import 'package:http/http.dart' as http;

import '../exceptions/upload_exception.dart';
import 'upload_result.dart';

/// Immutable configuration object for a single chunked-upload operation.
///
/// Pass a [UploadConfig] to [Uploader] (or use the [Uploader.upload]
/// convenience factory) to control every aspect of the upload:
/// chunk size, retry policy, custom HTTP headers, lifecycle callbacks,
/// and optional session resumption.
///
/// ## Example
/// ```dart
/// final config = UploadConfig(
///   filePath : '/sdcard/Movies/holiday.mp4',
///   url      : Uri.parse('https://api.acme.com/v1/upload'),
///   chunkSize: 10 * 1024 * 1024,   // 10 MB chunks
///   maxRetries: 5,
///   headers  : {'Authorization': 'Bearer $token'},
///   onProgress: (pct) => setState(() => _progress = pct),
///   sessionId: _savedSessionId,    // null → fresh upload
/// );
/// ```
class UploadConfig {
  // ── Required ───────────────────────────────────────────────────────────────

  /// Absolute path to the file that will be uploaded.
  ///
  /// The file must exist and be readable when [Uploader.start] is called;
  /// a [FileSystemException] is thrown otherwise.
  final String filePath;

  /// Target endpoint that will receive each chunk.
  ///
  /// Every chunk is sent as an HTTP `POST` with `multipart/form-data`
  /// encoding to this URI.
  final Uri url;

  // ── Chunking ────────────────────────────────────────────────────────────────

  /// Maximum number of bytes per chunk. Defaults to **5 MiB**.
  ///
  /// ### Trade-offs
  /// | Smaller chunks | Larger chunks |
  /// |---------------|--------------|
  /// | More resilient to drops | Fewer round-trips |
  /// | Higher request overhead | Better throughput on stable links |
  ///
  /// Recommended range: `1 MiB – 20 MiB`.
  final int chunkSize;

  // ── Retry ───────────────────────────────────────────────────────────────────

  /// Maximum number of *additional* attempts per chunk after the first
  /// failure. Defaults to **3** (= 4 total attempts before giving up).
  final int maxRetries;

  /// Base delay for the exponential back-off between retries.
  /// Defaults to **2 seconds**.
  ///
  /// Actual delay for attempt *n*:
  /// ```
  /// delay_n = retryDelay × 2^(n−1)   (capped at 30 s)
  /// ```
  final Duration retryDelay;

  // ── HTTP ────────────────────────────────────────────────────────────────────

  /// Additional HTTP headers merged into every chunk request.
  ///
  /// Typical uses: `Authorization`, `X-API-Key`, `X-App-Version`, etc.
  /// The following headers are *always* set by the library and must
  /// not be overridden here:
  /// `Content-Type`, `X-Session-Id`, `X-Chunk-Index`,
  /// `X-Total-Chunks`, `X-Chunk-Checksum`, `X-File-Size`, `Content-Range`.
  final Map<String, String> headers;

  /// Optional HTTP client override.
  ///
  /// Provide a custom [http.Client] (e.g. a [MockClient] in tests or a
  /// client with a custom certificate validator in production) to replace
  /// the default `http.Client()`.
  ///
  /// **Important**: the caller is responsible for closing this client.
  /// The library will *not* close it if it was injected externally.
  final http.Client? httpClient;

  // ── Session ─────────────────────────────────────────────────────────────────

  /// Session ID for resuming a previously interrupted upload.
  ///
  /// If `null`, the library generates a new UUID v4 and starts fresh.
  /// If a non-null value is supplied and a matching session is found in
  /// local storage, the upload skips all already-completed chunks.
  ///
  /// Persist the session ID returned by [Uploader.sessionId] in your app
  /// storage to enable cross-session resumption.
  final String? sessionId;

  // ── Callbacks ────────────────────────────────────────────────────────────────

  /// Called after each successful chunk with the overall progress
  /// percentage in the range `[0.0, 100.0]`.
  ///
  /// Guaranteed to be called on the isolate that called [Uploader.start].
  final void Function(double percent)? onProgress;

  /// Called immediately before each retry attempt.
  ///
  /// [chunkIndex] is the zero-based index of the failing chunk;
  /// [attempt] is the current retry number (1-based).
  final void Function(int chunkIndex, int attempt)? onChunkRetry;

  /// Called once when the upload completes successfully.
  ///
  /// Equivalent to awaiting the [Future] returned by [Uploader.start],
  /// but useful when you prefer a callback style.
  final void Function(UploadResult result)? onComplete;

  /// Called when an unrecoverable error terminates the upload.
  ///
  /// [error] carries the root cause and the session ID so you can
  /// display a meaningful message and offer a resume option.
  final void Function(UploadException error)? onError;

  // ── Constructor ──────────────────────────────────────────────────────────────

  const UploadConfig({
    required this.filePath,
    required this.url,
    this.chunkSize = 5 * 1024 * 1024,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 2),
    this.headers = const {},
    this.httpClient,
    this.sessionId,
    this.onProgress,
    this.onChunkRetry,
    this.onComplete,
    this.onError,
  }) : assert(chunkSize > 0, 'chunkSize must be positive'),
       assert(maxRetries >= 0, 'maxRetries must be non-negative');

  // ── copyWith ─────────────────────────────────────────────────────────────────

  /// Returns a copy of this config with the specified fields replaced.
  ///
  /// Useful for creating a "resume" config from an existing one:
  /// ```dart
  /// final resumeConfig = originalConfig.copyWith(sessionId: savedId);
  /// ```
  UploadConfig copyWith({
    String? filePath,
    Uri? url,
    int? chunkSize,
    int? maxRetries,
    Duration? retryDelay,
    Map<String, String>? headers,
    http.Client? httpClient,
    String? sessionId,
    void Function(double)? onProgress,
    void Function(int, int)? onChunkRetry,
    void Function(UploadResult)? onComplete,
    void Function(UploadException)? onError,
  }) =>
      UploadConfig(
        filePath: filePath ?? this.filePath,
        url: url ?? this.url,
        chunkSize: chunkSize ?? this.chunkSize,
        maxRetries: maxRetries ?? this.maxRetries,
        retryDelay: retryDelay ?? this.retryDelay,
        headers: headers ?? this.headers,
        httpClient: httpClient ?? this.httpClient,
        sessionId: sessionId ?? this.sessionId,
        onProgress: onProgress ?? this.onProgress,
        onChunkRetry: onChunkRetry ?? this.onChunkRetry,
        onComplete: onComplete ?? this.onComplete,
        onError: onError ?? this.onError,
      );

  @override
  String toString() =>
      'UploadConfig(filePath: $filePath, url: $url, '
      'chunkSize: ${chunkSize ~/ 1024}KiB, maxRetries: $maxRetries)';
}

// Note: UploadResult is defined in upload_result.dart and exported via the
// barrel file lib/quantum_upload.dart. Import that file for full access.

