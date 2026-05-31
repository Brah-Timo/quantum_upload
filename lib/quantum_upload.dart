/// A pure Dart library for resumable, chunked file uploads over HTTP.
///
/// ## Overview
///
/// `quantum_upload` solves the classic problem of uploading large files over
/// unstable networks. Instead of sending a 2 GB file as a single payload and
/// losing everything on a network drop at 99%, it:
///
/// 1. **Splits** the file into configurable-size chunks (default: 5 MB).
/// 2. **Persists** session state locally after every successful chunk.
/// 3. **Resumes** from the last successful chunk — even after the app restarts.
/// 4. **Retries** failed chunks with exponential back-off.
/// 5. **Verifies** every chunk with an MD5 checksum before and after transfer.
///
/// The library is fully **server-agnostic**: it uses standard HTTP multipart
/// `POST` requests that any backend (Node.js, Python, Go, PHP, …) can receive
/// without a special protocol like `tus`.
///
/// ## Quick start
///
/// ```dart
/// import 'package:quantum_upload/quantum_upload.dart';
///
/// final result = await Uploader.upload(
///   filePath: '/path/to/video.mp4',
///   url: 'https://api.example.com/upload',
///   onProgress: (pct) => print('${pct.toStringAsFixed(1)} %'),
/// );
/// print('Done in ${result.duration.inSeconds}s @ ${result.speedMbps}');
/// ```
///
/// ## Resuming an interrupted upload
///
/// ```dart
/// // First run — save the session ID somewhere durable
/// final uploader = Uploader(UploadConfig(
///   filePath: '/path/to/video.mp4',
///   url: Uri.parse('https://api.example.com/upload'),
/// ));
/// final sessionId = uploader.sessionId;   // persist this
///
/// // Second run — resume automatically
/// await Uploader.upload(
///   filePath: '/path/to/video.mp4',
///   url: 'https://api.example.com/upload',
///   sessionId: sessionId,                 // magic: skips uploaded chunks
/// );
/// ```
library quantum_upload;

// ── Core ──────────────────────────────────────────────────────────────────────
export 'src/uploader.dart';
export 'src/chunk_manager.dart';
export 'src/upload_session.dart';
export 'src/upload_request.dart';
export 'src/retry_policy.dart';
export 'src/progress_tracker.dart';

// ── Models ────────────────────────────────────────────────────────────────────
export 'src/models/upload_config.dart';
export 'src/models/upload_result.dart';
export 'src/models/upload_state.dart';
export 'src/models/chunk_info.dart';

// ── Exceptions ────────────────────────────────────────────────────────────────
export 'src/exceptions/upload_exception.dart';
export 'src/exceptions/chunk_exception.dart';
export 'src/exceptions/session_exception.dart';

// ── Storage (public interface only) ───────────────────────────────────────────
export 'src/storage/session_storage.dart';
export 'src/storage/shared_prefs_storage.dart';

