import 'package:test/test.dart';
import 'package:quantum_upload/quantum_upload.dart';

void main() {
  UploadConfig _config({int maxRetries = 3, int retryDelayMs = 10}) =>
      UploadConfig(
        filePath: '/dummy/file.mp4',
        url: Uri.parse('https://test.local/upload'),
        maxRetries: maxRetries,
        retryDelay: Duration(milliseconds: retryDelayMs),
      );

  // ═══════════════════════════════════════════════════════════════════════════
  // shouldRetry()
  // ═══════════════════════════════════════════════════════════════════════════

  group('shouldRetry()', () {
    test('returns true when attempts < maxRetries', () {
      final policy = RetryPolicy(_config(maxRetries: 3));
      expect(policy.shouldRetry(1), isTrue);
      expect(policy.shouldRetry(2), isTrue);
      expect(policy.shouldRetry(3), isTrue);
    });

    test('returns false when attempts > maxRetries', () {
      final policy = RetryPolicy(_config(maxRetries: 3));
      expect(policy.shouldRetry(4), isFalse);
      expect(policy.shouldRetry(10), isFalse);
    });

    test('maxRetries=0 → no retries at all', () {
      final policy = RetryPolicy(_config(maxRetries: 0));
      expect(policy.shouldRetry(1), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // delayFor()
  // ═══════════════════════════════════════════════════════════════════════════

  group('delayFor()', () {
    test('exponential growth: 2s, 4s, 8s with 2s base', () {
      final policy = RetryPolicy(_config(retryDelayMs: 2000));
      expect(policy.delayFor(1).inMilliseconds, equals(2000));
      expect(policy.delayFor(2).inMilliseconds, equals(4000));
      expect(policy.delayFor(3).inMilliseconds, equals(8000));
      expect(policy.delayFor(4).inMilliseconds, equals(16000));
    });

    test('is capped at 30 seconds regardless of attempt number', () {
      final policy = RetryPolicy(_config(retryDelayMs: 2000));
      // 2^20 × 2s would be enormous without the cap
      expect(policy.delayFor(20).inSeconds, equals(30));
    });

    test('100 ms base delay', () {
      final policy = RetryPolicy(_config(retryDelayMs: 100));
      expect(policy.delayFor(1).inMilliseconds, equals(100));
      expect(policy.delayFor(2).inMilliseconds, equals(200));
      expect(policy.delayFor(3).inMilliseconds, equals(400));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // execute() — generic retry executor
  // ═══════════════════════════════════════════════════════════════════════════

  group('execute()', () {
    test('returns immediately when action succeeds on first try', () async {
      final policy = RetryPolicy(_config());
      int calls = 0;

      final result = await policy.execute(() async {
        calls++;
        return 42;
      });

      expect(result, equals(42));
      expect(calls, equals(1));
    });

    test('retries up to maxRetries and returns on success', () async {
      final policy = RetryPolicy(_config(maxRetries: 3, retryDelayMs: 1));
      int calls = 0;

      final result = await policy.execute(() async {
        calls++;
        if (calls < 3) throw Exception('Transient error');
        return 'ok';
      });

      expect(result, equals('ok'));
      expect(calls, equals(3));
    });

    test('rethrows after exhausting all retries', () async {
      final policy = RetryPolicy(_config(maxRetries: 2, retryDelayMs: 1));
      int calls = 0;

      expect(
        () => policy.execute(() async {
          calls++;
          throw Exception('Always fail');
        }),
        throwsA(isA<Exception>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      // 1 initial + 2 retries = 3 total calls
      expect(calls, equals(3));
    });

    test('onRetry callback is invoked for each retry', () async {
      final policy = RetryPolicy(_config(maxRetries: 3, retryDelayMs: 1));
      final retryCalls = <int>[];

      try {
        await policy.execute(
          () async => throw Exception('fail'),
          onRetry: (attempt, _) => retryCalls.add(attempt),
        );
      } catch (_) {}

      expect(retryCalls, equals([1, 2, 3]));
    });

    test('shouldRetryFor can abort retries early', () async {
      final policy = RetryPolicy(_config(maxRetries: 5, retryDelayMs: 1));
      int calls = 0;

      expect(
        () => policy.execute(
          () async {
            calls++;
            throw Exception('Permanent error');
          },
          shouldRetryFor: (_) => false, // never retry
        ),
        throwsA(isA<Exception>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, equals(1)); // only one attempt
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // executeChunk() — HTTP-aware executor
  // ═══════════════════════════════════════════════════════════════════════════

  group('executeChunk()', () {
    test('does not retry on 4xx ChunkException', () async {
      final policy = RetryPolicy(_config(maxRetries: 3, retryDelayMs: 1));
      int calls = 0;

      expect(
        () => policy.executeChunk(
          () async {
            calls++;
            throw ChunkException(
              'Not found',
              chunkIndex: 0,
              attempts: 1,
              statusCode: 404, // 4xx — do not retry
            );
          },
          0,
        ),
        throwsA(isA<ChunkException>()),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, equals(1)); // no retries
    });

    test('retries on 5xx ChunkException', () async {
      final policy = RetryPolicy(_config(maxRetries: 2, retryDelayMs: 1));
      int calls = 0;

      try {
        await policy.executeChunk(
          () async {
            calls++;
            throw ChunkException(
              'Server error',
              chunkIndex: 0,
              attempts: calls,
              statusCode: 503, // 5xx — should retry
            );
          },
          0,
        );
      } catch (_) {}

      expect(calls, equals(3)); // 1 initial + 2 retries
    });

    test('retries on network Exception (no status code)', () async {
      final policy = RetryPolicy(_config(maxRetries: 2, retryDelayMs: 1));
      int calls = 0;

      try {
        await policy.executeChunk(
          () async {
            calls++;
            throw Exception('Connection refused');
          },
          0,
        );
      } catch (_) {}

      expect(calls, equals(3));
    });
  });
}

