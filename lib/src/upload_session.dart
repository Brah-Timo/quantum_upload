import 'dart:convert';

import 'models/chunk_info.dart';
import 'models/upload_state.dart';
import 'storage/session_storage.dart';
import 'exceptions/session_exception.dart';

/// Manages the **persistent state** of a single chunked-upload operation.
///
/// An [UploadSession] tracks:
/// - Which chunks have been successfully confirmed by the server.
/// - The overall [UploadState] of the upload.
/// - Timestamps for creation and last activity.
///
/// State is persisted to a [SessionStorage] after every successful chunk
/// (via [markChunkCompleted] + [save]) so that, if the app is killed,
/// a new [Uploader] can call [UploadSession.restore] and skip all
/// already-completed chunks.
///
/// ## Lifecycle
///
/// ```
/// UploadSession(…)          ← created fresh
///   └─ save()               ← persisted before first chunk
///       └─ markChunkCompleted(i) + save()   ← repeated per chunk
///           └─ delete()     ← removed when upload is done
/// ```
///
/// For a resumed upload:
/// ```
/// UploadSession.restore(sessionId, storage)  ← loads from disk
///   └─ nextChunkIndex                        ← first pending chunk
///       └─ markChunkCompleted(i) + save()    ← continues from there
/// ```
class UploadSession {
  // ── Identity ───────────────────────────────────────────────────────────────

  /// Unique identifier for this session. Matches [UploadConfig.sessionId]
  /// (or the auto-generated UUID v4 if none was supplied).
  final String sessionId;

  // ── File metadata ──────────────────────────────────────────────────────────

  /// Absolute path to the source file on disk.
  final String filePath;

  /// Target upload URL.
  final String uploadUrl;

  /// Total file size in bytes.
  final int fileSize;

  // ── Chunk state ────────────────────────────────────────────────────────────

  /// Mutable list of per-chunk metadata.
  ///
  /// Each element's [ChunkInfo.state] is updated as chunks succeed or fail.
  /// This is the sole source of truth for "which chunks still need to go."
  List<ChunkInfo> chunks;

  // ── Session state ──────────────────────────────────────────────────────────

  /// Overall state of this upload session.
  UploadState state;

  // ── Timestamps ─────────────────────────────────────────────────────────────

  /// When this session was first created.
  final DateTime createdAt;

  /// When the last successful chunk was confirmed. Updated by
  /// [markChunkCompleted]. `null` until at least one chunk succeeds.
  DateTime? lastActivityAt;

  // ── Storage back-end ───────────────────────────────────────────────────────

  final SessionStorage _storage;

  // ── Constructor ────────────────────────────────────────────────────────────

  UploadSession({
    required this.sessionId,
    required this.filePath,
    required this.uploadUrl,
    required this.fileSize,
    required this.chunks,
    required SessionStorage storage,
    this.state = UploadState.idle,
    DateTime? createdAt,
    this.lastActivityAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        _storage = storage;

  // ── Derived getters ────────────────────────────────────────────────────────

  /// Index of the **first chunk that has not yet been completed**.
  ///
  /// Used by [Uploader._uploadAllChunks] to skip already-done chunks
  /// when resuming. Returns [chunks.length] if all chunks are done.
  int get nextChunkIndex {
    for (int i = 0; i < chunks.length; i++) {
      if (chunks[i].state != UploadState.completed) return i;
    }
    return chunks.length;
  }

  /// Number of chunks that have been successfully confirmed by the server.
  int get uploadedChunks =>
      chunks.where((c) => c.state == UploadState.completed).length;

  /// Total bytes that have been successfully uploaded so far.
  int get uploadedBytes => chunks
      .where((c) => c.state == UploadState.completed)
      .fold(0, (sum, c) => sum + c.size);

  /// `true` when every chunk in [chunks] is [UploadState.completed].
  bool get isComplete => uploadedChunks == chunks.length;

  /// Progress as a value in `[0.0, 1.0]`.
  double get progressFraction =>
      chunks.isEmpty ? 0.0 : uploadedChunks / chunks.length;

  // ── Mutation ───────────────────────────────────────────────────────────────

  /// Marks chunk [index] as [UploadState.completed] and records the
  /// current timestamp in [lastActivityAt].
  ///
  /// Call [save] afterwards to persist the change.
  void markChunkCompleted(int index) {
    _assertValidIndex(index);
    chunks[index] = chunks[index].copyWith(state: UploadState.completed);
    lastActivityAt = DateTime.now();
  }

  /// Marks chunk [index] as [UploadState.failed] and increments its
  /// [ChunkInfo.attempts] counter.
  ///
  /// Call [save] afterwards so that a cold restart doesn't lose the
  /// attempt count (which feeds into [RetryPolicy.shouldRetry]).
  void markChunkFailed(int index) {
    _assertValidIndex(index);
    chunks[index] = chunks[index].copyWith(
      state: UploadState.failed,
      attempts: chunks[index].attempts + 1,
    );
  }

  /// Resets chunk [index] back to [UploadState.idle] so that the
  /// [RetryPolicy] loop can attempt it again.
  void resetChunk(int index) {
    _assertValidIndex(index);
    chunks[index] = chunks[index].copyWith(state: UploadState.idle);
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Serialises and writes the current session state to [_storage].
  ///
  /// Called after every successful or failed chunk to minimise the
  /// "work lost on crash" window.
  Future<void> save() async {
    try {
      await _storage.write(sessionId, _toJson());
    } catch (e, st) {
      // Re-wrap as SessionException for uniform error handling.
      throw SessionException(
        'Failed to persist session "$sessionId".',
        sessionId: sessionId,
        cause: e,
        stackTrace: st,
      );
    }
  }

  /// Removes this session from [_storage].
  ///
  /// Called by [Uploader] after a successful completion or a user
  /// cancel to reclaim local storage.
  Future<void> delete() async {
    try {
      await _storage.delete(sessionId);
    } catch (e, st) {
      throw SessionException(
        'Failed to delete session "$sessionId".',
        sessionId: sessionId,
        cause: e,
        stackTrace: st,
      );
    }
  }

  // ── Restoration ────────────────────────────────────────────────────────────

  /// Attempts to restore a previously saved session from [storage].
  ///
  /// Returns `null` if no session with [sessionId] is found.
  /// Throws [SessionException] if the persisted data exists but is corrupt.
  static Future<UploadSession?> restore({
    required String sessionId,
    required SessionStorage storage,
  }) async {
    final raw = await storage.read(sessionId);
    if (raw == null) return null;

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return UploadSession._fromJson(json, storage);
    } catch (e, st) {
      throw SessionException(
        'Session "$sessionId" exists but could not be deserialised. '
        'The data may be from an incompatible version.',
        sessionId: sessionId,
        cause: e,
        stackTrace: st,
        isCorrupt: true,
      );
    }
  }

  // ── JSON serialisation ─────────────────────────────────────────────────────

  String _toJson() => jsonEncode({
        'v': 1, // schema version — bump when adding breaking fields
        'sessionId': sessionId,
        'filePath': filePath,
        'uploadUrl': uploadUrl,
        'fileSize': fileSize,
        'state': state.name,
        'createdAt': createdAt.toIso8601String(),
        'lastActivityAt': lastActivityAt?.toIso8601String(),
        'chunks': chunks.map((c) => c.toJson()).toList(),
      });

  factory UploadSession._fromJson(
    Map<String, dynamic> json,
    SessionStorage storage,
  ) {
    return UploadSession(
      sessionId: json['sessionId'] as String,
      filePath: json['filePath'] as String,
      uploadUrl: json['uploadUrl'] as String,
      fileSize: json['fileSize'] as int,
      state: UploadState.values.byName(json['state'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastActivityAt: json['lastActivityAt'] != null
          ? DateTime.parse(json['lastActivityAt'] as String)
          : null,
      chunks: (json['chunks'] as List<dynamic>)
          .map((c) => ChunkInfo.fromJson(c as Map<String, dynamic>))
          .toList(),
      storage: storage,
    );
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  void _assertValidIndex(int index) {
    if (index < 0 || index >= chunks.length) {
      throw RangeError.index(index, chunks, 'chunkIndex');
    }
  }

  // ── Debug ──────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'UploadSession('
      'id=$sessionId, '
      '${uploadedChunks}/${chunks.length} chunks, '
      'state=${state.name}'
      ')';
}

