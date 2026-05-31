/// Phase-4 / stage-2 gate: `protoc-gen-ball-connect` emits `<file>.connect.dart`
/// service files whose typed client (over a `ball_rpc` `RpcTransport`)
/// round-trips through the generated message types.
///
/// We build a small `FileDescriptorSet` programmatically (no protoc needed),
/// mirroring `cross_file_test.dart`:
///   * `echo/echo.proto` (proto3, package `echo`): `message EchoReq`,
///     `message EchoResp`, and `service Echo` with
///       - `rpc Unary(EchoReq) returns (EchoResp)`           (unary)
///       - `rpc ServerStream(EchoReq) returns (stream EchoResp)` (server-stream)
///
/// The message plugin generates `echo/echo.pb.dart`; the connect plugin
/// generates `echo/echo.connect.dart`. Both are written to a temp dir, then a
/// subprocess driver:
///   1. constructs the generated `EchoClient` over a `ball_rpc` `FakeTransport`
///      with an in-memory echo handler registered per method path, and
///   2. asserts the unary + server-streaming round-trips through the TYPED
///      client API, plus an error path mapping to `RpcException`.
/// The driver compiles + runs green only if the generated typed client is
/// correct (proving "analyze clean" + "round-trips" in one shot, CWD-free).
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
  late List<GeneratedConnectFile> connectFiles;

  setUpAll(() {
    final fds = _buildFds();
    messageFiles = generateDartModels(
      fds,
      filesToGenerate: {'echo/echo.proto'},
    );
    connectFiles = generateConnectServices(
      fds,
      filesToGenerate: {'echo/echo.proto'},
    );
  });

  group('connect emission', () {
    test('emits one <file>.connect.dart for the service-bearing file', () {
      expect(
        {for (final g in connectFiles) g.path},
        {'echo/echo.connect.dart'},
      );
    });

    test('connect file imports ball_rpc + the message .pb.dart sibling', () {
      final c = connectFiles.single.content;
      expect(c, contains("import 'package:ball_rpc/ball_rpc.dart'"));
      expect(c, contains("import 'package:ball_protobuf/ball_protobuf.dart'"));
      // Local I/O types live in echo.pb.dart (same dir => bare filename).
      expect(c, contains("import 'echo.pb.dart'"));
    });

    test('emits a ServiceDescriptor const with the full method paths', () {
      final c = connectFiles.single.content;
      expect(c, contains('EchoServiceDescriptor'));
      expect(c, contains("fullName: 'echo.Echo'"));
      // gRPC/Connect path form `/{package}.{Service}/{Method}`.
      expect(c, contains("'/echo.Echo/Unary'"));
      expect(c, contains("'/echo.Echo/ServerStream'"));
      expect(c, contains('MethodKind.unary'));
      expect(c, contains('MethodKind.serverStreaming'));
      // Idempotency carried through from MethodOptions.
      expect(c, contains('IdempotencyLevel.noSideEffects'));
    });

    test('typed client signatures match the streaming kinds', () {
      final c = connectFiles.single.content;
      expect(c, contains('class EchoClient'));
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

  group('typed-client round-trip + error path (subprocess driver)', () {
    test('unary + server-streaming round-trip and an error maps to '
        'RpcException', () {
      final tmp = Directory.systemTemp.createTempSync('ball_connect_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });

      // 1) Write message + connect files under a gen/ tree mirroring their
      //    `/`-separated output paths.
      final genDir = Directory('${tmp.path}/gen')..createSync(recursive: true);
      for (final g in [
        ...messageFiles.map((m) => (m.path, m.content)),
        ...connectFiles.map((c) => (c.path, c.content)),
      ]) {
        final outFile = File('${genDir.path}/${g.$1}');
        outFile.parent.createSync(recursive: true);
        outFile.writeAsStringSync(g.$2);
      }

      // 2) The driver constructs the typed client over a FakeTransport and
      //    exercises every path. Throws (non-zero exit) on any failure.
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
      expect(result.stdout.toString(), contains('CONNECT_OK'));
    });
  });
}

/// Subprocess driver: imports the generated message + connect files, registers
/// an in-memory echo handler on a `ball_rpc` FakeTransport per method path, and
/// drives the TYPED `EchoClient` for unary + server-streaming + an error path.
const String _driverSource = r'''
import 'dart:async';

// MethodKind / IdempotencyLevel are part of the ball_protobuf service model.
import 'package:ball_protobuf/ball_protobuf.dart';
import 'package:ball_rpc/ball_rpc.dart';

import 'gen/echo/echo.pb.dart' as pb;
import 'gen/echo/echo.connect.dart' as connect;

void check(bool cond, String msg) {
  if (!cond) throw StateError('FAILED: $msg');
}

Future<void> main() async {
  final transport = FakeTransport();

  // Unary handler: decode the request bytes via the generated message type,
  // echo `message` back into the reply, re-encode via the response type.
  transport.registerUnary('/echo.Echo/Unary', (reqBytes, headers) {
    final req = pb.EchoReq.fromBytes(reqBytes);
    final resp = pb.EchoResp()..reply = 'echo:${req.message}';
    return resp.toBytes();
  });

  // Server-stream handler: emit `count` responses.
  transport.registerServerStream('/echo.Echo/ServerStream', (reqBytes, h) {
    final req = pb.EchoReq.fromBytes(reqBytes);
    return Stream.fromIterable([
      for (var i = 0; i < req.count; i++)
        (pb.EchoResp()..reply = '${req.message}#$i').toBytes(),
    ]);
  });

  final client = connect.EchoClient(transport);

  // The descriptor surface is the transport-agnostic ServiceDescriptor.
  check(connect.EchoClient.descriptor.fullName == 'echo.Echo',
      'descriptor.fullName');
  check(connect.EchoClient.descriptor.methods.length == 2,
      'descriptor method count');
  final unaryMethod = connect.EchoClient.descriptor.methodByName('Unary')!;
  check(unaryMethod.kind == MethodKind.unary, 'Unary kind');
  check(unaryMethod.idempotency == IdempotencyLevel.noSideEffects,
      'Unary idempotency');
  check(
      connect.EchoClient.descriptor.methodByName('ServerStream')!.kind ==
          MethodKind.serverStreaming,
      'ServerStream kind');

  // (1) Unary round-trip through the typed client.
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

  // (3) Error path: an unregistered method maps to an RpcException
  //     (unimplemented) surfaced through the typed unary API.
  final errTransport = FakeTransport();
  errTransport.registerUnary('/echo.Echo/Unary', (req, h) {
    throw RpcException(RpcCode.permissionDenied, 'denied');
  });
  final errClient = connect.EchoClient(errTransport);
  Object? caught;
  try {
    await errClient.unary(pb.EchoReq()..message = 'x');
  } catch (e) {
    caught = e;
  }
  check(caught is RpcException, 'error is RpcException (got $caught)');
  check((caught as RpcException).code == RpcCode.permissionDenied,
      'error code mapped (got ${caught.code})');

  print('CONNECT_OK');
}
''';
