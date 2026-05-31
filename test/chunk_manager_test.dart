import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:quantum_upload/quantum_upload.dart';

void main() {
  // ── Temporary file helpers ────────────────────────────────────────────────

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chunk_manager_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// Creates a temp file of [sizeBytes] filled with sequential byte values.
  Future<File> createTempFile(int sizeBytes, {String name = 'test.bin'}) async {
    final file = File('${tempDir.path}/$name');
    final data = Uint8List(sizeBytes);
    for (int i = 0; i < sizeBytes; i++) {
      data[i] = i % 256;
    }
    await file.writeAsBytes(data);
    return file;
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Static helpers — no I/O required
  // ═════════════════════════════════════════════════════════════════════════

  group('ChunkManager.estimateChunkCount()', () {
    test('exact division → no remainder', () {
      expect(ChunkManager.estimateChunkCount(10 * 1024, 1024), equals(10));
    });

    test('non-exact division → ceiling', () {
      // 10 MB file with 3 MB chunks → ceil(10/3) = 4
      expect(
        ChunkManager.estimateChunkCount(10 * 1024 * 1024, 3 * 1024 * 1024),
        equals(4),
      );
    });

    test('file smaller than one chunk → 1 chunk', () {
      expect(ChunkManager.estimateChunkCount(512, 1024), equals(1));
    });

    test('file exactly one chunk → 1 chunk', () {
      expect(ChunkManager.estimateChunkCount(1024, 1024), equals(1));
    });
  });

  group('ChunkManager.lastChunkSize()', () {
    test('remainder present', () {
      // 11 MB file, 5 MB chunks: last chunk = 1 MB
      expect(
        ChunkManager.lastChunkSize(11 * 1024 * 1024, 5 * 1024 * 1024),
        equals(1 * 1024 * 1024),
      );
    });

    test('no remainder → full chunk size', () {
      expect(ChunkManager.lastChunkSize(10 * 1024, 5 * 1024), equals(5 * 1024));
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // initialize() — file analysis
  // ═════════════════════════════════════════════════════════════════════════

  group('initialize()', () {
    test('throws FileSystemException for missing file', () async {
      final config = UploadConfig(
        filePath: '${tempDir.path}/nonexistent.mp4',
        url: Uri.parse('https://test.local/upload'),
      );
      final manager = ChunkManager(config);

      expect(
        () => manager.initialize(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('throws FileSystemException for empty file', () async {
      final file = File('${tempDir.path}/empty.bin');
      await file.writeAsBytes([]);

      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
      );
      final manager = ChunkManager(config);

      expect(
        () => manager.initialize(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('is idempotent — safe to call twice', () async {
      final file = await createTempFile(1024);
      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
      );
      final manager = ChunkManager(config);
      await manager.initialize();
      await manager.initialize(); // second call must be a no-op
      expect(manager.fileSize, equals(1024));
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // Chunk boundary computation
  // ═════════════════════════════════════════════════════════════════════════

  group('chunk boundary computation', () {
    test('all chunks are contiguous and cover the full file', () async {
      const fileSize = 17 * 1024; // 17 KiB
      const chunkSize = 5 * 1024; // 5 KiB → 4 chunks (5+5+5+2)

      final file = await createTempFile(fileSize);
      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
        chunkSize: chunkSize,
      );
      final manager = ChunkManager(config);
      await manager.initialize();

      final chunks = manager.chunks;

      // Count
      expect(chunks.length, equals(4));

      // Indices are sequential
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].index, equals(i));
      }

      // First chunk starts at 0
      expect(chunks.first.startByte, equals(0));

      // Last chunk ends at fileSize
      expect(chunks.last.endByte, equals(fileSize));

      // Chunks are contiguous
      for (int i = 1; i < chunks.length; i++) {
        expect(chunks[i].startByte, equals(chunks[i - 1].endByte));
      }
    });

    test('last chunk has remainder size', () async {
      const fileSize = 11 * 1024; // 11 KiB
      const chunkSize = 5 * 1024;
      // Last chunk: 11 - 10 = 1 KiB

      final file = await createTempFile(fileSize);
      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
        chunkSize: chunkSize,
      );
      final manager = ChunkManager(config);
      await manager.initialize();

      final last = manager.chunks.last;
      expect(last.size, equals(1 * 1024));
    });

    test('file fits in exactly one chunk', () async {
      const fileSize = 512;
      final file = await createTempFile(fileSize);
      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
        chunkSize: 1024,
      );
      final manager = ChunkManager(config);
      await manager.initialize();

      expect(manager.totalChunks, equals(1));
      expect(manager.chunks[0].startByte, equals(0));
      expect(manager.chunks[0].endByte, equals(fileSize));
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // readChunk() — byte-level accuracy
  // ═════════════════════════════════════════════════════════════════════════

  group('readChunk()', () {
    test('reads correct bytes for each chunk', () async {
      const chunkSize = 100;
      const fileSize = 250; // 3 chunks: [0-100), [100-200), [200-250)
      final file = await createTempFile(fileSize);
      final allBytes = await file.readAsBytes();

      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
        chunkSize: chunkSize,
      );
      final manager = ChunkManager(config);
      await manager.initialize();

      for (int i = 0; i < manager.totalChunks; i++) {
        final chunk = manager.chunks[i];
        final data = await manager.readChunk(i);
        final expected = allBytes.sublist(chunk.startByte, chunk.endByte);
        expect(data, equals(expected));
      }
    });

    test('throws RangeError for out-of-bounds index', () async {
      final file = await createTempFile(1024);
      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
        chunkSize: 512,
      );
      final manager = ChunkManager(config);
      await manager.initialize();

      expect(() => manager.readChunk(999), throwsA(isA<RangeError>()));
      expect(() => manager.readChunk(-1), throwsA(isA<RangeError>()));
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // computeChecksum() — MD5 integrity
  // ═════════════════════════════════════════════════════════════════════════

  group('computeChecksum()', () {
    test('returns 32-character lowercase hex string', () async {
      final file = await createTempFile(1024);
      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
      );
      final manager = ChunkManager(config);
      await manager.initialize();

      final bytes = await manager.readChunk(0);
      final checksum = await manager.computeChecksum(bytes);

      expect(checksum.length, equals(32));
      expect(checksum, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('same bytes → same checksum', () async {
      final file = await createTempFile(1024);
      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
      );
      final manager = ChunkManager(config);
      await manager.initialize();

      final bytes = await manager.readChunk(0);
      final c1 = await manager.computeChecksum(bytes);
      final c2 = await manager.computeChecksum(bytes);

      expect(c1, equals(c2));
    });

    test('different bytes → different checksum', () async {
      final file = await createTempFile(1024);
      final config = UploadConfig(
        filePath: file.path,
        url: Uri.parse('https://test.local/upload'),
        // chunkSize=512 produces two identical chunks because the test file is
        // filled with i%256: [0..255,0..255] / [0..255,0..255] → same MD5.
        // Use a non-power-of-2 size so the two chunk contents differ.
        chunkSize: 500,
      );
      final manager = ChunkManager(config);
      await manager.initialize();

      final bytes0 = await manager.readChunk(0);
      final bytes1 = await manager.readChunk(1);
      final c0 = await manager.computeChecksum(bytes0);
      final c1 = await manager.computeChecksum(bytes1);

      expect(c0, isNot(equals(c1)));
    });
  });
}

