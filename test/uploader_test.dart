import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:quantum_upload/quantum_upload.dart';

import 'mocks/mock_http_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

late Directory tempDir;

Future<File> createTempFile(int sizeBytes) async {
  final file = File('${tempDir.path}/test_${sizeBytes}.bin');
  final data = Uint8List(sizeBytes);
  for (int i = 0; i < sizeBytes; i++) data[i] = i % 256;
  await file.writeAsBytes(data);
  return file;
}

UploadConfig _config(
  String filePath,
  MockHttpClient client, {
  int chunkSize = 512,
  int maxRetries = 3,
  String? sessionId,
  void Function(double)? onProgress,
}) =>
    UploadConfig(
      filePath: filePath,
      url: Uri.parse('https://upload.test.local/v1/upload'),
      chunkSize: chunkSize,
      maxRetries: maxRetries,
      retryDelay: const Duration(milliseconds: 1),
      httpClient: client,
      sessionId: sessionId,
      onProgress: onProgress,
    );

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('uploader_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Basic upload — happy path
  // ═══════════════════════════════════════════════════════════════════════════

  group('Uploader — happy path', () {
    test('uploads all chunks and returns UploadResult', () async {
      final file = await createTempFile(1024); // 1 KiB
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();

      final result = await Uploader(_config(file.path, mock))
          .start(storage: store);

      // 1024 / 512 = 2 chunks
      expect(result.totalChunks, equals(2));
      expect(result.totalBytes, equals(1024));
      expect(result.uploadedThisSession, equals(2));
      expect(mock.callCount, equals(2));
    });

    test('sends correct chunk-index headers', () async {
      final file = await createTempFile(1024);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();

      await Uploader(_config(file.path, mock)).start(storage: store);

      final indices = mock.capturedRequests
          .map((r) => r.chunkIndex)
          .toList()
        ..sort();
      expect(indices, equals([0, 1]));
    });

    test('sends correct X-Total-Chunks header', () async {
      final file = await createTempFile(1024);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();

      await Uploader(_config(file.path, mock)).start(storage: store);

      for (final req in mock.capturedRequests) {
        expect(req.totalChunks, equals(2));
      }
    });

    test('sends consistent X-Session-Id across all chunks', () async {
      final file = await createTempFile(1024);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();

      await Uploader(_config(file.path, mock)).start(storage: store);

      final sessionIds = mock.capturedRequests.map((r) => r.sessionId).toSet();
      expect(sessionIds.length, equals(1)); // all the same
      expect(sessionIds.first, isNotEmpty);
    });

    test('sends MD5 checksum header for every chunk', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();

      await Uploader(_config(file.path, mock)).start(storage: store);

      for (final req in mock.capturedRequests) {
        expect(req.checksum, matches(RegExp(r'^[0-9a-f]{32}$')));
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Progress
  // ═══════════════════════════════════════════════════════════════════════════

  group('Uploader — progress reporting', () {
    test('onProgress is called once per chunk', () async {
      final file = await createTempFile(1024); // 2 chunks
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();
      final progressValues = <double>[];

      await Uploader(_config(
        file.path,
        mock,
        onProgress: progressValues.add,
      )).start(storage: store);

      expect(progressValues.length, equals(2));
    });

    test('progress is monotonically non-decreasing', () async {
      final file = await createTempFile(3072); // 6 chunks of 512 B
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();
      final progressValues = <double>[];

      await Uploader(_config(
        file.path,
        mock,
        onProgress: progressValues.add,
      )).start(storage: store);

      for (int i = 1; i < progressValues.length; i++) {
        expect(
          progressValues[i],
          greaterThanOrEqualTo(progressValues[i - 1]),
        );
      }
    });

    test('final progress value is 100.0', () async {
      final file = await createTempFile(1024);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();
      double? last;

      await Uploader(_config(
        file.path,
        mock,
        onProgress: (p) => last = p,
      )).start(storage: store);

      expect(last, closeTo(100.0, 0.001));
    });

    test('progressStream emits correct number of snapshots', () async {
      final file = await createTempFile(2048); // 4 chunks
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();
      final uploader = Uploader(_config(file.path, mock));

      final snapshots = <ProgressSnapshot>[];
      final sub = uploader.progressStream.listen(snapshots.add);

      await uploader.start(storage: store);
      await sub.cancel();

      expect(snapshots.length, equals(4));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // State transitions
  // ═══════════════════════════════════════════════════════════════════════════

  group('Uploader — state transitions', () {
    test('stateStream emits uploading → completed on success', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();
      final states = <UploadState>[];
      final uploader = Uploader(_config(file.path, mock));

      uploader.stateStream.listen(states.add);
      await uploader.start(storage: store);

      expect(states, contains(UploadState.uploading));
      expect(states.last, equals(UploadState.completed));
    });

    test('state is completed after start() resolves', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();
      final uploader = Uploader(_config(file.path, mock));

      await uploader.start(storage: store);
      expect(uploader.state, equals(UploadState.completed));
    });

    test('stateStream emits retrying on transient failure', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient()..failThenSucceed(times: 1);
      final store = InMemorySessionStorage();
      final states = <UploadState>[];
      final uploader = Uploader(_config(file.path, mock, maxRetries: 3));

      uploader.stateStream.listen(states.add);
      await uploader.start(storage: store);

      expect(states, contains(UploadState.retrying));
      expect(states.last, equals(UploadState.completed));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Retry behaviour
  // ═══════════════════════════════════════════════════════════════════════════

  group('Uploader — retry logic', () {
    test('retries failed chunk and succeeds on next attempt', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient()..failThenSucceed(times: 2);
      final store = InMemorySessionStorage();

      final result = await Uploader(_config(file.path, mock, maxRetries: 3))
          .start(storage: store);

      expect(result, isNotNull);
      // 2 failures + 1 success = 3 HTTP calls for 1 chunk
      expect(mock.callCount, equals(3));
    });

    test('throws UploadException after exhausting retries', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient();
      // Always throw
      for (int i = 0; i < 10; i++) mock.throwOnce(Exception('net error'));
      final store = InMemorySessionStorage();

      await expectLater(
        Uploader(_config(file.path, mock, maxRetries: 2))
            .start(storage: store),
        throwsA(isA<UploadException>()),
      );
    });

    test('does not retry on 4xx server error', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient();
      mock.respondWithSequence([MockResponse(statusCode: 404)]);
      final store = InMemorySessionStorage();

      await expectLater(
        Uploader(_config(file.path, mock, maxRetries: 5))
            .start(storage: store),
        throwsA(isA<ChunkException>()),
      );

      // Only 1 call — no retries for 4xx
      expect(mock.callCount, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Resume
  // ═══════════════════════════════════════════════════════════════════════════

  group('Uploader — resume', () {
    test('skips already-completed chunks on resume', () async {
      final file = await createTempFile(2048); // 4 chunks of 512 B
      final store = InMemorySessionStorage();
      final sessionId = 'resume-test-session';

      // First run — complete 2 of 4 chunks, then simulate interruption
      final session = UploadSession(
        sessionId: sessionId,
        filePath: file.path,
        uploadUrl: 'https://upload.test.local/v1/upload',
        fileSize: 2048,
        chunks: List.generate(
          4,
          (i) => ChunkInfo(
            index: i,
            startByte: i * 512,
            endByte: (i + 1) * 512,
            state: i < 2 ? UploadState.completed : UploadState.idle,
          ),
        ),
        storage: store,
      );
      await session.save();

      // Second run — resume
      final mock = MockHttpClient();
      final result = await Uploader(_config(
        file.path,
        mock,
        sessionId: sessionId,
      )).start(storage: store);

      // Only 2 remaining chunks should be sent
      expect(mock.callCount, equals(2));
      expect(result.uploadedThisSession, equals(2));
      expect(result.totalChunks, equals(4));
    });

    test('session is deleted after successful completion', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();
      const id = 'delete-after-done';

      await Uploader(_config(file.path, mock, sessionId: id))
          .start(storage: store);

      expect(await store.exists(id), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Cancel
  // ═══════════════════════════════════════════════════════════════════════════

  group('Uploader — cancel', () {
    test('cancel() throws UploadException from start()', () async {
      final file = await createTempFile(4096); // many chunks
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();
      final uploader = Uploader(_config(file.path, mock, chunkSize: 128));

      final uploadFuture = uploader.start(storage: store);

      // Cancel immediately
      await uploader.cancel();

      await expectLater(uploadFuture, throwsA(isA<UploadException>()));
    });

    test('state is cancelled after cancel()', () async {
      final file = await createTempFile(512);
      final mock = MockHttpClient();
      final uploader = Uploader(_config(file.path, mock));

      await uploader.cancel();
      expect(uploader.state, equals(UploadState.cancelled));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Static convenience method
  // ═══════════════════════════════════════════════════════════════════════════

  group('Uploader.upload() static factory', () {
    test('returns UploadResult on success', () async {
      final file = await createTempFile(1024);
      final mock = MockHttpClient();
      final store = InMemorySessionStorage();

      final result = await Uploader.upload(
        filePath: file.path,
        url: 'https://upload.test.local/v1/upload',
        httpClient: mock,
        storage: store,
        retryDelay: const Duration(milliseconds: 1),
      );

      expect(result, isA<UploadResult>());
      expect(result.totalBytes, equals(1024));
    });
  });
}

