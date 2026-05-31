# Changelog

All notable changes to `quantum_upload` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-05-30

### 🎉 Initial stable release

#### Added

**Core upload engine**
- `Uploader` — main orchestrator class with `start()`, `pause()`, `resume()`,
  `cancel()`, and `dispose()`.
- `Uploader.upload()` — static convenience factory for one-liner usage.
- `stateStream` — broadcast `Stream<UploadState>` for UI state binding.
- `progressStream` — broadcast `Stream<ProgressSnapshot>` with speed and ETA.

**Chunking**
- `ChunkManager` — splits files into configurable byte ranges using
  `RandomAccessFile` for memory-efficient reading.
- `ChunkManager.estimateChunkCount()` — static helper for pre-flight UI labels.
- `ChunkManager.lastChunkSize()` — static remainder calculator.

**Session management**
- `UploadSession` — full per-chunk state tracking; serialises to/from JSON.
- `UploadSession.restore()` — resumes a session from any `SessionStorage`.
- Auto-delete session on successful completion; session survives app kill.

**HTTP transport**
- `UploadRequest` — builds and sends `multipart/form-data POST` with library
  headers: `X-Session-Id`, `X-Chunk-Index`, `X-Total-Chunks`,
  `X-Chunk-Checksum`, `X-File-Size`, `Content-Range`.

**Retry logic**
- `RetryPolicy` — exponential back-off: `delay_n = baseDelay × 2^(n−1)`,
  capped at 30 seconds.
- `RetryPolicy.executeChunk()` — HTTP-aware variant that skips retries on
  4xx errors (client errors are not transient).

**Progress tracking**
- `ProgressTracker` — EMA-smoothed speed estimate (configurable α),
  ETA derivation, `ProgressSnapshot` stream.
- `ProgressSnapshot` — immutable value object with `speedMbps`, `etaFormatted`,
  `uploadedFormatted`, `totalFormatted`, `remainingBytes`.

**Models**
- `UploadConfig` — immutable, copyable configuration with `copyWith()`.
- `UploadState` — 8-value enum with `.label`, `.isActive`, `.isTerminal`,
  `.canResume` extensions.
- `ChunkInfo` — immutable byte-range record with JSON round-trip.
- `UploadResult` — upload summary: `speedMbps`, `sizeMiB`, `wasFreshUpload`,
  `resumedFraction`.

**Exceptions**
- `UploadException` — base class carrying `message`, `sessionId`, `cause`.
- `ChunkException` — adds `chunkIndex`, `statusCode`, `responseBody`,
  `isServerError`, `isClientError`, `isNetworkError`.
- `SessionException` — adds `isCorrupt` flag for version-mismatch detection.

**Storage**
- `SessionStorage` — abstract interface for pluggable backends.
- `SharedPrefsStorage` — default implementation using `shared_preferences`;
  includes `migrateFrom()` helper.
- `InMemorySessionStorage` — lightweight in-memory implementation for tests.

**Tests (100 % coverage)**
- `chunk_manager_test.dart` — 12 test cases covering boundary computation,
  byte accuracy, checksum correctness, and edge cases.
- `upload_session_test.dart` — 12 test cases covering getters, mutations,
  save/restore/delete, and corrupt-data handling.
- `retry_policy_test.dart` — 10 test cases covering delay formula,
  should-retry logic, HTTP-aware executor, and back-off behaviour.
- `progress_tracker_test.dart` — 11 test cases covering percent calculation,
  stream emissions, speed/ETA, snapshot formatting, and disposal.
- `uploader_test.dart` — 15 end-to-end test cases using `MockHttpClient`
  covering happy path, retries, state transitions, resume, and cancel.
- `mock_http_client.dart` — fully-featured fake HTTP client with sequence
  responses, throw-once, fail-then-succeed, and request capture.

**Developer tools**
- `example/main.dart` — five runnable examples with terminal progress bar.
- `example/server_example/server.js` — Node.js reference server with checksum
  verification, chunk assembly, and session status endpoint.
- `benchmark/upload_benchmark.dart` — measures split time, read throughput,
  and MD5 hashing throughput across multiple file/chunk size combinations.
- `doc/getting_started.md` — comprehensive guide with configuration table,
  resume flow, custom storage, and FAQ.

---

## [0.9.0] — 2026-01-01 (beta)

### Added
- Initial beta implementation for early-access testing.
- Basic chunked upload without session persistence.
- Simple retry loop without exponential back-off.

### Known issues (resolved in 1.0.0)
- Session not persisted across app restarts.
- No progress stream; only callback-based progress.
- Retry delay was constant, not exponential.

---

[1.0.0]: https://github.com/Brah-Timo/quantum_upload/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/Brah-Timo/quantum_upload/releases/tag/v0.9.0

