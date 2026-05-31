/// Represents every possible state in the lifecycle of a chunked upload.
///
/// States flow in the following order for a happy path:
/// ```
/// idle → uploading → completed
/// ```
///
/// States for error / control paths:
/// ```
/// uploading → retrying → uploading          (transient retry)
/// uploading → paused   → uploading          (manual pause/resume)
/// uploading → interrupted → uploading       (network drop → auto-resume)
/// uploading → failed                        (exhausted retries)
/// uploading → cancelled                     (user cancelled)
/// ```
enum UploadState {
  /// The uploader has been created but [Uploader.start] has not been called.
  idle,

  /// Chunks are actively being sent to the server.
  uploading,

  /// The upload was manually paused via [Uploader.pause].
  /// Call [Uploader.resume] to continue.
  paused,

  /// The upload was interrupted by a network error or app lifecycle event.
  /// The session is persisted; call [Uploader.start] again to auto-resume.
  interrupted,

  /// A specific chunk failed and is being retried.
  /// This is a transient state; the upload returns to [uploading] on success.
  retrying,

  /// Every chunk has been successfully delivered to the server.
  completed,

  /// The upload failed permanently after exhausting all retry attempts.
  failed,

  /// The upload was explicitly cancelled via [Uploader.cancel].
  cancelled,
}

/// Convenience extensions on [UploadState].
extension UploadStateX on UploadState {
  /// `true` while the uploader is actively sending data.
  bool get isActive => this == UploadState.uploading;

  /// `true` for states that require no further action (terminal).
  bool get isTerminal =>
      this == UploadState.completed ||
      this == UploadState.failed ||
      this == UploadState.cancelled;

  /// `true` when the upload can be resumed.
  bool get canResume =>
      this == UploadState.paused || this == UploadState.interrupted;

  /// Human-readable label for UI display.
  String get label {
    switch (this) {
      case UploadState.idle:
        return 'Idle';
      case UploadState.uploading:
        return 'Uploading…';
      case UploadState.paused:
        return 'Paused';
      case UploadState.interrupted:
        return 'Interrupted — will resume';
      case UploadState.retrying:
        return 'Retrying…';
      case UploadState.completed:
        return 'Completed ✓';
      case UploadState.failed:
        return 'Failed ✗';
      case UploadState.cancelled:
        return 'Cancelled';
    }
  }
}

