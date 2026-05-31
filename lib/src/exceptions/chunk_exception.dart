import 'upload_exception.dart';

/// Thrown when a specific chunk fails to upload and all retry attempts
/// have been exhausted.
///
/// Contains the chunk index, the HTTP status code (if the server
/// responded), and the raw response body — enough information to log
/// the error precisely or surface it in a developer console.
///
/// ## Example
/// ```dart
/// } on ChunkException catch (e) {
///   logger.error(
///     'Chunk ${e.chunkIndex} failed: HTTP ${e.statusCode} — ${e.responseBody}',
///   );
/// }
/// ```
class ChunkException extends UploadException {
  // ── Chunk identity ─────────────────────────────────────────────────────────

  /// Zero-based index of the chunk that could not be uploaded.
  final int chunkIndex;

  // ── Server response ────────────────────────────────────────────────────────

  /// HTTP status code returned by the server, or `null` if the request
  /// never reached the server (e.g. DNS failure, timeout).
  final int? statusCode;

  /// Raw response body from the server, trimmed to 4 KB to avoid
  /// bloating log output.
  final String? responseBody;

  // ── Retry info ─────────────────────────────────────────────────────────────

  /// Total number of upload attempts made for this chunk before giving up.
  final int attempts;

  // ── Constructor ────────────────────────────────────────────────────────────

  const ChunkException(
    super.message, {
    required this.chunkIndex,
    required this.attempts,
    this.statusCode,
    this.responseBody,
    super.sessionId,
    super.cause,
    super.stackTrace,
  });

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// `true` when the failure is a server-side error (5xx).
  bool get isServerError => statusCode != null && statusCode! >= 500;

  /// `true` when the failure is a client-side error (4xx).
  bool get isClientError =>
      statusCode != null && statusCode! >= 400 && statusCode! < 500;

  /// `true` when the request never received an HTTP response.
  bool get isNetworkError => statusCode == null;

  // ── Debug ──────────────────────────────────────────────────────────────────

  @override
  String toString() {
    final buf = StringBuffer(
      'ChunkException[chunk=$chunkIndex, attempts=$attempts',
    );
    if (statusCode != null) buf.write(', HTTP $statusCode');
    if (sessionId != null) buf.write(', session=$sessionId');
    buf.write(']: $message');
    if (responseBody != null && responseBody!.isNotEmpty) {
      final preview = responseBody!.length > 200
          ? '${responseBody!.substring(0, 200)}…'
          : responseBody!;
      buf.write('\n  Server said: $preview');
    }
    return buf.toString();
  }
}

