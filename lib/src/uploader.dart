import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'chunk_manager.dart';
import 'upload_session.dart';
import 'upload_request.dart';
import 'retry_policy.dart';
import 'progress_tracker.dart';
import 'storage/session_storage.dart';
import 'storage/shared_prefs_storage.dart';
import 'models/upload_config.dart';
import 'models/upload_result.dart';
import 'models/upload_state.dart';
import 'exceptions/upload_exception.dart';

/// The main entry point for performing resumable, chunked file uploads.
///
/// [Uploader] orchestrates every aspect of the upload process:
///
/// 1. **Initialise** — [ChunkManager] analyses the file and pre-computes
///    chunk boundaries.
/// 2. **Restore or create** — [UploadSession] is either restored from
///    local storage (resuming a previous run) or created fresh.
/// 3. **Upload loop** — Each pending chunk is read, hashed, sent via
///    [UploadRequest], and confirmed; [UploadSession] is persisted after
///    every success.
/// 4. **Retry** — [RetryPolicy] wraps each send with exponential back-off.
/// 5. **Progress** — [ProgressTracker] broadcasts a [ProgressSnapshot]
///    stream and calls [UploadConfig.onProgress] after each chunk.
/// 6. **Control** — The caller can [pause], [resume], or [cancel] at any
///    time between chunks.
///
/// ## Simplest usage — one-liner
///
/// ```dart
/// final result = await Uploader.upload(
///   filePath: '/movies/holiday.mp4',
///   url: 'https://api.acme.com/v1/upload',
///   headers: {'Authorization': 'Bearer $token'},
///   onProgress: (pct) => print('${pct.toStringAsFixed(1)} %'),
/// );
/// print('Done: ${result.speedMbps} average');
/// ```
///
/// ## Advanced — pause / resume / cancel
///
/// ```dart
/// final uploader = Uploader(config);
///
/// // Listen to state changes for UI updates
/// uploader.stateStream.listen((s) => setState(() => _state = s));
///
/// // Start in background; pause after user taps button
/// unawaited(uploader.start());
///
/// onPauseButton:  uploader.pause();
/// onResumeButton: uploader.resume();
/// onCancelButton: await uploader.cancel();
/// ```
///
/// ## Resuming after app restart
///
/// ```dart
/// // First session — persist the session ID
/// final uploader = Uploader(config);
/// final sessionId = uploader.sessionId;       // save to prefs
/// await uploader.start();
///
/// // Second session — pass the saved ID
/// final resumeConfig = config.copyWith(sessionId: savedSessionId);
/// await Uploader(resumeConfig).start();       // skips completed chunks
/// ```
class Uploader {
  // ── Configuration ──────────────────────────────────────────────────────────

  final UploadConfig _config;

  // ── Internals (fully initialised in start()) ──────────────────────────────

  late final ChunkManager _chunkManager;

  // _session is nullable so that cancel() can safely check whether start()
  // has been called yet (and skip the delete() if not).
  UploadSession? _session;

  late final RetryPolicy _retryPolicy;

  // _progressTracker is created inside start() once the file size is known.
  // Declared late non-final so it can be assigned and reassigned there.
  late ProgressTracker _progressTracker;

  late final UploadRequest _uploadRequest;
  late final http.Client _httpClient;
  late final bool _ownsHttpClient; // true when we created the client ourselves

  // ── Session ID ─────────────────────────────────────────────────────────────

  /// The session ID for this upload.
  ///
  /// Available immediately after construction (generated from
  /// [UploadConfig.sessionId] or a new UUID v4 if none was provided).
  ///
  /// Persist this value in your app to enable cross-session resumption:
  /// ```dart
  /// final id = uploader.sessionId;
  /// prefs.setString('lastUploadSession', id);
  /// ```
  late final String sessionId;

  // ── State ──────────────────────────────────────────────────────────────────

  UploadState _state = UploadState.idle;

  /// The current [UploadState] of this uploader.
  UploadState get state => _state;

  final _stateController = StreamController<UploadState>.broadcast();

  /// Broadcast stream of [UploadState] transitions.
  ///
  /// Emit order for a happy path:
  /// `idle → uploading → (retrying →)* uploading → completed`
  Stream<UploadState> get stateStream => _stateController.stream;

  // ── Progress ───────────────────────────────────────────────────────────────

  // Stable broadcast controller whose identity never changes.
  // Listeners may attach before start() — they will receive all snapshots
  // once the real ProgressTracker is created inside start().
  final _progressController =
      StreamController<ProgressSnapshot>.broadcast();

  // Subscription that forwards real-tracker events into _progressController.
  // Stored so it can be cancelled on dispose.
  StreamSubscription<ProgressSnapshot>? _progressForwardSub;

  /// Broadcast stream of [ProgressSnapshot] objects.
  ///
  /// Emits one snapshot per uploaded chunk.
  /// Listeners attached before [start] will receive all snapshots once
  /// the upload begins.
  Stream<ProgressSnapshot> get progressStream => _progressController.stream;

  // ── Control flags ──────────────────────────────────────────────────────────

  bool _cancelRequested = false;
  bool _pauseRequested = false;
  final _resumeCompleter = Completer<void>();

  // ── Constructor ────────────────────────────────────────────────────────────

  Uploader(this._config) {
    sessionId = _config.sessionId ?? const Uuid().v4();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Static convenience factory
  // ═══════════════════════════════════════════════════════════════════════════

  /// Creates an [Uploader] from the given parameters and immediately starts it.
  ///
  /// Equivalent to:
  /// ```dart
  /// await Uploader(UploadConfig(filePath: …, url: …, …)).start();
  /// ```
  ///
  /// ### Returns
  /// An [UploadResult] on success.
  ///
  /// ### Throws
  /// - [UploadException] on unrecoverable failure.
  /// - [FileSystemException] if the file does not exist.
  static Future<UploadResult> upload({
    required String filePath,
    required String url,
    int chunkSize = 5 * 1024 * 1024,
    int maxRetries = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Map<String, String> headers = const {},
    http.Client? httpClient,
    String? sessionId,
    SessionStorage? storage,
    void Function(double percent)? onProgress,
    void Function(int chunkIndex, int attempt)? onChunkRetry,
    void Function(UploadResult result)? onComplete,
    void Function(UploadException error)? onError,
  }) {
    final config = UploadConfig(
      filePath: filePath,
      url: Uri.parse(url),
      chunkSize: chunkSize,
      maxRetries: maxRetries,
      retryDelay: retryDelay,
      headers: headers,
      httpClient: httpClient,
      sessionId: sessionId,
      onProgress: onProgress,
      onChunkRetry: onChunkRetry,
      onComplete: onComplete,
      onError: onError,
    );
    return Uploader(config).start(storage: storage);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Core — start()
  // ═══════════════════════════════════════════════════════════════════════════

  /// Begins (or resumes) the upload.
  ///
  /// [storage] overrides the default [SharedPrefsStorage]. Pass an
  /// [InMemorySessionStorage] in tests to avoid touching disk.
  ///
  /// ### Returns
  /// [UploadResult] when every chunk has been confirmed by the server.
  ///
  /// ### Throws
  /// - [UploadException] — unrecoverable failure (all retries exhausted).
  /// - [FileSystemException] — source file missing or unreadable.
  Future<UploadResult> start({SessionStorage? storage}) async {
    // ── Set up HTTP client ─────────────────────────────────────────────────
    if (_config.httpClient != null) {
      _httpClient = _config.httpClient!;
      _ownsHttpClient = false; // caller manages lifecycle
    } else {
      _httpClient = http.Client();
      _ownsHttpClient = true;
    }

    _retryPolicy = RetryPolicy(_config);
    final sessionStorage = storage ?? SharedPrefsStorage();

    // ── Initialise chunk manager ────────────────────────────────────────────
    _chunkManager = ChunkManager(_config);
    await _chunkManager.initialize();

    // ── Restore or create session ───────────────────────────────────────────
    final existing = await UploadSession.restore(
      sessionId: sessionId,
      storage: sessionStorage,
    );

    if (existing != null) {
      _session = existing
        ..state = UploadState.uploading;
    } else {
      _session = UploadSession(
        sessionId: sessionId,
        filePath: _config.filePath,
        uploadUrl: _config.url.toString(),
        fileSize: _chunkManager.fileSize,
        chunks: List.from(_chunkManager.chunks),
        storage: sessionStorage,
      );
    }

    await _session!.save();

    // ── Progress tracker ────────────────────────────────────────────────────
    // Create a properly-sized tracker now that we know the real file size,
    // and forward its snapshots into the stable _progressController so that
    // listeners attached before start() receive all events.
    _progressTracker = ProgressTracker(totalBytes: _chunkManager.fileSize);
    _progressForwardSub = _progressTracker.progressStream.listen(
      (snapshot) {
        if (!_progressController.isClosed) _progressController.add(snapshot);
      },
    );
    _progressTracker.start();

    // Pre-seed progress for already-uploaded bytes (resumed session).
    if (_session!.uploadedBytes > 0) {
      _progressTracker.addBytes(_session!.uploadedBytes);
    }

    // ── Upload request builder ──────────────────────────────────────────────
    _uploadRequest = UploadRequest(config: _config, client: _httpClient);

    // ── Main loop ───────────────────────────────────────────────────────────
    _setState(UploadState.uploading);
    final startTime = DateTime.now();
    final chunksUploadedThisSession =
        _session!.chunks.length - _session!.nextChunkIndex;
    String? lastServerResponse;
    int? lastStatusCode;

    try {
      final result = await _uploadAllChunks();
      lastServerResponse = result.$1;
      lastStatusCode = result.$2;
    } catch (e, st) {
      _setState(UploadState.failed);

      // Wrap plain exceptions into UploadException so callers always receive
      // a typed error from start().
      final wrapped = e is UploadException
          ? e
          : UploadException(
              'Unexpected error: $e',
              sessionId: sessionId,
              cause: e,
              stackTrace: st,
            );
      _config.onError?.call(wrapped);
      await _progressForwardSub?.cancel();
      await _progressTracker.dispose();
      if (_ownsHttpClient) _httpClient.close();
      throw wrapped; // throw the UploadException, not the original
    }
    // ── Cleanup (success path) ─────────────────────────────────────────────
    if (_ownsHttpClient) _httpClient.close();
    await _progressForwardSub?.cancel();
    await _progressTracker.dispose();

    // ── Build result ────────────────────────────────────────────────────────
    final duration = DateTime.now().difference(startTime);
    final result = UploadResult(
      sessionId: sessionId,
      totalBytes: _chunkManager.fileSize,
      totalChunks: _chunkManager.totalChunks,
      uploadedThisSession: chunksUploadedThisSession,
      duration: duration,
      averageSpeedBps: _progressTracker.speedBps,
      serverResponse: lastServerResponse,
      statusCode: lastStatusCode,
    );

    _setState(UploadState.completed);
    await _session!.delete(); // clean up — no longer resumable
    _config.onComplete?.call(result);

    return result;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal upload loop
  // ═══════════════════════════════════════════════════════════════════════════

  /// Iterates through all pending chunks, sends each one, and persists
  /// progress after each success.
  ///
  /// Returns a tuple of (lastServerResponse, lastStatusCode).
  Future<(String?, int?)> _uploadAllChunks() async {
    final startIndex = _session!.nextChunkIndex;
    String? lastServerResponse;
    int? lastStatusCode;

    for (int i = startIndex; i < _chunkManager.totalChunks; i++) {
      // ── Cancellation check ────────────────────────────────────────────────
      if (_cancelRequested) {
        _setState(UploadState.cancelled);
        throw UploadException(
          'Upload cancelled by user.',
          sessionId: sessionId,
        );
      }

      // ── Pause gate ────────────────────────────────────────────────────────
      if (_pauseRequested) {
        _setState(UploadState.paused);
        await _waitForResume();
        _setState(UploadState.uploading);
      }

      // ── Upload chunk with retry ───────────────────────────────────────────
      final response = await _retryPolicy.executeChunk(
        () => _sendChunk(i),
        i,
        onRetry: (attempt, error) {
          _setState(UploadState.retrying);
          _config.onChunkRetry?.call(i, attempt);
        },
      );

      lastServerResponse = response.body;
      lastStatusCode = response.statusCode;

      // ── Persist progress ──────────────────────────────────────────────────
      _session!.markChunkCompleted(i);
      await _session!.save();

      // ── Broadcast progress ────────────────────────────────────────────────
      final chunkSize = _chunkManager.chunks[i].size;
      _progressTracker.addBytes(chunkSize);
      _config.onProgress?.call(_progressTracker.currentPercent);

      // Return to uploading state if we were retrying
      if (_state == UploadState.retrying) {
        _setState(UploadState.uploading);
      }
    }

    return (lastServerResponse, lastStatusCode);
  }

  // ── Single chunk dispatch ──────────────────────────────────────────────────

  /// Reads, hashes, and sends chunk at [chunkIndex].
  Future<http.Response> _sendChunk(int chunkIndex) async {
    final chunkInfo = _session!.chunks[chunkIndex];
    final data = await _chunkManager.readChunk(chunkIndex);
    final checksum = await _chunkManager.computeChecksum(data);

    return _uploadRequest.send(
      sessionId: sessionId,
      chunkInfo: chunkInfo,
      totalChunks: _chunkManager.totalChunks,
      totalBytes: _chunkManager.fileSize,
      data: data,
      checksum: checksum,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Control API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Pauses the upload **after the current chunk finishes**.
  ///
  /// The upload loop checks [_pauseRequested] at the top of every
  /// iteration, so the upload will not stop mid-chunk.
  ///
  /// Call [resume] to continue.
  void pause() {
    if (_state.isTerminal) return;
    _pauseRequested = true;
  }

  /// Resumes a paused upload.
  ///
  /// Has no effect if the upload is not currently paused.
  void resume() {
    if (!_pauseRequested) return;
    _pauseRequested = false;
    if (!_resumeCompleter.isCompleted) _resumeCompleter.complete();
  }

  /// Permanently cancels the upload and deletes the saved session.
  ///
  /// The [start] future will throw an [UploadException] with the message
  /// `"Upload cancelled by user."`.
  ///
  /// After cancellation, this [Uploader] instance cannot be reused —
  /// create a new one to start over.
  Future<void> cancel() async {
    _cancelRequested = true;
    if (_pauseRequested) resume(); // unblock the pause gate
    // _session is only set once start() has run; guard against early cancel().
    await _session?.delete();
    _setState(UploadState.cancelled);
  }

  // ── Pause helper ──────────────────────────────────────────────────────────

  Future<void> _waitForResume() async {
    // Poll every 200 ms instead of using a Completer so that
    // cancellation is also detected while paused.
    while (_pauseRequested && !_cancelRequested) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  // ── State helper ──────────────────────────────────────────────────────────

  void _setState(UploadState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Disposal
  // ═══════════════════════════════════════════════════════════════════════════

  /// Releases all resources held by this [Uploader].
  ///
  /// Call this when you no longer need the uploader (e.g. in a widget's
  /// `dispose` method or at the end of a test).  Calling [start] after
  /// [dispose] results in undefined behaviour.
  Future<void> dispose() async {
    await _progressForwardSub?.cancel();
    if (!_progressController.isClosed) await _progressController.close();
    if (!_stateController.isClosed) await _stateController.close();
  }
}

