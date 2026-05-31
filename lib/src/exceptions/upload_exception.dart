/// Base exception class for every error thrown by `quantum_upload`.
///
/// All library-specific exceptions extend [UploadException] so callers can
/// catch the entire hierarchy with a single `on UploadException catch (e)`
/// block, or target sub-types individually for finer-grained handling.
///
/// ## Example — catch everything
/// ```dart
/// try {
///   await Uploader.upload(filePath: '…', url: '…');
/// } on UploadException catch (e) {
///   print('Upload error: ${e.message}  (session: ${e.sessionId})');
/// }
/// ```
///
/// ## Example — catch only chunk errors
/// ```dart
/// } on ChunkException catch (e) {
///   print('Chunk ${e.chunkIndex} failed with HTTP ${e.statusCode}');
/// }
/// ```
class UploadException implements Exception {
  /// Human-readable description of the error.
  final String message;

  /// Session ID associated with the upload when the error occurred.
  ///
  /// Persist this value so you can offer a "resume" option in your UI.
  /// `null` if the error occurred before a session was established.
  final String? sessionId;

  /// The original exception or error that caused this [UploadException],
  /// if any (e.g. a [SocketException] or [HttpException]).
  final Object? cause;

  /// Stack trace captured at the point the exception was created.
  final StackTrace? stackTrace;

  const UploadException(
    this.message, {
    this.sessionId,
    this.cause,
    this.stackTrace,
  });

  @override
  String toString() {
    final buf = StringBuffer('UploadException: $message');
    if (sessionId != null) buf.write(' (session: $sessionId)');
    if (cause != null) buf.write('\n  Caused by: $cause');
    return buf.toString();
  }
}

