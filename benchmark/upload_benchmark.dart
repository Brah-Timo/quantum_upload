// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:quantum_upload/quantum_upload.dart';

// ─────────────────────────────────────────────────────────────────────────────
// quantum_upload — Performance Benchmark
//
// Measures how quickly the library can:
//   1. Split a file into chunks (ChunkManager)
//   2. Read all chunks from disk (sequential I/O throughput)
//   3. Compute MD5 checksums for all chunks (hashing throughput)
//
// The benchmark intentionally excludes real HTTP I/O so results reflect
// library overhead rather than network speed.
//
// Usage:
//   dart run benchmark/upload_benchmark.dart
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  print('╔══════════════════════════════════════════════════════════╗');
  print('║       quantum_upload  —  Performance Benchmark         ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  const fileSizes = [
    10 * 1024 * 1024,    //  10 MiB
    100 * 1024 * 1024,   // 100 MiB
    500 * 1024 * 1024,   // 500 MiB
  ];

  const chunkSizes = [
    1  * 1024 * 1024,  //  1 MiB
    5  * 1024 * 1024,  //  5 MiB
    10 * 1024 * 1024,  // 10 MiB
  ];

  final tmpDir = await Directory.systemTemp.createTemp('chunked_benchmark_');

  try {
    for (final fileSize in fileSizes) {
      final file = await _createFile(tmpDir, fileSize);

      _header('File size: ${_mb(fileSize)}');

      for (final chunkSize in chunkSizes) {
        await _benchmarkCombo(file, fileSize, chunkSize);
      }

      await file.delete();
      print('');
    }
  } finally {
    await tmpDir.delete(recursive: true);
  }

  print('Benchmark complete.\n');
}

// ─────────────────────────────────────────────────────────────────────────────

Future<void> _benchmarkCombo(File file, int fileSize, int chunkSize) async {
  final config = UploadConfig(
    filePath: file.path,
    url: Uri.parse('https://localhost/upload'), // not used in this benchmark
    chunkSize: chunkSize,
  );
  final manager = ChunkManager(config);
  await manager.initialize();

  final totalChunks = manager.totalChunks;

  // ── Phase 1: chunk boundary computation (already done in initialize) ──────
  // We re-run it to measure only the computation time, not file I/O.
  final t0 = _now();
  final dummyConfig = UploadConfig(
    filePath: file.path,
    url: Uri.parse('https://localhost/upload'),
    chunkSize: chunkSize,
  );
  final dummyManager = ChunkManager(dummyConfig);
  await dummyManager.initialize(); // includes boundary computation
  final splitMs = _elapsed(t0);

  // ── Phase 2: read all chunks sequentially ─────────────────────────────────
  final t1 = _now();
  for (int i = 0; i < totalChunks; i++) {
    await manager.readChunk(i);
  }
  final readMs = _elapsed(t1);

  // ── Phase 3: compute checksums for all chunks ─────────────────────────────
  final t2 = _now();
  for (int i = 0; i < totalChunks; i++) {
    final bytes = await manager.readChunk(i);
    await manager.computeChecksum(bytes);
  }
  final checksumMs = _elapsed(t2);

  // ── Results ────────────────────────────────────────────────────────────────
  final readThroughput  = fileSize / (readMs     / 1000);
  final hashThroughput  = fileSize / (checksumMs / 1000);

  print('  Chunk size: ${_mb(chunkSize).padRight(8)}  '
        'chunks=${totalChunks.toString().padLeft(5)}  │  '
        'split=${splitMs.toStringAsFixed(1).padLeft(6)} ms  │  '
        'read=${readMs.toStringAsFixed(1).padLeft(7)} ms  '
        '(${_mbPerSec(readThroughput).padLeft(8)})  │  '
        'checksum=${checksumMs.toStringAsFixed(1).padLeft(7)} ms  '
        '(${_mbPerSec(hashThroughput).padLeft(8)})');
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

double _now() => DateTime.now().microsecondsSinceEpoch / 1000.0; // ms
double _elapsed(double start) => _now() - start;

String _mb(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MiB';

String _mbPerSec(double bps) =>
    '${(bps / (1024 * 1024)).toStringAsFixed(0)} MiB/s';

void _header(String title) {
  print('┌─────────────────────────────────────────────────────────┐');
  print('│  $title');
  print('└─────────────────────────────────────────────────────────┘');
}

Future<File> _createFile(Directory dir, int sizeBytes) async {
  final file = File('${dir.path}/bench_${sizeBytes}.bin');
  final sink = file.openWrite();

  const blockSize = 256 * 1024; // 256 KiB blocks
  final block = Uint8List(blockSize)
    ..fillRange(0, blockSize, 0x41); // 'A' bytes

  int remaining = sizeBytes;
  while (remaining > 0) {
    final toWrite = remaining < blockSize ? remaining : blockSize;
    sink.add(block.sublist(0, toWrite));
    remaining -= toWrite;
  }

  await sink.flush();
  await sink.close();
  return file;
}

