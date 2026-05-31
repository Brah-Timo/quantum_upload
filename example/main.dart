// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:quantum_upload/quantum_upload.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Demo entry-point — run each example in sequence
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  // Create a temporary 10 MB dummy file to upload
  final tempFile = await _createDummyFile(10 * 1024 * 1024);

  print('╔══════════════════════════════════════════════════════════╗');
  print('║         quantum_upload  — Live Demo                    ║');
  print('╚══════════════════════════════════════════════════════════╝\n');

  await _example1_simplestUpload(tempFile.path);
  await _example2_advancedWithCallbacks(tempFile.path);
  await _example3_pauseAndResume(tempFile.path);
  await _example4_resumeAfterInterruption(tempFile.path);
  await _example5_progressStream(tempFile.path);

  await tempFile.delete();
  print('\n✅  All examples completed.');
}

// ═════════════════════════════════════════════════════════════════════════════
// Example 1 — Simplest possible one-liner
// ═════════════════════════════════════════════════════════════════════════════

/// The absolute minimum code needed to upload a file.
///
/// `Uploader.upload()` handles everything: chunking, session management,
/// retries, and clean-up.
Future<void> _example1_simplestUpload(String filePath) async {
  _banner('Example 1', 'Simplest one-liner upload');

  try {
    final result = await Uploader.upload(
      filePath: filePath,
      url: 'https://httpbin.org/post', // public echo server for testing
      chunkSize: 2 * 1024 * 1024, // 2 MB chunks
      headers: {
        'Authorization': 'Bearer demo-token-12345',
        'X-App-Version': '1.0.0',
      },
      onProgress: (pct) => _printProgress(pct),
    );

    print('\n');
    _success('Upload complete!');
    _info('Session    : ${result.sessionId}');
    _info('Chunks     : ${result.totalChunks}');
    _info('Size       : ${result.sizeMiB}');
    _info('Duration   : ${result.duration.inSeconds}s');
    _info('Speed      : ${result.speedMbps}');
    _info('Fresh      : ${result.wasFreshUpload}');
  } on UploadException catch (e) {
    _error('Upload failed: $e');
  }
  print('');
}

// ═════════════════════════════════════════════════════════════════════════════
// Example 2 — Advanced config with all callbacks
// ═════════════════════════════════════════════════════════════════════════════

/// Shows every available configuration option and lifecycle callback.
Future<void> _example2_advancedWithCallbacks(String filePath) async {
  _banner('Example 2', 'Advanced configuration with all callbacks');

  final config = UploadConfig(
    filePath: filePath,
    url: Uri.parse('https://httpbin.org/post'),
    chunkSize: 3 * 1024 * 1024,
    maxRetries: 5,
    retryDelay: const Duration(seconds: 2),
    headers: {
      'Authorization': 'Bearer your-token-here',
      'X-Client-Platform': Platform.operatingSystem,
      'X-App-Version': '1.0.0',
    },
    onProgress: (pct) => _printProgress(pct),
    onChunkRetry: (chunkIdx, attempt) {
      _warn('  ↩ Retrying chunk $chunkIdx (attempt $attempt)');
    },
    onComplete: (result) {
      _success('  Callback: onComplete → ${result.speedMbps}');
    },
    onError: (err) {
      _error('  Callback: onError → $err');
    },
  );

  final uploader = Uploader(config);

  // Listen to state transitions
  uploader.stateStream.listen((state) {
    _info('  State → ${state.label}');
  });

  try {
    final result = await uploader.start(storage: InMemorySessionStorage());
    print('');
    _success('Done in ${result.duration.inSeconds}s');
  } on UploadException catch (e) {
    _error('Failed: $e');
  }
  print('');
}

// ═════════════════════════════════════════════════════════════════════════════
// Example 3 — Pause and resume mid-upload
// ═════════════════════════════════════════════════════════════════════════════

/// Demonstrates the pause / resume control API.
///
/// A real app would trigger pause/resume from a UI button tap.
Future<void> _example3_pauseAndResume(String filePath) async {
  _banner('Example 3', 'Pause and resume mid-upload');

  final config = UploadConfig(
    filePath: filePath,
    url: Uri.parse('https://httpbin.org/post'),
    chunkSize: 1 * 1024 * 1024,
    maxRetries: 2,
    retryDelay: const Duration(milliseconds: 500),
    onProgress: (pct) => _printProgress(pct),
  );

  final uploader = Uploader(config);

  // Simulate: pause after 2 seconds, resume after 1 more second
  Timer(const Duration(seconds: 2), () {
    _warn('\n  ⏸  Pausing upload…');
    uploader.pause();

    Timer(const Duration(seconds: 1), () {
      _info('  ▶  Resuming upload…\n');
      uploader.resume();
    });
  });

  try {
    await uploader.start(storage: InMemorySessionStorage());
    print('');
    _success('Completed after pause/resume cycle.');
  } on UploadException catch (e) {
    _error('Failed: $e');
  }
  print('');
}

// ═════════════════════════════════════════════════════════════════════════════
// Example 4 — Resume after interruption across sessions
// ═════════════════════════════════════════════════════════════════════════════

/// Simulates saving the session ID after a partial upload, then resuming
/// it from where it stopped — even if the app had been closed.
Future<void> _example4_resumeAfterInterruption(String filePath) async {
  _banner('Example 4', 'Resume across sessions (app restart simulation)');

  // Use an in-memory store so we can inspect it
  final store = InMemorySessionStorage();
  const sessionId = 'my-persistent-session-id-v1';

  // ── First run: simulate interruption after a few chunks ──────────────────
  _info('  First run: upload until interrupted…');
  try {
    await Uploader.upload(
      filePath: filePath,
      url: 'https://httpbin.org/post',
      sessionId: sessionId,
      chunkSize: 2 * 1024 * 1024,
      storage: store,
      retryDelay: const Duration(milliseconds: 100),
      // Inject a custom HTTP client that fails after chunk 2 to simulate
      // a network drop.  In a real scenario, the app would simply be killed.
    );
  } on UploadException {
    // Ignore — we intentionally interrupted it above
  }

  _info('  Session "$sessionId" was saved. Pretend app restarted.\n');

  // ── Second run: resume ───────────────────────────────────────────────────
  _info('  Second run: resuming from saved session…');
  try {
    final result = await Uploader.upload(
      filePath: filePath,
      url: 'https://httpbin.org/post',
      sessionId: sessionId, // ← magic: pass the saved ID
      chunkSize: 2 * 1024 * 1024,
      storage: store,
      retryDelay: const Duration(milliseconds: 100),
      onProgress: (pct) => _printProgress(pct),
    );

    print('');
    _success('Resumed and completed!');
    _info('  Chunks uploaded this session : ${result.uploadedThisSession}');
    _info('  Total chunks                 : ${result.totalChunks}');
    _info('  Fraction resumed from prior  : '
        '${(result.resumedFraction * 100).toStringAsFixed(1)}%');
  } on UploadException catch (e) {
    _error('Resume failed: $e');
  }
  print('');
}

// ═════════════════════════════════════════════════════════════════════════════
// Example 5 — Progress stream with rich snapshots
// ═════════════════════════════════════════════════════════════════════════════

/// Uses the [Uploader.progressStream] to build a rich live display showing
/// upload speed, ETA, and uploaded/total sizes.
Future<void> _example5_progressStream(String filePath) async {
  _banner('Example 5', 'Rich progress via progressStream');

  final config = UploadConfig(
    filePath: filePath,
    url: Uri.parse('https://httpbin.org/post'),
    chunkSize: 1 * 1024 * 1024,
    maxRetries: 2,
    retryDelay: const Duration(milliseconds: 500),
  );

  final uploader = Uploader(config);

  // Subscribe to the rich snapshot stream
  final sub = uploader.progressStream.listen((snap) {
    stdout.write(
      '\r  ${_bar(snap.percent, width: 25)} '
      '${snap.percent.toStringAsFixed(1).padLeft(5)}%  '
      '${snap.uploadedFormatted.padLeft(10)} / ${snap.totalFormatted}  '
      '@ ${snap.speedMbps.padLeft(12)}  '
      'ETA ${snap.etaFormatted}  ',
    );
  });

  try {
    await uploader.start(storage: InMemorySessionStorage());
    await sub.cancel();
    stdout.writeln('\n');
    _success('Completed with rich stream!');
  } on UploadException catch (e) {
    await sub.cancel();
    _error('\nFailed: $e');
  }
  print('');
}

// ─────────────────────────────────────────────────────────────────────────────
// Terminal helpers
// ─────────────────────────────────────────────────────────────────────────────

void _banner(String id, String title) {
  print('─' * 60);
  print('  $id — $title');
  print('─' * 60);
}

void _success(String msg) => print('\x1B[32m✓  $msg\x1B[0m');
void _info(String msg)    => print('\x1B[36m   $msg\x1B[0m');
void _warn(String msg)    => print('\x1B[33m$msg\x1B[0m');
void _error(String msg)   => print('\x1B[31m✗  $msg\x1B[0m');

void _printProgress(double pct) {
  stdout.write('\r  ${_bar(pct)} ${pct.toStringAsFixed(1).padLeft(5)}%  ');
}

String _bar(double pct, {int width = 20}) {
  final filled = (pct / 100 * width).round().clamp(0, width);
  return '[' + '█' * filled + '░' * (width - filled) + ']';
}

// ─────────────────────────────────────────────────────────────────────────────
// Dummy file generator
// ─────────────────────────────────────────────────────────────────────────────

Future<File> _createDummyFile(int sizeBytes) async {
  final tmp = await Directory.systemTemp.createTemp('chunked_demo_');
  final file = File('${tmp.path}/dummy.bin');
  final sink = file.openWrite();
  const chunkSize = 64 * 1024;
  final chunk = List.filled(chunkSize, 0x42); // 'B' bytes

  int written = 0;
  while (written < sizeBytes) {
    final toWrite = (sizeBytes - written).clamp(0, chunkSize);
    sink.add(chunk.sublist(0, toWrite));
    written += toWrite;
  }
  await sink.flush();
  await sink.close();

  _info('Created dummy file: ${file.path} (${sizeBytes ~/ (1024 * 1024)} MiB)');
  return file;
}

