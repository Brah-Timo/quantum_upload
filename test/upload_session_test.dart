import 'package:test/test.dart';
import 'package:quantum_upload/quantum_upload.dart';

// Uses InMemorySessionStorage (defined in session_storage.dart) so no disk I/O.

UploadSession _makeSession({
  String sessionId = 'test-session-001',
  int chunkCount = 5,
  InMemorySessionStorage? storage,
}) {
  final store = storage ?? InMemorySessionStorage();
  final chunks = List.generate(
    chunkCount,
    (i) => ChunkInfo(
      index: i,
      startByte: i * 1024,
      endByte: (i + 1) * 1024,
    ),
  );
  return UploadSession(
    sessionId: sessionId,
    filePath: '/fake/video.mp4',
    uploadUrl: 'https://api.test.local/upload',
    fileSize: chunkCount * 1024,
    chunks: chunks,
    storage: store,
  );
}

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // Derived getters — no I/O
  // ═══════════════════════════════════════════════════════════════════════════

  group('UploadSession getters', () {
    test('nextChunkIndex is 0 for a fresh session', () {
      final s = _makeSession();
      expect(s.nextChunkIndex, equals(0));
    });

    test('nextChunkIndex skips completed chunks', () {
      final s = _makeSession(chunkCount: 5);
      s.markChunkCompleted(0);
      s.markChunkCompleted(1);
      s.markChunkCompleted(2);
      expect(s.nextChunkIndex, equals(3));
    });

    test('nextChunkIndex equals chunkCount when all done', () {
      final s = _makeSession(chunkCount: 3);
      s.markChunkCompleted(0);
      s.markChunkCompleted(1);
      s.markChunkCompleted(2);
      expect(s.nextChunkIndex, equals(3));
      expect(s.isComplete, isTrue);
    });

    test('uploadedChunks counts only completed chunks', () {
      final s = _makeSession(chunkCount: 4);
      s.markChunkCompleted(0);
      s.markChunkCompleted(2);
      expect(s.uploadedChunks, equals(2));
    });

    test('uploadedBytes sums sizes of completed chunks', () {
      final s = _makeSession(chunkCount: 4); // each chunk = 1 KiB
      s.markChunkCompleted(0);
      s.markChunkCompleted(3);
      expect(s.uploadedBytes, equals(2 * 1024));
    });

    test('progressFraction is 0 for empty session', () {
      final s = _makeSession(chunkCount: 4);
      expect(s.progressFraction, equals(0.0));
    });

    test('progressFraction is 1.0 when complete', () {
      final s = _makeSession(chunkCount: 3);
      for (int i = 0; i < 3; i++) s.markChunkCompleted(i);
      expect(s.progressFraction, closeTo(1.0, 0.001));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Mutation
  // ═══════════════════════════════════════════════════════════════════════════

  group('markChunkCompleted / markChunkFailed / resetChunk', () {
    test('markChunkCompleted sets state to completed', () {
      final s = _makeSession();
      s.markChunkCompleted(1);
      expect(s.chunks[1].state, equals(UploadState.completed));
    });

    test('markChunkCompleted updates lastActivityAt', () {
      final s = _makeSession();
      expect(s.lastActivityAt, isNull);
      s.markChunkCompleted(0);
      expect(s.lastActivityAt, isNotNull);
    });

    test('markChunkFailed sets state to failed', () {
      final s = _makeSession();
      s.markChunkFailed(2);
      expect(s.chunks[2].state, equals(UploadState.failed));
    });

    test('markChunkFailed increments attempts counter', () {
      final s = _makeSession();
      s.markChunkFailed(0);
      s.markChunkFailed(0);
      expect(s.chunks[0].attempts, equals(2));
    });

    test('resetChunk sets state back to idle', () {
      final s = _makeSession();
      s.markChunkFailed(1);
      s.resetChunk(1);
      expect(s.chunks[1].state, equals(UploadState.idle));
    });

    test('out-of-bounds index throws RangeError', () {
      final s = _makeSession(chunkCount: 3);
      expect(() => s.markChunkCompleted(99), throwsA(isA<RangeError>()));
      expect(() => s.markChunkFailed(-1), throwsA(isA<RangeError>()));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Persistence — save / restore / delete
  // ═══════════════════════════════════════════════════════════════════════════

  group('save() / restore() / delete()', () {
    test('restore() returns null when no session is stored', () async {
      final store = InMemorySessionStorage();
      final result = await UploadSession.restore(
        sessionId: 'nonexistent',
        storage: store,
      );
      expect(result, isNull);
    });

    test('save() persists session and restore() recreates it', () async {
      final store = InMemorySessionStorage();
      final original = _makeSession(storage: store);
      original.markChunkCompleted(0);
      original.markChunkCompleted(1);
      await original.save();

      final restored = await UploadSession.restore(
        sessionId: original.sessionId,
        storage: store,
      );

      expect(restored, isNotNull);
      expect(restored!.sessionId, equals(original.sessionId));
      expect(restored.uploadedChunks, equals(2));
      expect(restored.chunks[0].state, equals(UploadState.completed));
      expect(restored.chunks[1].state, equals(UploadState.completed));
      expect(restored.chunks[2].state, equals(UploadState.idle));
    });

    test('restored session has correct nextChunkIndex', () async {
      final store = InMemorySessionStorage();
      final s = _makeSession(chunkCount: 5, storage: store);
      s.markChunkCompleted(0);
      s.markChunkCompleted(1);
      s.markChunkCompleted(2);
      await s.save();

      final r = await UploadSession.restore(
        sessionId: s.sessionId,
        storage: store,
      );
      expect(r!.nextChunkIndex, equals(3));
    });

    test('delete() removes session from storage', () async {
      final store = InMemorySessionStorage();
      final s = _makeSession(storage: store);
      await s.save();
      expect(await store.exists(s.sessionId), isTrue);

      await s.delete();
      expect(await store.exists(s.sessionId), isFalse);
    });

    test('restore() throws SessionException on corrupt JSON', () async {
      final store = InMemorySessionStorage();
      await store.write('corrupt-id', '{invalid json{{{{');

      expect(
        () => UploadSession.restore(
          sessionId: 'corrupt-id',
          storage: store,
        ),
        throwsA(isA<SessionException>()),
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // toString
  // ═══════════════════════════════════════════════════════════════════════════

  group('toString()', () {
    test('contains session ID', () {
      final s = _makeSession(sessionId: 'abc-123');
      expect(s.toString(), contains('abc-123'));
    });

    test('contains chunk progress', () {
      final s = _makeSession(chunkCount: 5);
      s.markChunkCompleted(0);
      s.markChunkCompleted(1);
      expect(s.toString(), contains('2/5'));
    });
  });
}

