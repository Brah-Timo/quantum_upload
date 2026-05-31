import 'models/upload_config.dart';
import 'exceptions/chunk_exception.dart';

/// Encapsulates retry behaviour for individual chunk uploads.
///
/// Uses **exponential back-off with a hard cap** to spread retries out
/// over time, reducing the risk of hammering a struggling server.
///
/// ## Delay formula
///
/// For retry attempt *n* (1-based):
/// ```
/// delay_n = min( baseDelay × 2^(n−1),  maxDelay )
/// ```
///
/// With the defaults (`baseDelay = 2 s`, `maxDelay = 30 s`):
///
/// | Attempt | Delay |
/// |---------|-------|
/// | 1       | 2 s   |
/// | 2       | 4 s   |
/// | 3       | 8 s   |
/// | 4       | 16 s  |
/// | 5+      | 30 s  |
///
/// ## Usage
///
/// ```dart
/// final policy = RetryPolicy(config);
///
/// await policy.execute(
///   action : () => sendChunk(index, data),
///   onRetry: (attempt, err) => print('Retry #$attempt: $err'),
/// );
/// ```
class RetryPolicy {
  final UploadConfig _config;

  /// Hard upper-bound on any single delay interval.
  static const Duration _maxDelay = Duration(seconds: 30);

  const RetryPolicy(this._config);

  // ── Public API ─────────────────────────────────────────────────────────────

  /// `true` if another retry attempt is permissible after [attemptsMade]
  /// failures.
  ///
  /// [attemptsMade] is the number of *failed* attempts so far (1-based
  /// after the first failure).  The guard is:
  /// ```
  /// attemptsMade < maxRetries + 1
  /// ```
  /// because `maxRetries == 0` means "try once, do not retry."
  bool shouldRetry(int attemptsMade) =>
      attemptsMade <= _config.maxRetries;

  /// Returns the [Duration] to wait before attempt number [attemptNumber].
  ///
  /// [attemptNumber] is 1-based (1 = first retry after the initial failure).
  Duration delayFor(int attemptNumber) {
    assert(attemptNumber >= 1);
    final exponent = attemptNumber - 1; // 0, 1, 2, …
    final factor = 1 << exponent; // 1, 2, 4, 8, …
    final ms = _config.retryDelay.inMilliseconds * factor;
    return Duration(milliseconds: ms.clamp(0, _maxDelay.inMilliseconds));
  }

  // ── Generic executor ───────────────────────────────────────────────────────

  /// Executes [action] and retries on [Exception] up to [maxRetries] times.
  ///
  /// ### Parameters
  /// - [action]   — The async work to attempt (e.g. a chunk HTTP POST).
  /// - [onRetry]  — Optional callback invoked **before** each retry sleep
  ///                so the caller can log or update UI state.
  ///                Receives the 1-based [attempt] number and the caught
  ///                [Exception].
  /// - [shouldRetryFor] — Optional predicate that receives the caught
  ///                exception and returns `false` to abort retrying
  ///                immediately for non-transient errors (e.g. HTTP 404).
  ///
  /// ### Returns
  /// The value returned by [action] on its first successful invocation.
  ///
  /// ### Throws
  /// The original exception from [action] when all retries are exhausted
  /// or [shouldRetryFor] returns `false`.
  Future<T> execute<T>(
    Future<T> Function() action, {
    void Function(int attempt, Exception error)? onRetry,
    bool Function(Exception error)? shouldRetryFor,
  }) async {
    int attemptsMade = 0; // failed attempts so far

    while (true) {
      try {
        return await action();
      } on Exception catch (e) {
        attemptsMade++;

        // Honour caller's custom abort predicate.
        final retryable = shouldRetryFor?.call(e) ?? true;
        if (!retryable || !shouldRetry(attemptsMade)) {
          rethrow;
        }

        final delay = delayFor(attemptsMade);
        onRetry?.call(attemptsMade, e);
        await Future<void>.delayed(delay);
      }
    }
  }

  // ── HTTP-aware executor ────────────────────────────────────────────────────

  /// Like [execute] but automatically skips retries for 4xx responses.
  ///
  /// Client errors (400–499) indicate a problem with the request itself
  /// (e.g. bad session ID, file too large). Retrying won't help and would
  /// just waste time, so the exception is rethrown immediately.
  ///
  /// 5xx server errors *are* retried — they are usually transient.
  Future<T> executeChunk<T>(
    Future<T> Function() action,
    int chunkIndex, {
    void Function(int attempt, Exception error)? onRetry,
  }) =>
      execute(
        action,
        onRetry: onRetry,
        shouldRetryFor: (e) {
          if (e is ChunkException && e.isClientError) return false;
          return true; // retry on network errors and 5xx
        },
      );
}

