/// ConnectTransport unary + server-streaming + error round-trips against a
/// real in-process HTTP/1.1 server (dart:io HttpServer), exercising the actual
/// Connect wire format the transport produces and consumes.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_rpc/ball_rpc.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late ConnectTransport transport;

  /// The request handler installed per test.
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

  group('unary', () {
    test(
      'POSTs message bytes with the Connect headers; returns response bytes',
      () async {
        List<int>? receivedBody;
        String? receivedPath;
        String? protocolVersion;
        String? contentType;
        handler = (req) async {
          receivedPath = req.uri.path;
          protocolVersion = req.headers.value('connect-protocol-version');
          contentType = req.headers.contentType?.value;
          receivedBody = await _collect(req);
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.parse(
            'application/proto',
          );
          req.response.add([9, 8, 7]);
          await req.response.close();
        };

        final resp = await transport.unary('/acme.Eliza/Say', [1, 2, 3]);
        expect(resp, [9, 8, 7]);
        expect(receivedBody, [1, 2, 3]);
        expect(receivedPath, '/acme.Eliza/Say');
        expect(protocolVersion, '1');
        expect(contentType, 'application/proto');
      },
    );

    test('non-200 with Connect error JSON => RpcException', () {
      handler = (req) async {
        await _collect(req);
        req.response.statusCode = 403; // permission_denied per Connect table
        req.response.headers.contentType = ContentType.parse(
          'application/json',
        );
        req.response.write(
          jsonEncode({'code': 'permission_denied', 'message': 'not allowed'}),
        );
        await req.response.close();
      };

      expect(
        () => transport.unary('/acme.Eliza/Say', const []),
        throwsA(
          isA<RpcException>()
              .having((e) => e.code, 'code', RpcCode.permissionDenied)
              .having((e) => e.message, 'message', 'not allowed'),
        ),
      );
    });

    test('custom headers are sent', () async {
      String? auth;
      handler = (req) async {
        auth = req.headers.value('authorization');
        await _collect(req);
        req.response.add(const []);
        await req.response.close();
      };
      await transport.unary(
        '/acme.Eliza/Say',
        const [],
        headers: {'authorization': 'Bearer abc'},
      );
      expect(auth, 'Bearer abc');
    });
  });

  group('server-streaming', () {
    test('decodes enveloped data frames + a success end-of-stream', () async {
      handler = (req) async {
        await _collect(req);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.parse(
          'application/connect+proto',
        );
        req.response.add(connectEncodeMessage([1]));
        req.response.add(connectEncodeMessage([2, 3]));
        req.response.add(connectEncodeEndStream());
        await req.response.close();
      };

      final out = await transport.serverStream('/acme.Eliza/Stream', [
        0,
      ]).toList();
      expect(out, [
        [1],
        [2, 3],
      ]);
    });

    test('end-of-stream error envelope surfaces as a stream error', () {
      handler = (req) async {
        await _collect(req);
        req.response.statusCode = HttpStatus.ok; // streaming errors are 200
        req.response.headers.contentType = ContentType.parse(
          'application/connect+proto',
        );
        req.response.add(connectEncodeMessage([1]));
        req.response.add(
          connectEncodeEndStream(
            error: RpcException(RpcCode.unavailable, 'overloaded'),
          ),
        );
        await req.response.close();
      };

      expect(
        transport.serverStream('/acme.Eliza/Stream', const []),
        emitsInOrder([
          [1],
          emitsError(
            isA<RpcException>()
                .having((e) => e.code, 'code', RpcCode.unavailable)
                .having((e) => e.message, 'message', 'overloaded'),
          ),
        ]),
      );
    });
  });

  group('client-streaming (best-effort over HTTP/1.1)', () {
    test('buffers requests, returns the single response message', () async {
      handler = (req) async {
        await _collect(req);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.parse(
          'application/connect+proto',
        );
        req.response.add(connectEncodeMessage([42]));
        req.response.add(connectEncodeEndStream());
        await req.response.close();
      };

      final resp = await transport.clientStream(
        '/acme.Eliza/Collect',
        Stream.fromIterable([
          [1],
          [2],
        ]),
      );
      expect(resp, [42]);
    });
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}
