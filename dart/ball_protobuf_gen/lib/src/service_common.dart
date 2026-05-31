/// Target-independent service model + shared emission helpers for the service
/// plugins (`protoc-gen-ball-connect` and `protoc-gen-ball-grpc`).
///
/// Service codegen is split from message codegen (see
/// `docs/PROTOBUF_CODEGEN_PLAN.md` §8): `protoc-gen-ball` emits the message
/// `.pb.dart` files, and the two service plugins emit *only* their service
/// files. A Connect file (`.connect.dart`) and a gRPC file (`.grpc.dart`) share
/// almost everything: the same resolved [ServiceModel]/[MethodModel] view, the
/// same `ball_protobuf` [ServiceDescriptor] const, and the same typed-client
/// method bodies (which delegate to a transport-agnostic `ball_rpc`
/// `RpcTransport`). The *only* differences are the file extension, the client
/// class name, and the doc comments naming the default transport. This library
/// holds the common parts so neither emitter duplicates them.
library;

import 'package:ball_base/ball_base.dart'
    show
        MethodDescriptorProto,
        MethodOptions_IdempotencyLevel,
        ServiceDescriptorProto;

import 'gen_model.dart' show toLowerCamel;

/// The streaming kind of a method, mirroring `ball_protobuf`'s `MethodKind`.
/// Local enum so an emitter has no `package:ball_protobuf` import of its own
/// (it only *emits* references to the runtime enum).
enum ServiceMethodKind {
  unary,
  serverStreaming,
  clientStreaming,
  bidiStreaming,
}

/// Resolves the [ServiceMethodKind] from a method's streaming flags.
ServiceMethodKind methodKindOf(MethodDescriptorProto m) {
  if (m.clientStreaming && m.serverStreaming) {
    return ServiceMethodKind.bidiStreaming;
  }
  if (m.clientStreaming) return ServiceMethodKind.clientStreaming;
  if (m.serverStreaming) return ServiceMethodKind.serverStreaming;
  return ServiceMethodKind.unary;
}

/// The `ball_protobuf` `MethodKind` enum-value name for [k].
String kindEnumName(ServiceMethodKind k) => switch (k) {
  ServiceMethodKind.unary => 'unary',
  ServiceMethodKind.serverStreaming => 'serverStreaming',
  ServiceMethodKind.clientStreaming => 'clientStreaming',
  ServiceMethodKind.bidiStreaming => 'bidiStreaming',
};

/// The `ball_protobuf` `IdempotencyLevel` enum-value name for a method's
/// `MethodOptions.idempotency_level`.
String idempotencyEnumName(MethodOptions_IdempotencyLevel level) =>
    switch (level) {
      MethodOptions_IdempotencyLevel.NO_SIDE_EFFECTS => 'noSideEffects',
      MethodOptions_IdempotencyLevel.IDEMPOTENT => 'idempotent',
      _ => 'idempotencyUnknown',
    };

// ---------------------------------------------------------------------------
// Service model (target-independent).
// ---------------------------------------------------------------------------

/// A resolved view of one RPC method, ready to emit.
class MethodModel {
  /// Short method name, e.g. `Unary`.
  final String name;

  /// lowerCamel client method, e.g. `unary`.
  final String dartName;

  /// gRPC/Connect path `/{package}.{Service}/{Method}`.
  final String path;

  /// The streaming kind.
  final ServiceMethodKind kind;

  /// Stripped (no leading dot) input message FQN.
  final String inputFqn;

  /// Stripped (no leading dot) output message FQN.
  final String outputFqn;

  /// The method's idempotency level.
  final MethodOptions_IdempotencyLevel idempotency;

  MethodModel({
    required this.name,
    required this.dartName,
    required this.path,
    required this.kind,
    required this.inputFqn,
    required this.outputFqn,
    required this.idempotency,
  });
}

/// A resolved view of one service, ready to emit.
class ServiceModel {
  /// `{package}.{Service}`.
  final String fullName;

  /// The proto service name (client class base), e.g. `Eliza`.
  final String protoName;

  /// This service's methods.
  final List<MethodModel> methods;

  ServiceModel({
    required this.fullName,
    required this.protoName,
    required this.methods,
  });
}

String stripLeadingDot(String fqn) =>
    fqn.startsWith('.') ? fqn.substring(1) : fqn;

/// Builds the resolved [ServiceModel] for [svc] in package [pkg].
ServiceModel buildServiceModel(ServiceDescriptorProto svc, String pkg) {
  final pkgPrefix = pkg.isEmpty ? '' : '$pkg.';
  final fullName = '$pkgPrefix${svc.name}';
  final methods = <MethodModel>[];
  final usedDartNames = <String>{};
  for (final m in svc.method) {
    final dartName = _uniqueMethodName(
      escapeIdentifier(lowerCamelMethod(m.name)),
      usedDartNames,
    );
    methods.add(
      MethodModel(
        name: m.name,
        dartName: dartName,
        path: '/$fullName/${m.name}',
        kind: methodKindOf(m),
        inputFqn: stripLeadingDot(m.inputType),
        outputFqn: stripLeadingDot(m.outputType),
        idempotency: m.hasOptions()
            ? m.options.idempotencyLevel
            : MethodOptions_IdempotencyLevel.IDEMPOTENCY_UNKNOWN,
      ),
    );
  }
  return ServiceModel(
    fullName: fullName,
    protoName: svc.name,
    methods: methods,
  );
}

String _uniqueMethodName(String base, Set<String> used) {
  var name = base;
  var i = 2;
  while (used.contains(name)) {
    name = '$base$i';
    i++;
  }
  used.add(name);
  return name;
}

// ---------------------------------------------------------------------------
// Shared emission: the ServiceDescriptor const (identical for both targets).
// ---------------------------------------------------------------------------

/// Emits a `ball_protobuf` `ServiceDescriptor` const named [descName] for [s],
/// referencing the runtime under the [svcPrefix] import alias (`$svc`).
///
/// Both the Connect and gRPC emitters call this so the descriptor surface is
/// byte-identical across the two generated files.
void emitServiceDescriptor(
  StringBuffer b,
  ServiceModel s,
  String descName, {
  String svcPrefix = r'$svc',
}) {
  b.writeln('/// Transport-agnostic descriptor for `${s.fullName}`.');
  b.writeln(
    'const $svcPrefix.ServiceDescriptor $descName = '
    '$svcPrefix.ServiceDescriptor(',
  );
  b.writeln("  fullName: '${s.fullName}',");
  b.writeln('  methods: [');
  for (final m in s.methods) {
    b.writeln('    $svcPrefix.MethodDescriptor(');
    b.writeln("      name: '${m.name}',");
    b.writeln("      fullName: '${s.fullName}.${m.name}',");
    b.writeln("      inputDescriptor: '${m.inputFqn}',");
    b.writeln("      outputDescriptor: '${m.outputFqn}',");
    b.writeln('      kind: $svcPrefix.MethodKind.${kindEnumName(m.kind)},');
    b.writeln(
      '      idempotency: '
      '$svcPrefix.IdempotencyLevel.${idempotencyEnumName(m.idempotency)},',
    );
    b.writeln('    ),');
  }
  b.writeln('  ]);');
}

/// Emits one typed client method [m] into [b], resolving I/O Dart class names
/// via [classOf]. The body delegates to a transport-agnostic `RpcTransport`
/// (`$rpc`), so the same method shape works over both Connect and gRPC.
void emitClientMethod(
  StringBuffer b,
  MethodModel m,
  String Function(String) classOf,
) {
  final reqType = classOf(m.inputFqn);
  final respType = classOf(m.outputFqn);
  final path = "'${m.path}'";
  b.writeln('  /// `${m.name}` (${kindEnumName(m.kind)}).');
  switch (m.kind) {
    case ServiceMethodKind.unary:
      b.writeln('  Future<$respType> ${m.dartName}($reqType request) async {');
      b.writeln('    final bytes = await transport.unary(');
      b.writeln('      $path, request.toBytes(), headers: headers);');
      b.writeln('    return $respType.fromBytes(bytes);');
      b.writeln('  }');
    case ServiceMethodKind.serverStreaming:
      b.writeln('  Stream<$respType> ${m.dartName}($reqType request) {');
      b.writeln('    return transport');
      b.writeln('        .serverStream($path, request.toBytes(),');
      b.writeln('            headers: headers)');
      b.writeln('        .map($respType.fromBytes);');
      b.writeln('  }');
    case ServiceMethodKind.clientStreaming:
      b.writeln(
        '  Future<$respType> ${m.dartName}(Stream<$reqType> requests) async {',
      );
      b.writeln('    final bytes = await transport.clientStream(');
      b.writeln('      $path, requests.map((r) => r.toBytes()),');
      b.writeln('      headers: headers);');
      b.writeln('    return $respType.fromBytes(bytes);');
      b.writeln('  }');
    case ServiceMethodKind.bidiStreaming:
      b.writeln(
        '  Stream<$respType> ${m.dartName}(Stream<$reqType> requests) {',
      );
      b.writeln('    return transport');
      b.writeln('        .bidiStream(');
      b.writeln('            $path, requests.map((r) => r.toBytes()),');
      b.writeln('            headers: headers)');
      b.writeln('        .map($respType.fromBytes);');
      b.writeln('  }');
  }
}

// ---------------------------------------------------------------------------
// Shared path / import / identifier helpers.
// ---------------------------------------------------------------------------

/// `foo/bar.proto` -> `foo/bar` (drops the `.proto` extension if present).
String dropProtoExtension(String protoPath) => protoPath.endsWith('.proto')
    ? protoPath.substring(0, protoPath.length - '.proto'.length)
    : protoPath;

/// `foo/bar.proto` -> `foo/bar.pb.dart` (the message file a service file
/// imports for locally-defined I/O types).
String messageOutputPath(String protoPath) =>
    '${dropProtoExtension(protoPath)}.pb.dart';

/// Builds a relative `import` path from [fromOutputPath] to [toOutputPath]
/// (both `/`-separated generated paths). Mirrors `gen_model.dart`'s helper.
String relativeImport(String fromOutputPath, String toOutputPath) {
  final fromParts = fromOutputPath.split('/');
  final toParts = toOutputPath.split('/');
  final fromDir = fromParts.sublist(0, fromParts.length - 1);
  final toDir = toParts.sublist(0, toParts.length - 1);
  var common = 0;
  while (common < fromDir.length &&
      common < toDir.length &&
      fromDir[common] == toDir[common]) {
    common++;
  }
  final ups = List.filled(fromDir.length - common, '..');
  final downs = toParts.sublist(common);
  final rel = [...ups, ...downs].join('/');
  return rel.isEmpty ? toParts.last : rel;
}

/// Collects the `.pb.dart` paths a service file must import (own message file
/// plus every cross-file I/O type), and assigns each a stable `$pbN` prefix.
///
/// Returns the sorted path list and a `path -> prefix` map. [outputPaths] maps a
/// message/enum FQN to the `.pb.dart` defining it; an unmapped FQN falls back to
/// [ownMessagePath] (the same-file message output).
({List<String> sortedPaths, Map<String, String> prefixByPath})
collectMessageImports(
  List<ServiceModel> services,
  String ownMessagePath,
  Map<String, String> outputPaths,
) {
  // Only import a `.pb.dart` we actually reference. We intentionally do NOT
  // seed [ownMessagePath]: a service file whose every request/response type is
  // defined in another .proto must not import its own (message-less) .pb.dart,
  // or the generated file emits an `unused_import` analyzer warning. Same-file
  // I/O types still pull [ownMessagePath] in via the lookup/fallback below.
  final referencedPaths = <String>{};
  for (final s in services) {
    for (final m in s.methods) {
      referencedPaths.add(outputPaths[m.inputFqn] ?? ownMessagePath);
      referencedPaths.add(outputPaths[m.outputFqn] ?? ownMessagePath);
    }
  }
  final sortedPaths = referencedPaths.toList()..sort();
  final prefixByPath = <String, String>{};
  for (var i = 0; i < sortedPaths.length; i++) {
    prefixByPath[sortedPaths[i]] = '\$pb$i';
  }
  return (sortedPaths: sortedPaths, prefixByPath: prefixByPath);
}

/// PascalCase / snake-cased method name -> lowerCamelCase Dart method name.
String lowerCamelMethod(String name) {
  if (name.isEmpty) return name;
  // Method names are typically PascalCase (`SayHello`); snake names are folded
  // via toLowerCamel (shared with the message emitter naming).
  if (name.contains('_')) return toLowerCamel(name);
  return name[0].toLowerCase() + name.substring(1);
}

/// Dart reserved words that cannot be used as method identifiers.
const Set<String> dartKeywords = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

/// Appends a trailing `_` to a Dart reserved word so it is a legal identifier.
String escapeIdentifier(String name) =>
    dartKeywords.contains(name) ? '${name}_' : name;
