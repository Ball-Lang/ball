/// Coverage-focused edge tests for ball_rpc: RpcException.toString, the
/// Connect end-of-stream metadata-only (string-valued) branch, FakeTransport
/// unimplemented/guard paths, and GrpcTransport empty-response/stream branches.
///
/// Pure (socket-free) — exercises the lib paths the existing suites skip.
library;

import 'dart:async';

import 'package:ball_protobuf/ball_protobuf.dart'
    show grpcEncodeFrame, grpcEncodeFrameWithFlags, grpcMakeFlags;
import 'package:ball_rpc/ball_rpc.dart';
import 'package:test/test.dart';

/// A no-op [GrpcByteSender] that always replies with the caller-supplied framed
/// bytes and an OK status, so framing paths are exercised without a socket.
class _StaticSender implements GrpcByteSender {
  final List<int> responseBytes;
  _StaticSender(this.responseBytes);

  @override
  Future<GrpcResponse> send(
    String path,
    Map<String, String> headers,
    List<int> framedRequest,
  ) async =>
      GrpcResponse(bytes: responseBytes, trailers: const {'grpc-status': '0'});
}

void main() {
  group('RpcException.toString', () {
    test('without details renders code + message only', () {
      final e = RpcException(RpcCode.notFound, 'gone');
      expect(e.toString(), 'RpcException(not_found: gone)');
    });

    test('with details appends the details list', () {
      final e = RpcException(
        RpcCode.invalidArgument,
        'bad',
        details: const [
          {'type': 'x'},
        ],
      );
      final s = e.toString();
      expect(s, startsWith('RpcException(invalid_argument: bad, details: '));
      expect(s, endsWith(')'));
      expect(s, contains('type'));
    });

    test('details are unmodifiable', () {
      final e = RpcException(RpcCode.internal, 'x', details: const [1, 2]);
      expect(() => (e.details as List).add(3), throwsUnsupportedError);
    });
  });

  group('RpcCode', () {
    test('fromValue maps known + unknown codes', () {
      expect(RpcCode.fromValue(0), RpcCode.ok);
      expect(RpcCode.fromValue(16), RpcCode.unauthenticated);
      expect(RpcCode.fromValue(99), RpcCode.unknown);
      expect(RpcCode.fromValue(-1), RpcCode.unknown);
    });

    test('fromConnectName maps known + unknown names', () {
      expect(RpcCode.fromConnectName('canceled'), RpcCode.cancelled);
      expect(
        RpcCode.fromConnectName('deadline_exceeded'),
        RpcCode.deadlineExceeded,
      );
      expect(RpcCode.fromConnectName('not-a-code'), RpcCode.unknown);
    });
  });

  group('Connect end-of-stream metadata (string-valued branch)', () {
    test('a string metadata value (not an array) is read verbatim', () {
      // _metadataFromJson's `value is String` branch (connect_codec.dart:173):
      // hand-craft an EndStreamResponse whose metadata value is a bare string.
      final payload = '{"metadata":{"x-trace":"abc"}}'.codeUnits;
      final frame = grpcEncodeFrameWithFlags(
        payload,
        grpcMakeFlags(endOfStream: true),
      );
      final env = connectDecodeEnvelope(frame, 0);
      expect(env.endOfStream, isTrue);
      expect(env.metadata?['x-trace'], 'abc');
    });

    test('an empty metadata object yields null metadata', () {
      final payload = '{"metadata":{}}'.codeUnits;
      final frame = grpcEncodeFrameWithFlags(
        payload,
        grpcMakeFlags(endOfStream: true),
      );
      final env = connectDecodeEnvelope(frame, 0);
      expect(env.metadata, isNull);
    });
  });

  group('FakeTransport unregistered + guard paths', () {
    test('unary on an unregistered path throws unimplemented', () {
      final t = FakeTransport();
      expect(
        () => t.unary('/x.Y/Z', const []),
        throwsA(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.unimplemented,
          ),
        ),
      );
    });

    test('clientStream on an unregistered path throws unimplemented', () {
      final t = FakeTransport();
      expect(
        () => t.clientStream('/x.Y/Z', const Stream.empty()),
        throwsA(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.unimplemented,
          ),
        ),
      );
    });

    test('serverStream on an unregistered path emits a stream error', () {
      final t = FakeTransport();
      expect(
        t.serverStream('/x.Y/Z', const []),
        emitsError(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.unimplemented,
          ),
        ),
      );
    });

    test('bidiStream on an unregistered path emits a stream error', () {
      final t = FakeTransport();
      expect(
        t.bidiStream('/x.Y/Z', const Stream.empty()),
        emitsError(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.unimplemented,
          ),
        ),
      );
    });

    test('a handler that throws synchronously surfaces as a stream error', () {
      final t = FakeTransport();
      t.registerServerStream('/x.Y/Z', (req, headers) {
        throw RpcException(RpcCode.failedPrecondition, 'boom');
      });
      expect(
        t.serverStream('/x.Y/Z', const []),
        emitsError(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.failedPrecondition,
          ),
        ),
      );
    });

    test('registered handlers route requests and headers through', () async {
      final t = FakeTransport();
      t.registerClientStream('/x.Y/Collect', (requests, headers) async {
        final all = await requests.toList();
        return [all.length, headers?.length ?? 0];
      });
      final out = await t.clientStream(
        '/x.Y/Collect',
        Stream.fromIterable([
          [1],
          [2],
        ]),
        headers: {'a': 'b'},
      );
      expect(out, [2, 1]);
    });

    test('registered bidi handler streams responses', () async {
      final t = FakeTransport();
      t.registerBidiStream('/x.Y/Chat', (requests, headers) async* {
        await for (final r in requests) {
          yield r;
        }
      });
      final out = await t
          .bidiStream(
            '/x.Y/Chat',
            Stream.fromIterable([
              [9],
              [8],
            ]),
          )
          .toList();
      expect(out, [
        [9],
        [8],
      ]);
    });
  });

  group('GrpcTransport empty-response + remaining stream branches', () {
    test('unary with no response frame throws internal', () {
      final transport = GrpcTransport(_StaticSender(const []));
      expect(
        () => transport.unary('/x.Y/Z', const []),
        throwsA(
          isA<RpcException>()
              .having((e) => e.code, 'code', RpcCode.internal)
              .having((e) => e.message, 'message', contains('no response')),
        ),
      );
    });

    test('clientStream with no response frame throws internal', () {
      final transport = GrpcTransport(_StaticSender(const []));
      expect(
        () => transport.clientStream('/x.Y/Z', const Stream.empty()),
        throwsA(
          isA<RpcException>().having((e) => e.code, 'code', RpcCode.internal),
        ),
      );
    });

    test('bidiStream frames all requests and unframes all responses', () async {
      final reply = <int>[
        ...grpcEncodeFrame([1, 1]),
        ...grpcEncodeFrame([2, 2]),
      ];
      final transport = GrpcTransport(_StaticSender(reply));
      final out = await transport
          .bidiStream(
            '/x.Y/Chat',
            Stream.fromIterable([
              [0],
              [0],
            ]),
          )
          .toList();
      expect(out, [
        [1, 1],
        [2, 2],
      ]);
    });
  });
}
