/// GrpcTransport framing + status mapping, exercised through an in-memory
/// [GrpcByteSender] (the pluggable HTTP/2 injection point), proving the
/// transport works end-to-end without a real socket.
library;

import 'dart:async';

import 'package:ball_protobuf/ball_protobuf.dart'
    show grpcDecodeFrames, grpcEncodeFrame;
import 'package:ball_rpc/ball_rpc.dart';
import 'package:test/test.dart';

/// An in-memory [GrpcByteSender] that records the framed request and replies
/// with caller-provided framed bytes + trailers.
class _RecordingSender implements GrpcByteSender {
  final List<int> Function(List<List<int>> requestMessages) respond;
  final Map<String, String> trailers;

  String? lastPath;
  Map<String, String>? lastHeaders;
  List<List<int>>? lastRequestMessages;

  _RecordingSender(this.respond, {this.trailers = const {'grpc-status': '0'}});

  @override
  Future<GrpcResponse> send(
    String path,
    Map<String, String> headers,
    List<int> framedRequest,
  ) async {
    lastPath = path;
    lastHeaders = headers;
    lastRequestMessages = [
      for (final f in grpcDecodeFrames(framedRequest))
        f['messageBytes'] as List<int>,
    ];
    return GrpcResponse(
      bytes: respond(lastRequestMessages!),
      trailers: trailers,
    );
  }
}

void main() {
  group('unary', () {
    test('frames the request, sets headers, unframes the response', () async {
      final sender = _RecordingSender(
        (reqs) => grpcEncodeFrame(reqs.single.reversed.toList()),
      );
      final transport = GrpcTransport(sender);

      final resp = await transport.unary('/acme.Eliza/Say', [1, 2, 3]);
      expect(resp, [3, 2, 1]);
      expect(sender.lastPath, '/acme.Eliza/Say');
      expect(sender.lastHeaders?['content-type'], 'application/grpc+proto');
      expect(sender.lastHeaders?['te'], 'trailers');
      expect(sender.lastRequestMessages, [
        [1, 2, 3],
      ]);
    });

    test('custom headers are merged into the request', () async {
      final sender = _RecordingSender((reqs) => grpcEncodeFrame(const []));
      final transport = GrpcTransport(sender);
      await transport.unary(
        '/acme.Eliza/Say',
        const [],
        headers: {'authorization': 'Bearer t'},
      );
      expect(sender.lastHeaders?['authorization'], 'Bearer t');
    });

    test('non-zero grpc-status trailer => RpcException', () {
      final sender = _RecordingSender(
        (reqs) => const <int>[],
        trailers: {'grpc-status': '7', 'grpc-message': 'denied'},
      );
      final transport = GrpcTransport(sender);
      expect(
        () => transport.unary('/acme.Eliza/Say', const []),
        throwsA(
          isA<RpcException>()
              .having((e) => e.code, 'code', RpcCode.permissionDenied)
              .having((e) => e.message, 'message', 'denied'),
        ),
      );
    });
  });

  group('server-streaming', () {
    test('unframes multiple response frames into a stream', () async {
      final sender = _RecordingSender((reqs) {
        final out = <int>[];
        for (final m in [
          [1],
          [2, 3],
          [4, 5, 6],
        ]) {
          out.addAll(grpcEncodeFrame(m));
        }
        return out;
      });
      final transport = GrpcTransport(sender);
      final out = await transport.serverStream('/acme.Eliza/Stream', const [
        0,
      ]).toList();
      expect(out, [
        [1],
        [2, 3],
        [4, 5, 6],
      ]);
    });

    test('non-zero status surfaces as a stream error', () {
      final sender = _RecordingSender(
        (reqs) => const <int>[],
        trailers: {'grpc-status': '14', 'grpc-message': 'down'},
      );
      final transport = GrpcTransport(sender);
      expect(
        transport.serverStream('/acme.Eliza/Stream', const []),
        emitsError(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.unavailable,
          ),
        ),
      );
    });
  });

  group('client-streaming', () {
    test('frames every request message, returns one response', () async {
      final sender = _RecordingSender((reqs) {
        final total = reqs.fold<int>(0, (a, m) => a + m.length);
        return grpcEncodeFrame([total]);
      });
      final transport = GrpcTransport(sender);
      final resp = await transport.clientStream(
        '/acme.Eliza/Collect',
        Stream.fromIterable([
          [1, 2],
          [3],
        ]),
      );
      expect(resp, [3]);
      expect(sender.lastRequestMessages, [
        [1, 2],
        [3],
      ]);
    });
  });
}
