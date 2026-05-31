/// FakeTransport unary + server-streaming + error round-trips, plus the
/// client/bidi kinds.
library;

import 'dart:async';

import 'package:ball_rpc/ball_rpc.dart';
import 'package:test/test.dart';

void main() {
  late FakeTransport transport;

  setUp(() => transport = FakeTransport());

  group('unary', () {
    test('routes to the registered handler and returns its bytes', () async {
      transport.registerUnary('/acme.Echo/Unary', (req, headers) {
        // Echo the request reversed so we can prove request->response flow.
        return req.reversed.toList();
      });
      final resp = await transport.unary('/acme.Echo/Unary', [1, 2, 3]);
      expect(resp, [3, 2, 1]);
    });

    test('passes headers through to the handler', () async {
      RpcMetadata? seen;
      transport.registerUnary('/acme.Echo/Unary', (req, headers) {
        seen = headers;
        return const <int>[];
      });
      await transport.unary(
        '/acme.Echo/Unary',
        const [],
        headers: {'authorization': 'Bearer x'},
      );
      expect(seen?['authorization'], 'Bearer x');
    });

    test('handler throwing RpcException propagates to the caller', () {
      transport.registerUnary('/acme.Echo/Unary', (req, headers) {
        throw RpcException(RpcCode.permissionDenied, 'nope');
      });
      expect(
        () => transport.unary('/acme.Echo/Unary', const []),
        throwsA(
          isA<RpcException>()
              .having((e) => e.code, 'code', RpcCode.permissionDenied)
              .having((e) => e.message, 'message', 'nope'),
        ),
      );
    });

    test('unregistered path => unimplemented', () {
      expect(
        () => transport.unary('/acme.Echo/Missing', const []),
        throwsA(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.unimplemented,
          ),
        ),
      );
    });
  });

  group('server-streaming', () {
    test('emits each response from the handler stream in order', () async {
      transport.registerServerStream('/acme.Echo/Server', (req, headers) {
        return Stream.fromIterable([
          [req[0]],
          [req[0] + 1],
          [req[0] + 2],
        ]);
      });
      final out = await transport.serverStream('/acme.Echo/Server', [
        10,
      ]).toList();
      expect(out, [
        [10],
        [11],
        [12],
      ]);
    });

    test('error mid-stream propagates as a stream error', () {
      transport.registerServerStream('/acme.Echo/Server', (
        req,
        headers,
      ) async* {
        yield [1];
        throw RpcException(RpcCode.aborted, 'boom');
      });
      expect(
        transport.serverStream('/acme.Echo/Server', const []),
        emitsInOrder([
          [1],
          emitsError(
            isA<RpcException>().having((e) => e.code, 'code', RpcCode.aborted),
          ),
        ]),
      );
    });

    test('unregistered path => stream error (unimplemented)', () {
      expect(
        transport.serverStream('/acme.Echo/Missing', const []),
        emitsError(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.unimplemented,
          ),
        ),
      );
    });
  });

  group('client-streaming', () {
    test('consumes the request stream and returns one response', () async {
      transport.registerClientStream('/acme.Echo/Client', (
        reqs,
        headers,
      ) async {
        var sum = 0;
        await for (final r in reqs) {
          sum += r.fold<int>(0, (a, b) => a + b);
        }
        return [sum];
      });
      final resp = await transport.clientStream(
        '/acme.Echo/Client',
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
      );
      expect(resp, [10]);
    });
  });

  group('bidi-streaming', () {
    test('streams requests in, responses out', () async {
      transport.registerBidiStream('/acme.Echo/Bidi', (reqs, headers) async* {
        await for (final r in reqs) {
          yield r.reversed.toList();
        }
      });
      final out = await transport
          .bidiStream(
            '/acme.Echo/Bidi',
            Stream.fromIterable([
              [1, 2],
              [3, 4],
            ]),
          )
          .toList();
      expect(out, [
        [2, 1],
        [4, 3],
      ]);
    });
  });
}
