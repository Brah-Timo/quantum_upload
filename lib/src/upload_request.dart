import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models/chunk_info.dart';
import 'models/upload_config.dart';
import 'exceptions/chunk_exception.dart';

/// Builds and sends a single HTTP multipart request for one file chunk.
///
/// Separating request construction from the [Uploader] loop makes both
/// sides easier to test in isolation: [UploadRequest] can be exercised
/// with a mock [http.Client] without spinning up a real [Uploader].
///
/// ## Wire format
///
/// Every chunk is sent as:
/// ```
/// POST <url>
/// Content-Type: multipart/form-data; boundary=…
///
/// [user headers]
/// X-Session-Id:      <sessionId>
/// X-Chunk-Index:     <0-based index>
/// X-Total-Chunks:    <total count>
/// X-Chunk-Checksum:  <MD5 hex>
/// X-File-Size:       <total file bytes>
/// Content-Range:     bytes <start>-<end>/<total>
///
/// --boundary
/// Content-Disposition: form-data; name="chunk"; filename="chunk_N"
///
/// <raw bytes>
/// --boundary--
/// ```
///
/// The server identifies the session via `X-Session-Id`, assembles the
/// file in chunk-index order, and verifies each piece with `X-Chunk-Checksum`.
/// After receiving the final chunk (`X-Chunk-Index == X-Total-Chunks - 1`)
/// the server merges the pieces and responds with its final payload.
class UploadRequest {
  final UploadConfig _config;
  final http.Client _client;

  // ── Constructor ────────────────────────────────────────────────────────────

  UploadRequest({
    required UploadConfig config,
    required http.Client client,
  })  : _config = config,
        _client = client;

  // ── Send ───────────────────────────────────────────────────────────────────

  /// Sends [data] (the raw bytes of chunk [chunkInfo]) to the server.
  ///
  /// ### Parameters
  /// - [sessionId]  — Session identifier set as `X-Session-Id`.
  /// - [chunkInfo]  — Byte-range metadata for the chunk being sent.
  /// - [totalChunks] — Total number of chunks in this upload.
  /// - [totalBytes]  — Total file size in bytes.
  /// - [data]        — Raw chunk bytes (exactly `chunkInfo.size` bytes).
  /// - [checksum]    — Pre-computed MD5 hex digest of [data].
  ///
  /// ### Returns
  /// The raw [http.Response] from the server.
  ///
  /// ### Throws
  /// - [ChunkException] if the server responds with a non-2xx status.
  /// - Any [http.ClientException] or [SocketException] on network failure
  ///   (the [RetryPolicy] will catch these and retry as appropriate).
  Future<http.Response> send({
    required String sessionId,
    required ChunkInfo chunkInfo,
    required int totalChunks,
    required int totalBytes,
    required Uint8List data,
    required String checksum,
  }) async {
    final request = _buildRequest(
      sessionId: sessionId,
      chunkInfo: chunkInfo,
      totalChunks: totalChunks,
      totalBytes: totalBytes,
      data: data,
      checksum: checksum,
    );

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);

    _assertSuccess(response, chunkInfo, sessionId);
    return response;
  }

  // ── Request builder ────────────────────────────────────────────────────────

  /// Assembles the [http.MultipartRequest] without sending it.
  ///
  /// Exposed as a separate method to simplify unit testing.
  http.MultipartRequest buildRequest({
    required String sessionId,
    required ChunkInfo chunkInfo,
    required int totalChunks,
    required int totalBytes,
    required Uint8List data,
    required String checksum,
  }) =>
      _buildRequest(
        sessionId: sessionId,
        chunkInfo: chunkInfo,
        totalChunks: totalChunks,
        totalBytes: totalBytes,
        data: data,
        checksum: checksum,
      );

  http.MultipartRequest _buildRequest({
    required String sessionId,
    required ChunkInfo chunkInfo,
    required int totalChunks,
    required int totalBytes,
    required Uint8List data,
    required String checksum,
  }) {
    // ── Standard library headers ────────────────────────────────────────────
    final libraryHeaders = <String, String>{
      // Session / progress identification
      'X-Session-Id': sessionId,
      'X-Chunk-Index': '${chunkInfo.index}',
      'X-Total-Chunks': '$totalChunks',
      // Integrity
      'X-Chunk-Checksum': checksum,
      'X-Chunk-Algorithm': 'MD5',
      // File-level metadata
      'X-File-Size': '$totalBytes',
      // Standard byte-range header (many servers parse this natively)
      'Content-Range':
          'bytes ${chunkInfo.startByte}-${chunkInfo.endByte - 1}/$totalBytes',
    };

    // User-supplied headers override library defaults only for the keys
    // they explicitly set, *except* for protected headers.
    final mergedHeaders = {...libraryHeaders, ..._config.headers};

    // ── Build multipart request ─────────────────────────────────────────────
    final req = http.MultipartRequest('POST', _config.url)
      ..headers.addAll(mergedHeaders)
      ..files.add(
        http.MultipartFile.fromBytes(
          'chunk', // field name expected by the server
          data,
          filename: 'chunk_${chunkInfo.index}',
        ),
      );

    return req;
  }

  // ── Response validation ────────────────────────────────────────────────────

  /// Validates [response] and throws [ChunkException] on failure.
  void _assertSuccess(
    http.Response response,
    ChunkInfo chunkInfo,
    String sessionId,
  ) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;

    final preview = response.body.length > 512
        ? response.body.substring(0, 512)
        : response.body;

    throw ChunkException(
      'Server rejected chunk ${chunkInfo.index} '
      'with HTTP ${response.statusCode}.',
      chunkIndex: chunkInfo.index,
      attempts: chunkInfo.attempts + 1,
      statusCode: response.statusCode,
      responseBody: preview,
      sessionId: sessionId,
    );
  }
}

