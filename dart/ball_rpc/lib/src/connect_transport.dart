/// [ConnectTransport]: an [RpcTransport] over the Connect protocol.
///
/// Implements the Connect protocol (<https://connectrpc.com/docs/protocol/>)
/// over HTTP/1.1 via `dart:io`'s [HttpClient]:
///
/// * **Unary** — HTTP `POST {baseUrl}/{package}.{Service}/{Method}`,
///   `content-type: application/proto`, body = the single message bytes. A
///   non-200 response is parsed as JSON `{code, message, details}` into an
///   [RpcException]. The `connect-protocol-version: 1` header is always sent.
/// * **Server-streaming** — `content-type: application/connect+proto`; the
///   response body is a sequence of length-prefixed envelopes, the final one
///   carrying the end-of-stream marker (flag bit 1) whose `EndStreamResponse`
///   JSON conveys any error + trailing metadata.
///
/// `clientStream`/`bidiStream` are **best-effort** over HTTP/1.1: a full
/// bidirectional stream requires HTTP/2 flow control that `HttpClient` does not
/// expose. They buffer the outbound request stream, send all envelopes in one
/// request body, and read the response envelopes — adequate for client-stream
/// (one response) and for bidi exchanges that do not require interleaving, but
/// not for truly concurrent bidi. See the package README.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'connect_codec.dart';
import 'rpc_code.dart';
import 'rpc_exception.dart';
import 'rpc_transport.dart';

/// A [RpcTransport] speaking the Connect protocol over HTTP/1.1.
class ConnectTransport implements RpcTransport {
  /// The base URL of the Connect server, e.g. `https://api.acme.com`. The
  /// method path (`/{package}.{Service}/{Method}`) is appended to this.
  final Uri baseUrl;

  final HttpClient _client;
  final bool _ownsClient;

  /// Creates a transport targeting [baseUrl].
  ///
  /// An [httpClient] may be injected (e.g. for connection pooling or tests);
  /// otherwise an [HttpClient] is created and closed with [close].
  ConnectTransport(this.baseUrl, {HttpClient? httpClient})
    : _client = httpClient ?? HttpClient(),
      _ownsClient = httpClient == null;

  Uri _uriFor(String path) => baseUrl.replace(path: _join(baseUrl.path, path));

  static String _join(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return path.startsWith('/') ? '$b$path' : '$b/$path';
  }

  void _applyHeaders(HttpClientRequest req, RpcMetadata? headers) {
    req.headers.set('connect-protocol-version', connectProtocolVersion);
    if (headers != null) {
      headers.forEach(req.headers.set);
    }
  }

  @override
  Future<List<int>> unary(
    String path,
    List<int> request, {
    RpcMetadata? headers,
  }) async {
    final req = await _client.postUrl(_uriFor(path));
    req.headers.contentType = ContentType.parse(connectUnaryProtoContentType);
    _applyHeaders(req, headers);
    req.add(request);
    final resp = await req.close();
    final body = await _collect(resp);
    if (resp.statusCode != HttpStatus.ok) {
      throw _unaryError(resp.statusCode, body);
    }
    return body;
  }

  @override
  Stream<List<int>> serverStream(
    String path,
    List<int> request, {
    RpcMetadata? headers,
  }) {
    return _streamCall(path, Stream.value(request), headers);
  }

  @override
  Future<List<int>> clientStream(
    String path,
    Stream<List<int>> requests, {
    RpcMetadata? headers,
  }) async {
    // Best-effort over HTTP/1.1: collect responses; a client-streaming method
    // yields exactly one response message.
    final responses = await _streamCall(path, requests, headers).toList();
    if (responses.isEmpty) {
      throw RpcException(
        RpcCode.internal,
        'client-streaming call returned no response message',
      );
    }
    return responses.first;
  }

  @override
  Stream<List<int>> bidiStream(
    String path,
    Stream<List<int>> requests, {
    RpcMetadata? headers,
  }) {
    // Best-effort over HTTP/1.1: the request stream is buffered into a single
    // request body before responses are read (no concurrent interleaving).
    return _streamCall(path, requests, headers);
  }

  /// Shared streaming machinery: buffers [requests] into Connect data
  /// envelopes, POSTs them with the streaming content type, then decodes the
  /// response envelopes, emitting each data message and surfacing the
  /// end-of-stream error (if any) as a stream error.
  Stream<List<int>> _streamCall(
    String path,
    Stream<List<int>> requests,
    RpcMetadata? headers,
  ) async* {
    final req = await _client.postUrl(_uriFor(path));
    req.headers.contentType = ContentType.parse(connectStreamProtoContentType);
    _applyHeaders(req, headers);
    await for (final msg in requests) {
      req.add(connectEncodeMessage(msg));
    }
    final resp = await req.close();
    final body = await _collect(resp);
    final envelopes = connectDecodeEnvelopes(body);
    for (final env in envelopes) {
      if (env.endOfStream) {
        if (env.error != null) throw env.error!;
        continue;
      }
      yield env.payload;
    }
  }

  RpcException _unaryError(int statusCode, List<int> body) {
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(body));
        if (decoded is Map<String, Object?> && decoded['code'] is String) {
          return errorFromJson(decoded);
        }
      } catch (_) {
        // Fall through to an HTTP-status-derived error below.
      }
    }
    return RpcException(_codeFromHttpStatus(statusCode), 'HTTP $statusCode');
  }

  static Future<List<int>> _collect(Stream<List<int>> stream) async {
    final out = <int>[];
    await for (final chunk in stream) {
      out.addAll(chunk);
    }
    return out;
  }

  /// Closes the underlying [HttpClient] when this transport created it.
  void close({bool force = false}) {
    if (_ownsClient) _client.close(force: force);
  }
}

/// Maps an HTTP status to an [RpcCode] for a unary error whose body could not be
/// parsed as a Connect error JSON, per the Connect HTTP-to-code table.
RpcCode _codeFromHttpStatus(int status) {
  switch (status) {
    case 400:
      return RpcCode.invalidArgument;
    case 401:
      return RpcCode.unauthenticated;
    case 403:
      return RpcCode.permissionDenied;
    case 404:
      return RpcCode.unimplemented;
    case 429:
      return RpcCode.unavailable;
    case 502:
    case 503:
    case 504:
      return RpcCode.unavailable;
    default:
      return RpcCode.unknown;
  }
}
