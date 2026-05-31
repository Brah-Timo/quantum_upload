# Getting Started with `quantum_upload`

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  quantum_upload: ^1.0.0
```

Then run:

```bash
dart pub get
# or for Flutter:
flutter pub get
```

## Basic Concepts

### What is a chunk?

A chunk is a fixed-size byte range of the original file.  
Given a 10 MiB file and a 3 MiB chunk size:

```
Chunk 0 → bytes 0       – 3,145,727    (3 MiB)
Chunk 1 → bytes 3145728 – 6,291,455    (3 MiB)
Chunk 2 → bytes 6291456 – 9,437,183    (3 MiB)
Chunk 3 → bytes 9437184 – 10,485,759   (1 MiB — remainder)
```

`totalChunks = ⌈ fileSize / chunkSize ⌉ = ⌈ 10 / 3 ⌉ = 4`

### What is a session?

A session is a persistent record of which chunks have been successfully
uploaded. It is keyed by a UUID and stored in `SharedPreferences`.

If the app is killed after chunk 2 is confirmed, the next run finds the
session and starts from chunk 3 — no redundant uploads.

---

## Quick Start

```dart
import 'package:quantum_upload/quantum_upload.dart';

// Simplest possible call:
final result = await Uploader.upload(
  filePath: '/path/to/large_video.mp4',
  url: 'https://api.example.com/upload',
  onProgress: (pct) => print('${pct.toStringAsFixed(1)}%'),
);

print('Done! ${result.speedMbps} average speed');
```

---

## Configuration Options

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `filePath` | `String` | **required** | Absolute path to source file |
| `url` | `Uri` | **required** | Upload endpoint |
| `chunkSize` | `int` | `5 MiB` | Bytes per chunk |
| `maxRetries` | `int` | `3` | Retries per chunk before failing |
| `retryDelay` | `Duration` | `2s` | Base delay (exponential back-off) |
| `headers` | `Map<String,String>` | `{}` | Extra HTTP headers |
| `sessionId` | `String?` | `null` | Pass saved ID to resume |
| `onProgress` | `void Function(double)` | `null` | 0–100 progress callback |
| `onChunkRetry` | `void Function(int, int)` | `null` | Retry notification |
| `onComplete` | `void Function(UploadResult)` | `null` | Success callback |
| `onError` | `void Function(UploadException)` | `null` | Error callback |

---

## Resuming Uploads

```dart
// ── Step 1: Start the upload and save the session ID ────────────────
final uploader = Uploader(UploadConfig(
  filePath: '/path/to/file.zip',
  url: Uri.parse('https://api.example.com/upload'),
));

final sessionId = uploader.sessionId; // save this!
await prefs.setString('activeUploadSession', sessionId);

await uploader.start();

// ── Step 2: On the next run, pass the saved session ID ──────────────
final savedId = prefs.getString('activeUploadSession');
if (savedId != null) {
  await Uploader.upload(
    filePath: '/path/to/file.zip',
    url: 'https://api.example.com/upload',
    sessionId: savedId,                    // ← resumes here
    onProgress: (p) => print('$p%'),
  );
}
```

---

## Pause and Resume

```dart
final uploader = Uploader(config);
unawaited(uploader.start());

// From a UI button:
uploader.pause();   // stops after current chunk
uploader.resume();  // continues
```

---

## Using the Progress Stream

```dart
final uploader = Uploader(config);

uploader.progressStream.listen((snapshot) {
  print(
    '${snapshot.percent.toStringAsFixed(1)}%  '
    '${snapshot.uploadedFormatted} / ${snapshot.totalFormatted}  '
    '@ ${snapshot.speedMbps}  '
    'ETA ${snapshot.etaFormatted}',
  );
});

await uploader.start();
```

---

## Custom Session Storage

Replace `SharedPreferences` with any backend:

```dart
class SecureStorage implements SessionStorage {
  final _store = FlutterSecureStorage();

  @override
  Future<void> write(String key, String value) =>
      _store.write(key: 'upload_$key', value: value);

  @override
  Future<String?> read(String key) =>
      _store.read(key: 'upload_$key');

  @override
  Future<void> delete(String key) =>
      _store.delete(key: 'upload_$key');

  @override
  Future<bool> exists(String key) async =>
      (await _store.read(key: 'upload_$key')) != null;

  @override
  Future<List<String>> listKeys() async {
    final all = await _store.readAll();
    return all.keys
        .where((k) => k.startsWith('upload_'))
        .map((k) => k.substring('upload_'.length))
        .toList();
  }

  @override
  Future<void> clear() async {
    final keys = await listKeys();
    for (final k in keys) await delete(k);
  }
}

// Inject it:
await uploader.start(storage: SecureStorage());
```

---

## Server-Side Requirements

The server must accept `multipart/form-data POST` requests with:

| HTTP Header | Description |
|-------------|-------------|
| `X-Session-Id` | Identifies the upload session |
| `X-Chunk-Index` | 0-based position of this chunk |
| `X-Total-Chunks` | Total expected chunks |
| `X-Chunk-Checksum` | MD5 hex for integrity check |
| `X-File-Size` | Total file size in bytes |
| `Content-Range` | `bytes start-end/total` |

Form field: `chunk` — the raw chunk bytes.

See `example/server_example/server.js` for a complete Node.js reference.

---

## Error Handling

```dart
try {
  await Uploader.upload(filePath: '…', url: '…');
} on ChunkException catch (e) {
  // A specific chunk failed permanently
  print('Chunk ${e.chunkIndex} failed: HTTP ${e.statusCode}');
  print('Server said: ${e.responseBody}');
} on SessionException catch (e) {
  // Could not save/load session state
  print('Session error: ${e.message}  corrupt=${e.isCorrupt}');
} on UploadException catch (e) {
  // General upload failure
  print('Upload failed: ${e.message}  session=${e.sessionId}');
}
```

---

## FAQ

**Q: Can I use this without Flutter?**  
A: Yes — `quantum_upload` is pure Dart with no Flutter dependency.

**Q: Does it work on the web?**  
A: The `dart:io` dependency means it targets VM targets only (iOS, Android, 
desktop, CLI). Web support would require an alternative file-reading strategy.

**Q: What if the server rejects a chunk checksum?**  
A: The server should return a non-2xx status (e.g. 422). The library treats 
this as a `ChunkException` and retries according to `maxRetries`.

**Q: How do I delete an abandoned session?**  
A: ```dart
await InMemorySessionStorage().delete(savedSessionId);
// or for SharedPrefs:
await SharedPrefsStorage().delete(savedSessionId);
```

