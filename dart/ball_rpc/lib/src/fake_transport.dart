/// [FakeTransport]: an in-memory [RpcTransport] for testing generated clients
/// without sockets.
///
/// Register a handler per method [path] for each of the four kinds; a call to
/// the matching transport method invokes the handler. Handlers throw
/// [RpcException] to exercise error propagation. An unregistered path yields an
/// [RpcCode.unimplemented] error.
library;

import 'dart:async';

import 'rpc_code.dart';
import 'rpc_exception.dart';
import 'rpc_transport.dart';

/// A unary handler: one request, one response.
typedef FakeUnaryHandler =
    FutureOr<List<int>> Function(List<int> request, RpcMetadata? headers);

/// A server-streaming handler: one request, a stream of responses.
typedef FakeServerStreamHandler =
    Stream<List<int>> Function(List<int> request, RpcMetadata? headers);

/// A client-streaming handler: a stream of requests, one response.
typedef FakeClientStreamHandler =
    FutureOr<List<int>> Function(
      Stream<List<int>> requests,
      RpcMetadata? headers,
    );

/// A bidi-streaming handler: a stream of requests, a stream of responses.
typedef FakeBidiStreamHandler =
    Stream<List<int>> Function(
      Stream<List<int>> requests,
      RpcMetadata? headers,
    );

/// An in-memory [RpcTransport] that routes each method [path] to a registered
/// handler. No HTTP, no sockets — for testing generated service clients.
class FakeTransport implements RpcTransport {
  final Map<String, FakeUnaryHandler> _unary = {};
  final Map<String, FakeServerStreamHandler> _serverStream = {};
  final Map<String, FakeClientStreamHandler> _clientStream = {};
  final Map<String, FakeBidiStreamHandler> _bidiStream = {};

  /// Registers a [handler] for the unary method at [path].
  void registerUnary(String path, FakeUnaryHandler handler) =>
      _unary[path] = handler;

  /// Registers a [handler] for the server-streaming method at [path].
  void registerServerStream(String path, FakeServerStreamHandler handler) =>
      _serverStream[path] = handler;

  /// Registers a [handler] for the client-streaming method at [path].
  void registerClientStream(String path, FakeClientStreamHandler handler) =>
      _clientStream[path] = handler;

  /// Registers a [handler] for the bidi-streaming method at [path].
  void registerBidiStream(String path, FakeBidiStreamHandler handler) =>
      _bidiStream[path] = handler;

  @override
  Future<List<int>> unary(
    String path,
    List<int> request, {
    RpcMetadata? headers,
  }) async {
    final handler = _unary[path];
    if (handler == null) throw _unimplemented(path);
    return handler(request, headers);
  }

  @override
  Stream<List<int>> serverStream(
    String path,
    List<int> request, {
    RpcMetadata? headers,
  }) {
    final handler = _serverStream[path];
    if (handler == null) return Stream.error(_unimplemented(path));
    // Defer to a controller so a synchronous throw inside the handler also
    // surfaces as a stream error rather than escaping the call.
    return _guardStream(() => handler(request, headers));
  }

  @override
  Future<List<int>> clientStream(
    String path,
    Stream<List<int>> requests, {
    RpcMetadata? headers,
  }) async {
    final handler = _clientStream[path];
    if (handler == null) throw _unimplemented(path);
    return handler(requests, headers);
  }

  @override
  Stream<List<int>> bidiStream(
    String path,
    Stream<List<int>> requests, {
    RpcMetadata? headers,
  }) {
    final handler = _bidiStream[path];
    if (handler == null) return Stream.error(_unimplemented(path));
    return _guardStream(() => handler(requests, headers));
  }

  static Stream<List<int>> _guardStream(Stream<List<int>> Function() body) {
    final Stream<List<int>> inner;
    try {
      inner = body();
    } catch (e, st) {
      return Stream.error(e, st);
    }
    return inner;
  }

  static RpcException _unimplemented(String path) =>
      RpcException(RpcCode.unimplemented, 'no handler registered for $path');
}
