/// Contains the full summary of a successfully completed upload operation.
///
/// An [UploadResult] is returned by [Uploader.start] and passed to
/// [UploadConfig.onComplete] once *every* chunk has been confirmed
/// by the server.
class UploadResult {
  // ── Identity ──────────────────────────────────────────────────────────────

  /// The session ID that was used for this upload.
  ///
  /// Matches the value previously returned by [Uploader.sessionId].
  final String sessionId;

  // ── Volume ────────────────────────────────────────────────────────────────

  /// Total number of bytes uploaded (= file size on disk).
  final int totalBytes;

  /// Total number of chunks that were sent to the server.
  ///
  /// Equal to `ceil(totalBytes / chunkSize)`.
  final int totalChunks;

  /// Number of chunks that were *actually* uploaded during this run
  /// (i.e. not already completed in a previous session).
  ///
  /// `resumedFromChunk == 0` means a fresh upload;
  /// `resumedFromChunk == totalChunks` is impossible (upload would be done).
  final int uploadedThisSession;

  // ── Timing ────────────────────────────────────────────────────────────────

  /// Wall-clock duration from [Uploader.start] to the last chunk ACK.
  ///
  /// Includes retry delays but *not* time spent in previous sessions.
  final Duration duration;

  // ── Speed ─────────────────────────────────────────────────────────────────

  /// Average upload throughput in bytes per second over [duration].
  ///
  /// Computed as `uploadedThisSession_bytes / duration.inSeconds`.
  final double averageSpeedBps;

  // ── Server ────────────────────────────────────────────────────────────────

  /// Raw response body returned by the server for the *last* chunk.
  ///
  /// Many backends return a JSON payload (e.g. a file URL or metadata)
  /// only after receiving the final chunk. Expose it here so callers
  /// don't have to add an extra API call.
  final String? serverResponse;

  /// HTTP status code for the final chunk's response.
  final int? statusCode;

  // ── Constructor ───────────────────────────────────────────────────────────

  const UploadResult({
    required this.sessionId,
    required this.totalBytes,
    required this.totalChunks,
    required this.uploadedThisSession,
    required this.duration,
    required this.averageSpeedBps,
    this.serverResponse,
    this.statusCode,
  });

  // ── Derived helpers ───────────────────────────────────────────────────────

  /// Average speed formatted as `"X.XX MB/s"`.
  String get speedMbps =>
      '${(averageSpeedBps / (1024 * 1024)).toStringAsFixed(2)} MB/s';

  /// Total size in mebibytes formatted as `"X.XX MiB"`.
  String get sizeMiB =>
      '${(totalBytes / (1024 * 1024)).toStringAsFixed(2)} MiB';

  /// Whether this was a fully fresh upload (no resumed chunks).
  bool get wasFreshUpload => uploadedThisSession == totalChunks;

  /// Fraction of chunks that were skipped due to a prior session.
  ///
  /// Returns `0.0` for a fresh upload, up to just below `1.0` if nearly
  /// all chunks were already done.
  double get resumedFraction =>
      (totalChunks - uploadedThisSession) / totalChunks;

  // ── Debug ─────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'UploadResult('
      'session=$sessionId, '
      'chunks=$totalChunks (uploaded=$uploadedThisSession), '
      'size=$sizeMiB, '
      'duration=${duration.inSeconds}s, '
      'speed=$speedMbps'
      ')';
}

