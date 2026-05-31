import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models/chunk_info.dart';
import 'models/upload_config.dart';
import 'models/upload_state.dart';

/// Splits a file into fixed-size byte ranges and provides efficient,
/// on-demand chunk reading using a [RandomAccessFile].
///
/// ## Design rationale
///
/// Reading the entire file into memory at once is not feasible for large
/// uploads. [ChunkManager] instead computes chunk *boundaries* eagerly
/// (a list of `(startByte, endByte)` pairs — O(n) in chunk count, not
/// file size) and reads each chunk's raw bytes only when they are needed
/// via [readChunk]. The [RandomAccessFile.setPosition] call jumps directly
/// to the chunk's offset, so the OS only loads the relevant pages.
///
/// ## Chunk-count formula
///
/// ```
/// totalChunks = ⌈ fileSize / chunkSize ⌉
/// ```
///
/// Every chunk has exactly `chunkSize` bytes except the last, which holds
/// the remainder:
/// ```
/// lastChunkSize = fileSize mod chunkSize   (or chunkSize if perfectly divisible)
/// ```
///
/// ## Usage
///
/// ```dart
/// final manager = ChunkManager(config);
/// await manager.initialize();            // must call first
///
/// for (int i = 0; i < manager.totalChunks; i++) {
///   final bytes    = await manager.readChunk(i);
///   final checksum = await manager.computeChecksum(bytes);
///   // … send bytes to server …
/// }
/// ```
class ChunkManager {
  final UploadConfig _config;

  late final File _file;
  late final int _fileSize;
  late final String _fileName;
  late final List<ChunkInfo> _chunks;

  bool _initialized = false;

  ChunkManager(this._config);

  // ── Public initialiser ─────────────────────────────────────────────────────

  /// Analyses the source file and pre-computes all chunk boundaries.
  ///
  /// **Must be called** once before [readChunk], [chunks], or any other
  /// getter.  Calling it more than once is safe (subsequent calls are
  /// no-ops).
  ///
  /// Throws [FileSystemException] if the file at [UploadConfig.filePath]
  /// does not exist or cannot be stat'd.
  Future<void> initialize() async {
    if (_initialized) return;

    _file = File(_config.filePath);

    if (!await _file.exists()) {
      throw FileSystemException(
        'Source file not found.',
        _config.filePath,
      );
    }

    _fileSize = await _file.length();
    _fileName = p.basename(_config.filePath);

    if (_fileSize == 0) {
      throw FileSystemException(
        'Source file is empty — nothing to upload.',
        _config.filePath,
      );
    }

    _chunks = _computeChunks();
    _initialized = true;
  }

  // ── Chunk computation ──────────────────────────────────────────────────────

  /// Calculates the [ChunkInfo] list for the full file.
  ///
  /// Complexity: O(totalChunks) in both time and space.
  List<ChunkInfo> _computeChunks() {
    final result = <ChunkInfo>[];
    int offset = 0;
    int index = 0;

    while (offset < _fileSize) {
      final end = (offset + _config.chunkSize).clamp(0, _fileSize);
      result.add(ChunkInfo(
        index: index,
        startByte: offset,
        endByte: end,
        state: UploadState.idle,
      ));
      offset = end;
      index++;
    }

    return result;
  }

  // ── Chunk reading ──────────────────────────────────────────────────────────

  /// Reads and returns the raw bytes for chunk at [chunkIndex].
  ///
  /// Opens the file in read-only mode, seeks to [ChunkInfo.startByte],
  /// reads exactly [ChunkInfo.size] bytes, then closes the file handle.
  ///
  /// The returned [Uint8List] is a copy of the bytes — modifying it does
  /// not affect the file.
  ///
  /// Throws [StateError] if [initialize] has not been called.
  /// Throws [RangeError] if [chunkIndex] is out of bounds.
  /// Throws [FileSystemException] on any I/O error.
  Future<Uint8List> readChunk(int chunkIndex) async {
    _assertInitialized();

    if (chunkIndex < 0 || chunkIndex >= _chunks.length) {
      throw RangeError.index(chunkIndex, _chunks, 'chunkIndex');
    }

    final chunk = _chunks[chunkIndex];
    RandomAccessFile? raf;

    try {
      raf = await _file.open(mode: FileMode.read);
      await raf.setPosition(chunk.startByte);
      final bytes = await raf.read(chunk.size);
      return bytes;
    } on FileSystemException {
      rethrow;
    } catch (e) {
      throw FileSystemException(
        'Failed to read chunk $chunkIndex: $e',
        _config.filePath,
      );
    } finally {
      await raf?.close();
    }
  }

  // ── Integrity ──────────────────────────────────────────────────────────────

  /// Computes the **MD5** hex-digest of [data].
  ///
  /// The digest is sent as the `X-Chunk-Checksum` HTTP header so the
  /// server can independently verify that the received bytes are
  /// bit-for-bit identical to the original.
  ///
  /// MD5 is chosen for speed rather than cryptographic strength; it is
  /// more than sufficient to detect accidental corruption in transit.
  ///
  /// Returns a lowercase 32-character hex string.
  Future<String> computeChecksum(Uint8List data) async {
    final digest = md5.convert(data);
    return digest.toString();
  }

  /// Computes the **SHA-256** hex-digest of [data].
  ///
  /// Use this when your server requires a stronger hash algorithm.
  Future<String> computeSha256(Uint8List data) async {
    final digest = sha256.convert(data);
    return digest.toString();
  }

  // ── Public getters ─────────────────────────────────────────────────────────

  /// An unmodifiable view of all computed [ChunkInfo] objects.
  ///
  /// Each item describes the byte range of one chunk. States are all
  /// [UploadState.idle] at this point — [UploadSession] tracks the
  /// mutable per-chunk states.
  List<ChunkInfo> get chunks {
    _assertInitialized();
    return List.unmodifiable(_chunks);
  }

  /// Total number of chunks the file was split into.
  int get totalChunks {
    _assertInitialized();
    return _chunks.length;
  }

  /// Size of the source file in bytes.
  int get fileSize {
    _assertInitialized();
    return _fileSize;
  }

  /// Base name of the source file (e.g. `"holiday.mp4"`).
  String get fileName {
    _assertInitialized();
    return _fileName;
  }

  // ── Static helpers ─────────────────────────────────────────────────────────

  /// Estimates the total number of chunks **without** opening the file.
  ///
  /// Useful for quick pre-flight checks or UI labels before the upload
  /// has been initialised.
  ///
  /// ```dart
  /// final n = ChunkManager.estimateChunkCount(fileSize, chunkSize);
  /// print('Will upload in $n chunks');
  /// ```
  static int estimateChunkCount(int fileSize, int chunkSize) {
    assert(chunkSize > 0, 'chunkSize must be positive');
    return (fileSize / chunkSize).ceil();
  }

  /// Returns the size of the *last* chunk given a file size and chunk size.
  ///
  /// If `fileSize` is an exact multiple of `chunkSize` the last chunk is
  /// a full chunk (returns `chunkSize`).
  static int lastChunkSize(int fileSize, int chunkSize) {
    final remainder = fileSize % chunkSize;
    return remainder == 0 ? chunkSize : remainder;
  }

  // ── Private ────────────────────────────────────────────────────────────────

  void _assertInitialized() {
    if (!_initialized) {
      throw StateError(
        'ChunkManager.initialize() must be called before accessing this member.',
      );
    }
  }
}

