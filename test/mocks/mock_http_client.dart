import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────────────────────
// Request record — captures what was sent so tests can inspect it
// ─────────────────────────────────────────────────────────────────────────────

/// Records every HTTP request intercepted by [MockHttpClient].
class CapturedRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Uint8List body;

  CapturedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  /// Value of the `X-Chunk-Index` header, parsed as int.
  int get chunkIndex => int.parse(headers['x-chunk-index'] ?? '-1');

  /// Value of the `X-Total-Chunks` header, parsed as int.
  int get totalChunks => int.parse(headers['x-total-chunks'] ?? '0');

  /// Value of the `X-Session-Id` header.
  String get sessionId => headers['x-session-id'] ?? '';

  /// Value of the `X-Chunk-Checksum` header.
  String get checksum => headers['x-chunk-checksum'] ?? '';
}

// ─────────────────────────────────────────────────────────────────────────────
// MockHttpClient — configurable fake HTTP client for unit tests
// ─────────────────────────────────────────────────────────────────────────────

/// A fake [http.BaseClient] that intercepts requests without touching the
/// network.
///
/// Configure it before each test:
///
/// ```dart
/// final mock = MockHttpClient();
///
/// // Always succeed
/// mock.respondWith(statusCode: 200);
///
/// // Fail the first two calls, then succeed
/// mock.respondWithSequence([
///   MockResponse(statusCode: 500),
///   MockResponse(statusCode: 500),
///   MockResponse(statusCode: 200),
/// ]);
///
/// // Throw a network error on the first call
/// mock.throwOnce(Exception('Network error'));
/// ```
///
/// After the test, inspect captured requests:
/// ```dart
/// expect(mock.capturedRequests.length, equals(3));
/// expect(mock.capturedRequests[0].chunkIndex, equals(0));
/// ```
class MockHttpClient extends http.BaseClient {
  // ── Captured requests ──────────────────────────────────────────────────────

  final List<CapturedRequest> capturedRequests = [];

  /// Total number of HTTP calls intercepted.
  int get callCount => capturedRequests.length;

  // ── Response configuration ─────────────────────────────────────────────────

  // Queue of responses/exceptions to return in sequence.
  final List<_Instruction> _instructions = [];

  // Fallback response when the instruction queue is empty.
  int _defaultStatusCode = 200;
  String _defaultBody = '{"status":"ok"}';

  /// Sets the default response returned when the instruction queue is empty.
  void respondWith({
    int statusCode = 200,
    String body = '{"status":"ok"}',
  }) {
    _defaultStatusCode = statusCode;
    _defaultBody = body;
  }

  /// Queues a sequence of responses/exceptions to return, one per request.
  ///
  /// Once the queue is exhausted, falls back to the default set by
  /// [respondWith].
  void respondWithSequence(List<MockResponse> responses) {
    _instructions.addAll(responses.map((r) => _ResponseInstruction(r)));
  }

  /// Queues a single network-level exception to throw on the next call.
  void throwOnce(Exception e) {
    _instructions.add(_ThrowInstruction(e));
  }

  /// Queues [n] network-level exceptions followed by a success response.
  ///
  /// Shorthand for testing the retry logic:
  /// ```dart
  /// mock.failThenSucceed(times: 2); // fail × 2, then HTTP 200
  /// ```
  void failThenSucceed({
    int times = 1,
    Exception? error,
    int successStatusCode = 200,
  }) {
    for (int i = 0; i < times; i++) {
      throwOnce(error ?? Exception('Simulated network error'));
    }
    _instructions.add(_ResponseInstruction(
      MockResponse(statusCode: successStatusCode),
    ));
  }

  /// Queues a 5xx server error followed by a success response.
  void serverErrorThenSucceed({int times = 1}) {
    for (int i = 0; i < times; i++) {
      _instructions.add(_ResponseInstruction(
        MockResponse(statusCode: 500, body: 'Internal Server Error'),
      ));
    }
    _instructions.add(_ResponseInstruction(
      MockResponse(statusCode: 200),
    ));
  }

  // ── BaseClient override ────────────────────────────────────────────────────

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // ── Capture request details ──────────────────────────────────────────────
    Uint8List body = Uint8List(0);
    if (request is http.MultipartRequest) {
      // Finalise so we can read the finalized bytes.
      final finalised = await request.finalize().toBytes();
      body = finalised;
    } else if (request is http.Request) {
      body = request.bodyBytes;
    }

    capturedRequests.add(CapturedRequest(
      method: request.method,
      url: request.url,
      headers: Map<String, String>.from(request.headers)
          .map((k, v) => MapEntry(k.toLowerCase(), v)),
      body: body,
    ));

    // ── Process next instruction ─────────────────────────────────────────────
    if (_instructions.isNotEmpty) {
      final instruction = _instructions.removeAt(0);
      return instruction.execute();
    }

    // ── Default response ─────────────────────────────────────────────────────
    return _buildStreamedResponse(_defaultStatusCode, _defaultBody);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static http.StreamedResponse _buildStreamedResponse(
    int statusCode,
    String body,
  ) {
    final bytes = utf8.encode(body);
    return http.StreamedResponse(
      Stream.fromIterable([bytes]),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  }

  /// Clears all captured requests and queued instructions.
  void reset() {
    capturedRequests.clear();
    _instructions.clear();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Response value object
// ─────────────────────────────────────────────────────────────────────────────

class MockResponse {
  final int statusCode;
  final String body;

  const MockResponse({
    required this.statusCode,
    this.body = '{"status":"ok"}',
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal instruction types
// ─────────────────────────────────────────────────────────────────────────────

abstract class _Instruction {
  Future<http.StreamedResponse> execute();
}

class _ResponseInstruction extends _Instruction {
  final MockResponse response;
  _ResponseInstruction(this.response);

  @override
  Future<http.StreamedResponse> execute() async =>
      MockHttpClient._buildStreamedResponse(
        response.statusCode,
        response.body,
      );
}

class _ThrowInstruction extends _Instruction {
  final Exception error;
  _ThrowInstruction(this.error);

  @override
  Future<http.StreamedResponse> execute() => Future.error(error);
}

