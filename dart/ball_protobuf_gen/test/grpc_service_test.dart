/// Phase-4 / stage-3 gate: `protoc-gen-ball-grpc` emits `<file>.grpc.dart`
/// service files whose typed `<Service>GrpcClient` (over a `ball_rpc`
/// `GrpcTransport`) round-trips through the generated message types and maps a
/// non-OK `grpc-status` trailer to an `RpcException`.
///
/// We build the same small Echo `FileDescriptorSet` programmatically as
/// `connect_service_test.dart` (no protoc needed):
///   * `echo/echo.proto` (proto3, package `echo`): `message EchoReq`,
///     `message EchoResp`, and `service Echo` with
///       - `rpc Unary(EchoReq) returns (EchoResp)`               (unary)
///       - `rpc ServerStream(EchoReq) returns (stream EchoResp)` (server-stream)
///
/// The difference from the Connect gate is the *transport semantics under test*:
/// the driver drives the typed client over a REAL `ball_rpc` `GrpcTransport`
/// whose pluggable [GrpcByteSender] is an in-memory gRPC server — it unframes
/// the request via `grpcDecodeFrames`, dispatches by method path, re-frames the
/// response via `grpcEncodeFrame`, and returns `grpc-status`/`grpc-message`
/// trailers. This exercises the full gRPC framing + status-mapping path
/// (`application/grpc+proto`, length-prefixed frames, trailer → `RpcException`)
/// rather than the `FakeTransport` shortcut.
///
/// The message plugin generates `echo/echo.pb.dart`; the gRPC plugin generates
/// `echo/echo.grpc.dart`. Both are written to a temp dir, then a subprocess
/// driver compiles + runs them green only if the generated typed gRPC client is
/// correct (proving "analyze clean" + "round-trips" + "error mapping" in one
/// shot, CWD-free).
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show
        DescriptorProto,
        FieldDescriptorProto,
        FieldDescriptorProto_Label,
        FieldDescriptorProto_Type,
        FileDescriptorProto,
        FileDescriptorSet,
        MethodDescriptorProto,
        MethodOptions,
        MethodOptions_IdempotencyLevel,
        ServiceDescriptorProto;
import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Programmatic FileDescriptorSet: an Echo service + its message types.
// ---------------------------------------------------------------------------

FieldDescriptorProto _field(
  String name,
  int number,
  FieldDescriptorProto_Type type,
) {
  return FieldDescriptorProto()
    ..name = name
    ..number = number
    ..type = type
    ..label = FieldDescriptorProto_Label.LABEL_OPTIONAL;
}

/// `echo/echo.proto` (proto3): EchoReq, EchoResp, and the Echo service with a
/// unary + a server-streaming method.
FileDescriptorProto _echoProto() {
  final req = DescriptorProto()
    ..name = 'EchoReq'
    ..field.addAll([
      _field('message', 1, FieldDescriptorProto_Type.TYPE_STRING),
      _field('count', 2, FieldDescriptorProto_Type.TYPE_INT32),
    ]);
  final resp = DescriptorProto()
    ..name = 'EchoResp'
    ..field.add(_field('reply', 1, FieldDescriptorProto_Type.TYPE_STRING));

  final unary = MethodDescriptorProto()
    ..name = 'Unary'
    ..inputType = '.echo.EchoReq'
    ..outputType = '.echo.EchoResp'
    // No-side-effects to prove idempotency is carried into the descriptor.
    ..options = (MethodOptions()
      ..idempotencyLevel = MethodOptions_IdempotencyLevel.NO_SIDE_EFFECTS);
  final serverStream = MethodDescriptorProto()
    ..name = 'ServerStream'
    ..inputType = '.echo.EchoReq'
    ..outputType = '.echo.EchoResp'
    ..serverStreaming = true;

  final service = ServiceDescriptorProto()
    ..name = 'Echo'
    ..method.addAll([unary, serverStream]);

  return FileDescriptorProto()
    ..name = 'echo/echo.proto'
    ..package = 'echo'
    ..syntax = 'proto3'
    ..messageType.addAll([req, resp])
    ..service.add(service);
}

List<int> _buildFds() =>
    (FileDescriptorSet()..file.add(_echoProto())).writeToBuffer();

/// Locates the workspace `.dart_tool/package_config.json` (shared by all
/// workspace packages), so the generated-driver subprocess resolves
/// `package:ball_protobuf`, `package:ball_rpc`, and `package:ball_base`.
String _packageConfigPath() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    final f = File('${dir.path}/.dart_tool/package_config.json');
    if (f.existsSync()) return f.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'Could not locate .dart_tool/package_config.json from '
    '${Directory.current.path}; run `dart pub get` in dart/ first.',
  );
}

void main() {
  late List<GeneratedDartFile> messageFiles;
  late List<GeneratedGrpcFile> grpcFiles;

  setUpAll(() {
    final fds = _buildFds();
    messageFiles = generateDartModels(
      fds,
      filesToGenerate: {'echo/echo.proto'},
    );
    grpcFiles = generateGrpcServices(fds, filesToGenerate: {'echo/echo.proto'});
  });

  group('grpc emission', () {
    test('emits one <file>.grpc.dart for the service-bearing file', () {
      expect({for (final g in grpcFiles) g.path}, {'echo/echo.grpc.dart'});
    });

    test('grpc file imports ball_rpc + the message .pb.dart sibling', () {
      final c = grpcFiles.single.content;
      expect(c, contains("import 'package:ball_rpc/ball_rpc.dart'"));
      expect(c, contains("import 'package:ball_protobuf/ball_protobuf.dart'"));
      // Local I/O types live in echo.pb.dart (same dir => bare filename).
      expect(c, contains("import 'echo.pb.dart'"));
    });

    test('emits a ServiceDescriptor const with the full method paths', () {
      final c = grpcFiles.single.content;
      expect(c, contains('EchoServiceDescriptor'));
      expect(c, contains("fullName: 'echo.Echo'"));
      // gRPC path form `/{package}.{Service}/{Method}`.
      expect(c, contains("'/echo.Echo/Unary'"));
      expect(c, contains("'/echo.Echo/ServerStream'"));
      expect(c, contains('MethodKind.unary'));
      expect(c, contains('MethodKind.serverStreaming'));
      // Idempotency carried through from MethodOptions.
      expect(c, contains('IdempotencyLevel.noSideEffects'));
    });

    test('typed gRPC client signatures match the streaming kinds', () {
      final c = grpcFiles.single.content;
      // The gRPC client is suffixed `GrpcClient` (so it can coexist with the
      // Connect `<Service>Client` in the same import scope).
      expect(c, contains('class EchoGrpcClient'));
      // unary => Future<Resp> m(Req)
      expect(
        c,
        contains(
          RegExp(
            r'Future<\$pb\d+\.EchoResp>\s+unary\('
            r'\$pb\d+\.EchoReq request\)',
          ),
        ),
      );
      // serverStreaming => Stream<Resp> m(Req)
      expect(
        c,
        contains(
          RegExp(
            r'Stream<\$pb\d+\.EchoResp>\s+serverStream\('
            r'\$pb\d+\.EchoReq request\)',
          ),
        ),
      );
    });
  });

  group(
    'typed gRPC-client round-trip + grpc-status error (subprocess driver)',
    () {
      test('unary + server-streaming round-trip over GrpcTransport and a '
          'grpc-status trailer maps to RpcException', () {
        final tmp = Directory.systemTemp.createTempSync('ball_grpc_');
        addTearDown(() {
          try {
            tmp.deleteSync(recursive: true);
          } catch (_) {}
        });

        // 1) Write message + grpc files under a gen/ tree mirroring their
        //    `/`-separated output paths.
        final genDir = Directory('${tmp.path}/gen')
          ..createSync(recursive: true);
        for (final g in [
          ...messageFiles.map((m) => (m.path, m.content)),
          ...grpcFiles.map((c) => (c.path, c.content)),
        ]) {
          final outFile = File('${genDir.path}/${g.$1}');
          outFile.parent.createSync(recursive: true);
          outFile.writeAsStringSync(g.$2);
        }

        // 2) The driver constructs the typed client over a real GrpcTransport
        //    backed by an in-memory GrpcByteSender, and exercises every path.
        final driver = File('${tmp.path}/driver.dart')
          ..writeAsStringSync(_driverSource);

        final pkgConfig = _packageConfigPath();
        final result = Process.runSync('dart', [
          'run',
          '--packages=$pkgConfig',
          driver.path,
        ], workingDirectory: tmp.path);

        expect(
          result.exitCode,
          0,
          reason:
              'driver failed.\n'
              'STDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}',
        );
        expect(result.stdout.toString(), contains('GRPC_OK'));
      });
    },
  );
}

/// Subprocess driver: imports the generated message + grpc files, stands up an
/// in-memory gRPC server as a `ball_rpc` [GrpcByteSender] (real framing +
/// trailers), and drives the TYPED `EchoGrpcClient` for unary +
/// server-streaming + a `grpc-status` error path.
const String _driverSource = r'''
import 'dart:async';

// MethodKind / IdempotencyLevel + the gRPC framing helpers are part of the
// ball_protobuf service/runtime model.
import 'package:ball_protobuf/ball_protobuf.dart';
import 'package:ball_rpc/ball_rpc.dart';

import 'gen/echo/echo.pb.dart' as pb;
import 'gen/echo/echo.grpc.dart' as grpc;

void check(bool cond, String msg) {
  if (!cond) throw StateError('FAILED: $msg');
}

/// One method's server logic: raw request message bytes -> raw response
/// message bytes (one or more). A handler may throw to signal a non-OK status.
typedef _Handler = List<List<int>> Function(List<int> requestMessage);

/// An in-memory gRPC server behind the GrpcTransport's pluggable byte layer.
///
/// It unframes the (length-prefixed) request via grpcDecodeFrames, dispatches
/// by method path to a [_Handler], re-frames the responses via grpcEncodeFrame,
/// and returns the framed bytes plus `grpc-status: 0` trailers on success. A
/// handler throwing an [RpcException] is surfaced as the matching non-zero
/// `grpc-status` + percent-encoded `grpc-message` trailers (no message frames),
/// exactly as a real gRPC server would — so GrpcTransport's trailer→RpcException
/// mapping is exercised end-to-end.
class _InMemoryGrpcServer implements GrpcByteSender {
  final Map<String, _Handler> handlers;
  _InMemoryGrpcServer(this.handlers);

  @override
  Future<GrpcResponse> send(
    String path,
    Map<String, String> headers,
    List<int> framedRequest,
  ) async {
    // The transport must set the gRPC content type.
    check(headers['content-type'] == 'application/grpc+proto',
        'request content-type (got ${headers['content-type']})');

    final handler = handlers[path];
    if (handler == null) {
      return GrpcResponse(bytes: const [], trailers: {
        'grpc-status': '${RpcCode.unimplemented.value}',
        'grpc-message': 'no handler for $path',
      });
    }

    // Unframe the request: take the first message (unary/server-stream send
    // exactly one request frame).
    final frames = grpcDecodeFrames(framedRequest);
    check(frames.isNotEmpty, 'server received no request frame');
    final requestMessage = (frames.first['messageBytes'] as List).cast<int>();

    try {
      final responses = handler(requestMessage);
      final out = <int>[];
      for (final r in responses) {
        out.addAll(grpcEncodeFrame(r));
      }
      return GrpcResponse(bytes: out, trailers: {'grpc-status': '0'});
    } on RpcException catch (e) {
      return GrpcResponse(bytes: const [], trailers: {
        'grpc-status': '${e.code.value}',
        'grpc-message': grpcEncodeMessage(e.message),
      });
    }
  }
}

Future<void> main() async {
  // Server handlers keyed by gRPC path.
  final server = _InMemoryGrpcServer({
    '/echo.Echo/Unary': (reqBytes) {
      final req = pb.EchoReq.fromBytes(reqBytes);
      final resp = pb.EchoResp()..reply = 'echo:${req.message}';
      return [resp.toBytes()];
    },
    '/echo.Echo/ServerStream': (reqBytes) {
      final req = pb.EchoReq.fromBytes(reqBytes);
      return [
        for (var i = 0; i < req.count; i++)
          (pb.EchoResp()..reply = '${req.message}#$i').toBytes(),
      ];
    },
  });

  final transport = GrpcTransport(server);
  final client = grpc.EchoGrpcClient(transport);

  // The descriptor surface is the transport-agnostic ServiceDescriptor.
  check(grpc.EchoGrpcClient.descriptor.fullName == 'echo.Echo',
      'descriptor.fullName');
  check(grpc.EchoGrpcClient.descriptor.methods.length == 2,
      'descriptor method count');
  final unaryMethod = grpc.EchoGrpcClient.descriptor.methodByName('Unary')!;
  check(unaryMethod.kind == MethodKind.unary, 'Unary kind');
  check(unaryMethod.idempotency == IdempotencyLevel.noSideEffects,
      'Unary idempotency');
  check(
      grpc.EchoGrpcClient.descriptor.methodByName('ServerStream')!.kind ==
          MethodKind.serverStreaming,
      'ServerStream kind');

  // (1) Unary round-trip through the typed client over real gRPC framing.
  final resp = await client.unary(pb.EchoReq()..message = 'hi');
  check(resp.reply == 'echo:hi', 'unary typed reply (got ${resp.reply})');

  // (2) Server-streaming round-trip through the typed client.
  final replies = await client
      .serverStream(pb.EchoReq()
        ..message = 'm'
        ..count = 3)
      .map((r) => r.reply)
      .toList();
  check(replies.length == 3, 'server-stream count (got ${replies.length})');
  check(replies[0] == 'm#0' && replies[2] == 'm#2',
      'server-stream replies (got $replies)');

  // (3) Error path: a server returning a non-zero grpc-status trailer maps to
  //     an RpcException with the matching code + message through the typed API.
  final errServer = _InMemoryGrpcServer({
    '/echo.Echo/Unary': (req) {
      throw RpcException(RpcCode.permissionDenied, 'denied');
    },
  });
  final errClient = grpc.EchoGrpcClient(GrpcTransport(errServer));
  Object? caught;
  try {
    await errClient.unary(pb.EchoReq()..message = 'x');
  } catch (e) {
    caught = e;
  }
  check(caught is RpcException, 'error is RpcException (got $caught)');
  check((caught as RpcException).code == RpcCode.permissionDenied,
      'grpc-status mapped (got ${caught.code})');
  check(caught.message == 'denied',
      'grpc-message decoded (got ${caught.message})');

  print('GRPC_OK');
}
''';
