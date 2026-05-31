/// [GrpcTransport]: an [RpcTransport] over gRPC-over-HTTP/2, with a pluggable
/// byte-sender so the framing + status mapping are fully implemented and
/// testable without a real HTTP/2 stack.
///
/// `dart:io`'s `HttpClient` does **not** speak HTTP/2, and gRPC mandates HTTP/2
/// (PROTOCOL-HTTP2.md). Rather than pull in a heavyweight HTTP/2 dependency,
/// the actual transport is injected as a [GrpcByteSender]: it is handed the
/// method [path], the request headers, and the *already-framed* request bytes
/// (gRPC length-prefixed messages) and returns the *framed* response bytes plus
/// the response trailers. [GrpcTransport] owns everything else — building the
/// path, framing/unframing via `grpc_frame`, and mapping `grpc-status` /
/// `grpc-message` trailers to an [RpcException]. A production HTTP/2 binding
/// (e.g. over `package:http2`) plugs in as a [GrpcByteSender].
library;

import 'dart:async';

import 'package:ball_protobuf/ball_protobuf.dart'
    show grpcDecodeFrames, grpcEncodeFrame;

import 'grpc_codec.dart';
import 'rpc_code.dart';
import 'rpc_exception.dart';
import 'rpc_transport.dart';

/// The result of a [GrpcByteSender] exchange: the framed response [bytes] and
/// the response [trailers] (lower-cased trailer fields, incl. `grpc-status` /
/// `grpc-message`).
class GrpcResponse {
  /// The framed response bytes (zero or more gRPC length-prefixed messages).
  final List<int> bytes;

  /// The response trailers (lower-cased keys).
  final Map<String, String> trailers;

  const GrpcResponse({required this.bytes, this.trailers = const {}});
}

/// The pluggable HTTP/2 byte layer for [GrpcTransport].
///
/// An implementation performs a single gRPC call: it sends the [framedRequest]
/// bytes to [path] with [headers] (`content-type: application/grpc+proto` is
/// already set by the transport) and returns the framed response + trailers.
/// Streaming uses the same primitive: [framedRequest] concatenates all request
/// frames, and the returned [GrpcResponse.bytes] concatenates all response
/// frames. This keeps the framing/status logic in [GrpcTransport] and the
/// socket concern fully replaceable (and testable with an in-memory sender).
abstract class GrpcByteSender {
  /// Sends [framedRequest] to [path] with [headers]; returns the framed
  /// response bytes and trailers. Throws on a transport-level (connection)
  /// failure.
  Future<GrpcResponse> send(
    String path,
    Map<String, String> headers,
    List<int> framedRequest,
  );
}

/// A [RpcTransport] implementing gRPC framing + status mapping over a pluggable
/// [GrpcByteSender].
class GrpcTransport implements RpcTransport {
  final GrpcByteSender _sender;

  /// Creates a transport that delegates byte transfer to [sender].
  GrpcTransport(GrpcByteSender sender) : _sender = sender;

  Map<String, String> _headers(RpcMetadata? headers) => {
    'content-type': grpcProtoContentType,
    'te': 'trailers',
    ...?headers,
  };

  /// Frames [messages] (each a raw message) into one gRPC byte stream.
  List<int> _frame(List<List<int>> messages) {
    final out = <int>[];
    for (final m in messages) {
      out.addAll(grpcEncodeFrame(m));
    }
    return out;
  }

  /// Unframes [bytes] into the sequence of raw response messages.
  List<List<int>> _unframe(List<int> bytes) {
    if (bytes.isEmpty) return const [];
    return [
      for (final f in grpcDecodeFrames(bytes)) f['messageBytes'] as List<int>,
    ];
  }

  Future<GrpcResponse> _exchange(
    String path,
    List<List<int>> requestMessages,
    RpcMetadata? headers,
  ) async {
    final resp = await _sender.send(
      path,
      _headers(headers),
      _frame(requestMessages),
    );
    final err = grpcStatusFromTrailers(resp.trailers);
    if (err != null) throw err;
    return resp;
  }

  @override
  Future<List<int>> unary(
    String path,
    List<int> request, {
    RpcMetadata? headers,
  }) async {
    final resp = await _exchange(path, [request], headers);
    final messages = _unframe(resp.bytes);
    if (messages.isEmpty) {
      throw RpcException(
        RpcCode.internal,
        'unary call returned no response message',
      );
    }
    return messages.first;
  }

  @override
  Stream<List<int>> serverStream(
    String path,
    List<int> request, {
    RpcMetadata? headers,
  }) async* {
    final resp = await _exchange(path, [request], headers);
    for (final m in _unframe(resp.bytes)) {
      yield m;
    }
  }

  @override
  Future<List<int>> clientStream(
    String path,
    Stream<List<int>> requests, {
    RpcMetadata? headers,
  }) async {
    final all = await requests.toList();
    final resp = await _exchange(path, all, headers);
    final messages = _unframe(resp.bytes);
    if (messages.isEmpty) {
      throw RpcException(
        RpcCode.internal,
        'client-streaming call returned no response message',
      );
    }
    return messages.first;
  }

  @override
  Stream<List<int>> bidiStream(
    String path,
    Stream<List<int>> requests, {
    RpcMetadata? headers,
  }) async* {
    final all = await requests.toList();
    final resp = await _exchange(path, all, headers);
    for (final m in _unframe(resp.bytes)) {
      yield m;
    }
  }
}
