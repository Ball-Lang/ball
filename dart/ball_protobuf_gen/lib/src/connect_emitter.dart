/// Connect-service emitter: turns the services in a `FileDescriptorSet` into
/// `<file>.connect.dart` files.
///
/// This is the Phase-4 / stage-2 deliverable from
/// `docs/PROTOBUF_CODEGEN_PLAN.md` §8: **service codegen is separate from
/// message codegen.** `protoc-gen-ball` emits the message `.pb.dart` files;
/// this emitter (driven by the separate `protoc-gen-ball-connect` plugin) emits
/// *only* the service files. A `.connect.dart` never re-declares a message — it
/// imports the message `.pb.dart` for its request/response types and reuses the
/// runtime descriptors those classes already carry.
///
/// For each service in a file we emit:
///   * a [`ServiceDescriptor`] const (from `package:ball_protobuf`): the
///     service FQN plus one [`MethodDescriptor`] per method, carrying the full
///     gRPC/Connect path `/{package}.{Service}/{Method}`, the input/output
///     message FQNs, the [`MethodKind`] (resolved from the
///     `client_streaming`/`server_streaming` flags), and the idempotency level;
///     and
///   * a typed client class taking a `ball_rpc` `RpcTransport` and exposing one
///     typed method per RPC. The method shape follows the streaming kind:
///       - unary           => `Future<Resp> m(Req req)`
///       - serverStreaming => `Stream<Resp> m(Req req)`
///       - clientStreaming => `Future<Resp> m(Stream<Req> reqs)`
///       - bidiStreaming   => `Stream<Resp> m(Stream<Req> reqs)`
///     Each method marshals the request(s) via the generated message type's
///     `toBytes`, calls the matching `RpcTransport` method with the full path,
///     and rehydrates the response(s) via `fromBytes`. No wire/framing logic is
///     generated; the transport (and, under it, the `ball_protobuf` runtime)
///     does all of it.
///
/// The service model, the `ServiceDescriptor` const, and the typed-client
/// method bodies are shared with the gRPC emitter via `service_common.dart`
/// (both produce identical clients over the transport-agnostic `RpcTransport`);
/// the Connect emitter only differs in the file extension, the doc comments
/// naming the default transport, and the `Connect`-suffixed client class.
///
/// Request/response types defined in a *different* `.proto` are reached through
/// the same cross-file import mechanism the message emitter uses: the referenced
/// type's message `.pb.dart` is imported under a stable `$pbN` prefix and the
/// Dart class name is qualified with it.
library;

import 'package:ball_base/ball_base.dart' show FileDescriptorProto;

import 'gen_model.dart';
import 'service_common.dart';

/// One generated Connect service file: its `/`-separated output path
/// (`foo/bar.connect.dart`) and Dart source.
class GeneratedConnectFile {
  /// `/`-separated output path, e.g. `acme/eliza.connect.dart`.
  final String path;

  /// The Dart source.
  final String content;

  const GeneratedConnectFile(this.path, this.content);
}

/// Builds [GeneratedConnectFile]s for every file in [fdsBytes] that declares at
/// least one service and whose name is in [filesToGenerate] (empty ⇒ every
/// service-bearing file). Files with no services produce no output.
///
/// Cross-file request/response types resolve through the message emitter's
/// output-path index (so a method whose I/O lives in another `.proto` imports
/// that sibling's `.pb.dart`).
List<GeneratedConnectFile> generateConnectServices(
  List<int> fdsBytes, {
  Set<String> filesToGenerate = const {},
}) {
  final builder = GenModelBuilder.fromBytes(fdsBytes);
  final dartNames = builder.dartNamesByFqn;
  final outputPaths = builder.outputPathByFqn;

  final out = <GeneratedConnectFile>[];
  for (final file in builder.files) {
    if (file.service.isEmpty) continue;
    if (filesToGenerate.isNotEmpty && !filesToGenerate.contains(file.name)) {
      continue;
    }
    out.add(_emitFile(file, dartNames, outputPaths));
  }
  return out;
}

/// `foo/bar.proto` -> `foo/bar.connect.dart`.
String _connectOutputPath(String protoPath) =>
    '${dropProtoExtension(protoPath)}.connect.dart';

GeneratedConnectFile _emitFile(
  FileDescriptorProto file,
  Map<String, String> dartNames,
  Map<String, String> outputPaths,
) {
  final pkg = file.package;

  // Build the resolved service views.
  final services = [
    for (final svc in file.service) buildServiceModel(svc, pkg),
  ];

  // Collect the message `.pb.dart` files this service file must import: the
  // own-file message output (always, since most I/O is local) plus the output
  // path of every referenced input/output type defined in a *different* file.
  // Each gets a stable `$pbN` import prefix.
  final ownMessagePath = messageOutputPath(file.name);
  final ownConnectPath = _connectOutputPath(file.name);
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
  // Message `.pb.dart` imports (relative to this connect file's directory).
  for (final p in sortedPaths) {
    final rel = relativeImport(ownConnectPath, p);
    b.writeln("import '$rel' as ${prefixByPath[p]};");
  }
  b.writeln();

  for (final s in services) {
    emitServiceDescriptor(b, s, '${s.protoName}ServiceDescriptor');
    b.writeln();
    _emitClient(b, s, classOf);
    b.writeln();
  }

  return GeneratedConnectFile(ownConnectPath, b.toString());
}

void _emitClient(
  StringBuffer b,
  ServiceModel s,
  String Function(String) classOf,
) {
  final clientName = '${s.protoName}Client';
  final descName = '${s.protoName}ServiceDescriptor';
  b.writeln('/// Typed Connect/gRPC client for `${s.fullName}`.');
  b.writeln('///');
  b.writeln(
    '/// Wraps a `ball_rpc` [\$rpc.RpcTransport]; each method marshals',
  );
  b.writeln('/// its request via the generated message `toBytes` and decodes');
  b.writeln('/// the response via `fromBytes` (the transport + ball_protobuf');
  b.writeln('/// runtime handle all wire framing).');
  b.writeln('class $clientName {');
  b.writeln('  /// The underlying bytes-level transport.');
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
    '// Generated by protoc-gen-ball-connect from $protoPath.\n'
    '// Typed RPC clients (ball_rpc) + ServiceDescriptors (ball_protobuf).\n'
    '//\n'
    '// ignore_for_file: prefer_const_constructors, non_constant_identifier_names\n'
    '// ignore_for_file: constant_identifier_names, library_prefixes\n'
    '// ignore_for_file: lines_longer_than_80_chars, unnecessary_cast\n';
