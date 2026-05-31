# quantum_upload 📦

[![pub version](https://img.shields.io/pub/v/quantum_upload?style=flat-square)](https://pub.dev/packages/quantum_upload)
[![Dart SDK](https://img.shields.io/badge/Dart-%3E%3D3.0.0-blue?style=flat-square)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Test coverage](https://img.shields.io/badge/coverage-100%25-brightgreen?style=flat-square)](#tests)

> **Upload large files over unreliable networks — reliably.**  
> Splits. Persists. Resumes. Works with any HTTP server.

---

## The Problem

You're uploading a 2 GB video. The network drops at 99%.  
You start again from zero. You cry.

## The Solution

`quantum_upload` splits the file into small pieces, confirms each one with
the server, and saves progress locally. When the network drops, it picks up
from the last confirmed piece — not from the beginning.

---

## Features

| Feature | Detail |
|---------|--------|
| ✂️ **Smart chunking** | Configurable chunk size (default 5 MiB); last chunk gets the remainder |
| 💾 **Persistent sessions** | Survives app kill + device restart via `SharedPreferences` |
| 🔄 **True resume** | Skips already-confirmed chunks — zero redundant uploads |
| 🔁 **Exponential back-off** | `delay_n = baseDelay × 2^(n−1)`, capped at 30 s |
| 🔐 **MD5 integrity check** | Every chunk is hashed before sending |
| 📊 **Rich progress** | Percent, EMA speed, ETA, uploaded/total formatted |
| ⏸️ **Pause / resume / cancel** | Full lifecycle control between chunks |
| 🌐 **Server-agnostic** | Standard HTTP multipart `POST` — no special protocol needed |
| 🔌 **Pluggable storage** | Replace `SharedPreferences` with any `SessionStorage` |
| 🧪 **100 % unit-tested** | Every layer tested in isolation with a mock HTTP client |

---

## Installation

```yaml
dependencies:
  quantum_upload: ^1.0.0
```

```bash
dart pub get
```

---

## Quick Start

```dart
import 'package:quantum_upload/quantum_upload.dart';

final result = await Uploader.upload(
  filePath: '/path/to/video.mp4',
  url: 'https://api.example.com/upload',
  headers: {'Authorization': 'Bearer $token'},
  onProgress: (pct) => print('${pct.toStringAsFixed(1)} %'),
);

print('Done in ${result.duration.inSeconds}s @ ${result.speedMbps}');
```

---

## Advanced Usage

### Full configuration

```dart
final config = UploadConfig(
  filePath   : '/path/to/video.mp4',
  url        : Uri.parse('https://api.example.com/upload'),
  chunkSize  : 10 * 1024 * 1024,          // 10 MiB chunks
  maxRetries : 5,
  retryDelay : const Duration(seconds: 2), // 2 s → 4 s → 8 s → …
  headers    : {'Authorization': 'Bearer $token'},
  sessionId  : savedSessionId,             // null = fresh upload
  onProgress   : (pct)          => setState(() => _progress = pct),
  onChunkRetry : (chunk, attempt) => print('Retrying chunk $chunk ($attempt)'),
  onComplete   : (result)        => print('Done! ${result.speedMbps}'),
  onError      : (err)           => showErrorDialog(err.message),
);

final uploader = Uploader(config);
await uploader.start();
```

### Pause and resume

```dart
final uploader = Uploader(config);
unawaited(uploader.start());   // fire and forget in background

// From UI buttons:
uploader.pause();              // stops after current chunk finishes
uploader.resume();             // continues immediately
await uploader.cancel();       // permanent — cleans up session
```

### Cross-session resume (app restart)

```dart
// ── Run 1 — save the session ID ─────────────────────────────────
final uploader = Uploader(config);
await prefs.setString('uploadSession', uploader.sessionId);
await uploader.start();

// ── Run 2 — resume automatically ────────────────────────────────
await Uploader.upload(
  filePath  : '/path/to/video.mp4',
  url       : 'https://api.example.com/upload',
  sessionId : prefs.getString('uploadSession'),  // ← magic
);
```

### Rich progress stream

```dart
uploader.progressStream.listen((snap) {
  print(
    '[${snap.percent.toStringAsFixed(1).padLeft(5)}%]  '
    '${snap.uploadedFormatted} / ${snap.totalFormatted}  '
    '@ ${snap.speedMbps}  ETA ${snap.etaFormatted}',
  );
});
```

Sample output:
```
[ 12.5%]    12.50 MiB /  100.00 MiB  @  8.32 MB/s  ETA 10:38
[ 25.0%]    25.00 MiB /  100.00 MiB  @  9.01 MB/s  ETA 08:21
```

---

## How It Works

```
Uploader.start()
│
├─ ChunkManager.initialize()
│   └─ compute chunk boundaries: [(0, 5M), (5M, 10M), …]
│
├─ UploadSession.restore(sessionId) or create fresh
│   └─ persisted in SharedPreferences as JSON
│
└─ for each pending chunk:
    ├─ readChunk(i)           — RandomAccessFile.setPosition + read
    ├─ computeChecksum(data)  — MD5 hex
    ├─ RetryPolicy.executeChunk(() => UploadRequest.send(…))
    │   └─ on success: markChunkCompleted(i) + session.save()
    │   └─ on fail:    exponential back-off → retry
    └─ progressTracker.addBytes(chunkSize)

→ UploadResult  (session deleted from storage)
```

---

## HTTP Wire Format

Every chunk is a standard `multipart/form-data POST`:

```
POST /upload
Content-Type: multipart/form-data; boundary=…

X-Session-Id:     c3d4e5f6-…
X-Chunk-Index:    3
X-Total-Chunks:   40
X-Chunk-Checksum: a3f4b2c1d5e6…   (MD5 hex)
X-File-Size:      209715200
Content-Range:    bytes 15728640-20971519/209715200
Authorization:    Bearer <your-token>   (from config.headers)

--boundary
Content-Disposition: form-data; name="chunk"; filename="chunk_3"

<raw 5 MiB bytes>
--boundary--
```

See `example/server_example/server.js` for a Node.js reference implementation.

---

## Package Architecture

```
lib/
├── quantum_upload.dart       ← barrel (one import for everything)
└── src/
    ├── uploader.dart           ← main orchestrator — start/pause/resume/cancel
    ├── chunk_manager.dart      ← file splitting + chunk reading + MD5
    ├── upload_session.dart     ← persistent per-chunk state
    ├── upload_request.dart     ← HTTP multipart builder + sender
    ├── retry_policy.dart       ← exponential back-off executor
    ├── progress_tracker.dart   ← EMA speed, ETA, stream emitter
    ├── models/
    │   ├── upload_config.dart  ← immutable configuration value object
    │   ├── upload_state.dart   ← enum: idle|uploading|paused|…|completed
    │   ├── chunk_info.dart     ← byte-range + state + checksum per chunk
    │   └── upload_result.dart  ← final summary (speed, chunks, duration)
    ├── storage/
    │   ├── session_storage.dart        ← abstract interface
    │   └── shared_prefs_storage.dart   ← default implementation
    └── exceptions/
        ├── upload_exception.dart   ← base class
        ├── chunk_exception.dart    ← per-chunk failure (HTTP status, body)
        └── session_exception.dart  ← storage failure
```

---

## Comparison

| Feature | **quantum_upload** | flutter_upchunk | tus_client_dart |
|---------|:---:|:---:|:---:|
| Pure Dart (no Flutter dep.) | ✅ | ✅ | ✅ |
| Resume after app restart | ✅ | ❌ | ✅ |
| Works with any HTTP server | ✅ | ✅ | ❌ requires tus server |
| MD5 checksum per chunk | ✅ | ❌ | ❌ |
| Exponential back-off | ✅ | ❌ | ❌ |
| Pause / resume | ✅ | ✅ | ✅ |
| Progress stream (speed + ETA) | ✅ | ❌ | ❌ |
| Pluggable session storage | ✅ | ❌ | ❌ |
| 4xx vs 5xx retry distinction | ✅ | ❌ | ❌ |
| Unit test coverage | ✅ 100 % | partial | partial |

---

## Tests

```bash
dart test
dart test --coverage=coverage
dart pub global run coverage:format_coverage --lcov \
    --in=coverage --out=lcov.info --report-on=lib
```

Test suite covers:

- `chunk_manager_test.dart` — boundary computation, byte reading, checksums
- `upload_session_test.dart` — persistence, restore, mutation
- `retry_policy_test.dart` — should-retry logic, delay formula, executors
- `progress_tracker_test.dart` — EMA speed, ETA, stream emissions
- `uploader_test.dart` — end-to-end with `MockHttpClient`

---

## Contributing

1. Fork the repo and create a feature branch.
2. Write tests for every new behaviour.
3. Run `dart analyze && dart test` — both must pass.
4. Submit a pull request with a clear description.

---

## License

MIT © 2026 — see [LICENSE](LICENSE).

