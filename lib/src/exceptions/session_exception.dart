import 'upload_exception.dart';

/// Thrown when a session-storage operation fails.
///
/// Typical causes:
/// - The device is out of storage space.
/// - The `SharedPreferences` store is locked by another process.
/// - A custom [SessionStorage] implementation threw an unhandled error.
/// - The persisted session JSON is corrupt or incompatible (version mismatch).
///
/// ## Recovery
/// When a [SessionException] is caught, treat it as if no prior session
/// exists and start a fresh upload:
/// ```dart
/// try {
///   await Uploader.upload(filePath: path, url: url, sessionId: saved);
/// } on SessionException {
///   // Session storage unavailable — start from scratch
///   await Uploader.upload(filePath: path, url: url);
/// }
/// ```
class SessionException extends UploadException {
  /// `true` when the session data was found but could not be deserialised.
  ///
  /// Indicates a version-mismatch or data corruption rather than a
  /// simple "not found" condition.
  final bool isCorrupt;

  const SessionException(
    super.message, {
    super.sessionId,
    super.cause,
    super.stackTrace,
    this.isCorrupt = false,
  });

  @override
  String toString() {
    final tag = isCorrupt ? 'SessionException(corrupt)' : 'SessionException';
    final buf = StringBuffer('$tag: $message');
    if (sessionId != null) buf.write(' (session: $sessionId)');
    if (cause != null) buf.write('\n  Caused by: $cause');
    return buf.toString();
  }
}

