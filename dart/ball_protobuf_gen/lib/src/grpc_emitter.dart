/// gRPC-service emitter: turns the services in a `FileDescriptorSet` into
/// `<file>.grpc.dart` files.
///
/// This is the Phase-4 / stage-3 deliverable from
/// `docs/PROTOBUF_CODEGEN_PLAN.md` §8: like `protoc-gen-ball-connect`, **service
/// codegen is separate from message codegen** and from the *other* service
/// plugin. `protoc-gen-ball` emits the message `.pb.dart` files; this emitter
/// (driven by the separate `protoc-gen-ball-grpc` plugin) emits *only*
/// `<file>.grpc.dart` service files. A `.grpc.dart` never re-declares a message
/// — it imports the message `.pb.dart` for its request/response types and
/// reuses the runtime descriptors those classes already carry.
///
/// For each service in a file we emit:
///   * the SAME `ball_protobuf` [`ServiceDescriptor`] const the Connect emitter
///     produces (emitted via the shared `service_common.dart` helper, so the
///     descriptor surface is byte-identical across the two service files);
///   * a typed `<Service>GrpcClient` class taking a `ball_rpc` `RpcTransport`
///     and exposing one typed method per RPC, with the same per-kind shapes as
///     the Connect client:
///       - unary           => `Future<Resp> m(Req req)`
///       - serverStreaming => `Stream<Resp> m(Req req)`
///       - clientStreaming => `Future<Resp> m(Stream<Req> reqs)`
///       - bidiStreaming   => `Stream<Resp> m(Stream<Req> reqs)`
///
/// The generated client is transport-agnostic at the Dart level — it delegates
/// bytes to whatever `RpcTransport` it is constructed with. The intended
/// transport for a `.grpc.dart` client is `ball_rpc`'s `GrpcTransport`, which
/// owns the gRPC-over-HTTP/2 specifics the brief calls out: the
/// `application/grpc+proto` content type, length-prefixed framing, and mapping
/// `grpc-status` / `grpc-message` trailers to an `RpcException`. None of that
/// wire logic is generated — the transport (and the `ball_protobuf` runtime
/// under it) does all of it. (The same client also runs over `ConnectTransport`
/// or `FakeTransport`; the difference between the Connect and gRPC plugins is
/// purely which default transport + content-type a consumer wires up, exactly
/// as connect-es ships decoupled service stubs over a pluggable transport.)
///
/// Request/response types defined in a *different* `.proto` are reached through
/// the same cross-file import mechanism the message + Connect emitters use: the
/// referenced type's message `.pb.dart` is imported under a stable `$pbN`
/// prefix and the Dart class name is qualified with it.
library;

import 'package:ball_base/ball_base.dart' show FileDescriptorProto;

import 'gen_model.dart';
import 'service_common.dart';

/// One generated gRPC service file: its `/`-separated output path
/// (`foo/bar.grpc.dart`) and Dart source.
class GeneratedGrpcFile {
  /// `/`-separated output path, e.g. `acme/eliza.grpc.dart`.
  final String path;

  /// The Dart source.
  final String content;

  const GeneratedGrpcFile(this.path, this.content);
}

/// Builds [GeneratedGrpcFile]s for every file in [fdsBytes] that declares at
/// least one service and whose name is in [filesToGenerate] (empty ⇒ every
/// service-bearing file). Files with no services produce no output.
///
/// Cross-file request/response types resolve through the message emitter's
/// output-path index (so a method whose I/O lives in another `.proto` imports
/// that sibling's `.pb.dart`).
List<GeneratedGrpcFile> generateGrpcServices(
  List<int> fdsBytes, {
  Set<String> filesToGenerate = const {},
}) {
  final builder = GenModelBuilder.fromBytes(fdsBytes);
  final dartNames = builder.dartNamesByFqn;
  final outputPaths = builder.outputPathByFqn;

  final out = <GeneratedGrpcFile>[];
  for (final file in builder.files) {
    if (file.service.isEmpty) continue;
    if (filesToGenerate.isNotEmpty && !filesToGenerate.contains(file.name)) {
      continue;
    }
    out.add(_emitFile(file, dartNames, outputPaths));
  }
  return out;
}

/// `foo/bar.proto` -> `foo/bar.grpc.dart`.
String _grpcOutputPath(String protoPath) =>
    '${dropProtoExtension(protoPath)}.grpc.dart';

GeneratedGrpcFile _emitFile(
  FileDescriptorProto file,
  Map<String, String> dartNames,
  Map<String, String> outputPaths,
) {
  final pkg = file.package;

  // Build the resolved service views (shared model with the Connect emitter).
  final services = [
    for (final svc in file.service) buildServiceModel(svc, pkg),
  ];

  // Collect the message `.pb.dart` files this service file must import: the
  // own-file message output (always, since most I/O is local) plus the output
  // path of every referenced input/output type defined in a *different* file.
  // Each gets a stable `$pbN` import prefix.
  final ownMessagePath = messageOutputPath(file.name);
  final ownGrpcPath = _grpcOutputPath(file.name);
  final imports = collectMessageImports(services, ownMessagePath, outputPaths);
  final sortedPaths = imports.sortedPaths;
  final prefixByPath = imports.prefixByPath;

  String classOf(String fqn) {
    final name = dartNames[fqn] ?? fqn.split('.').last;
    final path = outputPaths[fqn] ?? ownMessagePath;
    return '${prefixByPath[path]!}.$name';
  }

  final b = StringBuffer();
  b.write(_header(file.name));
  b.writeln();
  b.writeln("import 'dart:async';");
  b.writeln();
  b.writeln("import 'package:ball_protobuf/ball_protobuf.dart' as \$svc;");
  b.writeln("import 'package:ball_rpc/ball_rpc.dart' as \$rpc;");
  // Message `.pb.dart` imports (relative to this grpc file's directory).
  for (final p in sortedPaths) {
    final rel = relativeImport(ownGrpcPath, p);
    b.writeln("import '$rel' as ${prefixByPath[p]};");
  }
  b.writeln();

  for (final s in services) {
    // Same descriptor const name as the Connect emitter so a consumer wiring
    // either transport refers to the same `<Service>ServiceDescriptor`.
    emitServiceDescriptor(b, s, '${s.protoName}ServiceDescriptor');
    b.writeln();
    _emitClient(b, s, classOf);
    b.writeln();
  }

  return GeneratedGrpcFile(ownGrpcPath, b.toString());
}

void _emitClient(
  StringBuffer b,
  ServiceModel s,
  String Function(String) classOf,
) {
  // gRPC client is suffixed `GrpcClient` so a consumer can import both the
  // Connect (`<Service>Client`) and gRPC (`<Service>GrpcClient`) stubs into the
  // same scope without a name clash.
  final clientName = '${s.protoName}GrpcClient';
  final descName = '${s.protoName}ServiceDescriptor';
  b.writeln('/// Typed gRPC client for `${s.fullName}`.');
  b.writeln('///');
  b.writeln('/// Wraps a `ball_rpc` [\$rpc.RpcTransport] — typically a');
  b.writeln('/// `GrpcTransport` (gRPC-over-HTTP/2: `application/grpc+proto`,');
  b.writeln(
    '/// length-prefixed framing, `grpc-status`/`grpc-message` trailer',
  );
  b.writeln('/// mapping to `RpcException`). Each method marshals its request');
  b.writeln('/// via the generated message `toBytes` and decodes the response');
  b.writeln(
    '/// via `fromBytes`; the transport + ball_protobuf runtime handle',
  );
  b.writeln('/// all wire framing and status handling.');
  b.writeln('class $clientName {');
  b.writeln(
    '  /// The underlying bytes-level transport (e.g. `GrpcTransport`).',
  );
  b.writeln('  final \$rpc.RpcTransport transport;');
  b.writeln();
  b.writeln('  /// Optional default headers sent with every call.');
  b.writeln('  final \$rpc.RpcMetadata? headers;');
  b.writeln();
  b.writeln('  const $clientName(this.transport, {this.headers});');
  b.writeln();
  b.writeln('  /// The transport-agnostic service descriptor.');
  b.writeln('  static const \$svc.ServiceDescriptor descriptor = $descName;');
  for (final m in s.methods) {
    b.writeln();
    emitClientMethod(b, m, classOf);
  }
  b.writeln('}');
}

String _header(String protoPath) =>
    '// GENERATED CODE — DO NOT EDIT.\n'
    '//\n'
    '// Generated by protoc-gen-ball-grpc from $protoPath.\n'
    '// Typed gRPC clients (ball_rpc) + ServiceDescriptors (ball_protobuf).\n'
    '//\n'
    '// ignore_for_file: prefer_const_constructors, non_constant_identifier_names\n'
    '// ignore_for_file: constant_identifier_names, library_prefixes\n'
    '// ignore_for_file: lines_longer_than_80_chars, unnecessary_cast\n';
