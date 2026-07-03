/// The abstract [RpcTransport] contract: bytes-level RPC for all four
/// [MethodKind]s.
///
// coverage:ignore-file
// Pure abstract interface — every member is a bodyless signature, so there is
// no executable statement dart:coverage could ever instrument (confirmed: a
// suite that imports this file via a concrete subclass, e.g. FakeTransport,
// produces zero `SF:`/`DA:` records for it). The behavior lives in — and is
// tested via — the concrete implementations (FakeTransport, ConnectTransport,
// GrpcTransport), which each have their own dedicated test suites.
library;

import 'rpc_exception.dart';

/// A bytes-level RPC transport.
///
/// Generated service clients depend on this interface, not on any concrete
/// transport. Each method takes a fully-qualified method [path] of the form
/// `/{package}.{Service}/{Method}` and the request message *bytes* (the typed
/// generated client serializes via the `ball_protobuf` runtime before calling,
/// and deserializes the returned bytes after). The four methods mirror the four
/// streaming kinds:
///
/// * [unary] — one request, one response.
/// * [serverStream] — one request, a stream of responses.
/// * [clientStream] — a stream of requests, one response.
/// * [bidiStream] — a stream of requests and a stream of responses.
///
/// On any non-OK outcome, a transport throws (or, for [Stream]-returning
/// methods, emits as a stream error) an [RpcException].
abstract class RpcTransport {
  /// One request, one response.
  Future<List<int>> unary(
    String path,
    List<int> request, {
    RpcMetadata? headers,
  });

  /// One request, a stream of responses.
  Stream<List<int>> serverStream(
    String path,
    List<int> request, {
    RpcMetadata? headers,
  });

  /// A stream of requests, one response.
  Future<List<int>> clientStream(
    String path,
    Stream<List<int>> requests, {
    RpcMetadata? headers,
  });

  /// A stream of requests and a stream of responses.
  Stream<List<int>> bidiStream(
    String path,
    Stream<List<int>> requests, {
    RpcMetadata? headers,
  });
}
