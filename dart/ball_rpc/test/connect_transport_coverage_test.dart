/// Coverage-focused ConnectTransport tests against a real in-process HTTP/1.1
/// server: the bidi path, the empty client-stream-response error, and the
/// HTTP-status -> RpcCode fallback table (`_codeFromHttpStatus`) when the error
/// body is not parseable as Connect error JSON.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_rpc/ball_rpc.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late ConnectTransport transport;
  late Future<void> Function(HttpRequest req) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) => handler(req));
    transport = ConnectTransport(
      Uri.parse('http://${server.address.host}:${server.port}'),
    );
  });

  tearDown(() async {
    transport.close(force: true);
    await server.close(force: true);
  });

  Future<void> drain(HttpRequest req) async {
    await for (final _ in req) {}
  }

  group('bidiStream (best-effort over HTTP/1.1)', () {
    test('buffers requests and streams the response envelopes', () async {
      handler = (req) async {
        await drain(req);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.parse(
          'application/connect+proto',
        );
        req.response.add(connectEncodeMessage([7]));
        req.response.add(connectEncodeMessage([8, 9]));
        req.response.add(connectEncodeEndStream());
        await req.response.close();
      };

      final out = await transport
          .bidiStream(
            '/acme.Eliza/Chat',
            Stream.fromIterable([
              [1],
              [2],
            ]),
          )
          .toList();
      expect(out, [
        [7],
        [8, 9],
      ]);
    });
  });

  group('clientStream empty-response error', () {
    test('a stream with only an end-of-stream marker => internal error', () {
      handler = (req) async {
        await drain(req);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.parse(
          'application/connect+proto',
        );
        // No data envelopes, just the success end-of-stream.
        req.response.add(connectEncodeEndStream());
        await req.response.close();
      };

      expect(
        () =>
            transport.clientStream('/acme.Eliza/Collect', const Stream.empty()),
        throwsA(
          isA<RpcException>()
              .having((e) => e.code, 'code', RpcCode.internal)
              .having((e) => e.message, 'message', contains('no response')),
        ),
      );
    });
  });

  group('unary error fallback (_codeFromHttpStatus, unparseable body)', () {
    Future<void> expectStatusMapsTo(int status, RpcCode code) async {
      handler = (req) async {
        await drain(req);
        req.response.statusCode = status;
        // A non-JSON body so errorFromJson is skipped and the status table runs.
        req.response.write('not json {{{');
        await req.response.close();
      };
      await expectLater(
        () => transport.unary('/x.Y/Z', const []),
        throwsA(
          isA<RpcException>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.message, 'message', 'HTTP $status'),
        ),
      );
    }

    test(
      '400 -> invalid_argument',
      () => expectStatusMapsTo(400, RpcCode.invalidArgument),
    );
    test(
      '401 -> unauthenticated',
      () => expectStatusMapsTo(401, RpcCode.unauthenticated),
    );
    test(
      '403 -> permission_denied',
      () => expectStatusMapsTo(403, RpcCode.permissionDenied),
    );
    test(
      '404 -> unimplemented',
      () => expectStatusMapsTo(404, RpcCode.unimplemented),
    );
    test(
      '429 -> unavailable',
      () => expectStatusMapsTo(429, RpcCode.unavailable),
    );
    test(
      '503 -> unavailable',
      () => expectStatusMapsTo(503, RpcCode.unavailable),
    );
    test(
      '500 -> unknown (default)',
      () => expectStatusMapsTo(500, RpcCode.unknown),
    );

    test('empty body also falls through to the status table', () async {
      handler = (req) async {
        await drain(req);
        req.response.statusCode = 502;
        await req.response.close();
      };
      await expectLater(
        () => transport.unary('/x.Y/Z', const []),
        throwsA(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            RpcCode.unavailable,
          ),
        ),
      );
    });
  });

  group('baseUrl path join', () {
    test('a baseUrl with a trailing-slash path joins cleanly', () async {
      final t = ConnectTransport(
        Uri.parse('http://${server.address.host}:${server.port}/api/'),
      );
      String? seenPath;
      handler = (req) async {
        seenPath = req.uri.path;
        await drain(req);
        req.response.add(const [1]);
        await req.response.close();
      };
      final resp = await t.unary('/svc.S/M', const []);
      expect(resp, [1]);
      expect(seenPath, '/api/svc.S/M');
      t.close(force: true);
    });
  });
}
