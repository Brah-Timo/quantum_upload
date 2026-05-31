import 'upload_state.dart';

/// Immutable metadata record for a single file chunk.
///
/// A [ChunkInfo] describes the byte boundaries of one slice of the
/// source file, tracks how many upload attempts have been made, stores
/// the MD5 checksum once computed, and records the current [UploadState]
/// of that slice specifically.
///
/// The list of [ChunkInfo] objects is owned by [UploadSession] and
/// serialised to JSON so that progress survives app restarts.
class ChunkInfo {
  // ── Identity ──────────────────────────────────────────────────────────────

  /// Zero-based sequential index of this chunk within the complete file.
  ///
  /// The first chunk has [index] == 0; the last has
  /// [index] == `totalChunks - 1`.
  final int index;

  // ── Byte range ────────────────────────────────────────────────────────────

  /// Byte offset (inclusive) where this chunk starts in the original file.
  final int startByte;

  /// Byte offset (exclusive) where this chunk ends in the original file.
  ///
  /// The actual bytes belonging to this chunk are `[startByte, endByte)`.
  final int endByte;

  /// Number of bytes in this chunk: `endByte - startByte`.
  ///
  /// Equal to `chunkSize` for every chunk except possibly the last, which
  /// carries the file's remainder bytes:
  /// ```
  /// lastChunkSize = fileSize mod chunkSize
  /// ```
  int get size => endByte - startByte;

  // ── Integrity ─────────────────────────────────────────────────────────────

  /// MD5 hex-digest of this chunk's raw bytes.
  ///
  /// Computed by [ChunkManager.computeChecksum] just before transmission
  /// and sent as the `X-Chunk-Checksum` HTTP header so the server can
  /// verify data integrity independently.
  ///
  /// `null` until the chunk data has been read and hashed.
  final String? checksum;

  // ── State ─────────────────────────────────────────────────────────────────

  /// Current upload state of *this individual chunk*.
  final UploadState state;

  /// Total number of upload attempts made for this specific chunk.
  ///
  /// Incremented by [UploadSession.markChunkFailed] and used by
  /// [RetryPolicy.shouldRetry] to decide whether to give up.
  final int attempts;

  // ── Constructor ───────────────────────────────────────────────────────────

  const ChunkInfo({
    required this.index,
    required this.startByte,
    required this.endByte,
    this.checksum,
    this.state = UploadState.idle,
    this.attempts = 0,
  }) : assert(
          endByte > startByte,
          'endByte must be strictly greater than startByte',
        );

  // ── Immutable copy ────────────────────────────────────────────────────────

  /// Returns a copy of this [ChunkInfo] with the given fields replaced.
  ChunkInfo copyWith({
    UploadState? state,
    String? checksum,
    int? attempts,
  }) =>
      ChunkInfo(
        index: index,
        startByte: startByte,
        endByte: endByte,
        checksum: checksum ?? this.checksum,
        state: state ?? this.state,
        attempts: attempts ?? this.attempts,
      );

  // ── Serialisation ─────────────────────────────────────────────────────────

  /// Serialises this [ChunkInfo] to a JSON-compatible [Map].
  Map<String, dynamic> toJson() => {
        'index': index,
        'startByte': startByte,
        'endByte': endByte,
        'checksum': checksum,
        'state': state.name,
        'attempts': attempts,
      };

  /// Deserialises a [ChunkInfo] from a JSON [Map].
  factory ChunkInfo.fromJson(Map<String, dynamic> json) => ChunkInfo(
        index: json['index'] as int,
        startByte: json['startByte'] as int,
        endByte: json['endByte'] as int,
        checksum: json['checksum'] as String?,
        state: UploadState.values.byName(json['state'] as String),
        attempts: json['attempts'] as int,
      );

  // ── Debug ─────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'ChunkInfo(#$index bytes=$startByte–$endByte '
      'size=${size}B state=${state.name} attempts=$attempts)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChunkInfo &&
          other.index == index &&
          other.startByte == startByte &&
          other.endByte == endByte;

  @override
  int get hashCode => Object.hash(index, startByte, endByte);
}

