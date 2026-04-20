/// Registry bridge — routes RegistrySource imports to the appropriate adapter.
///
/// Usage:
///   final bridge = RegistryBridge()
///     ..register(PubAdapter())
///     ..register(NpmAdapter());
///   final resolver = ModuleResolver(registryResolver: bridge.resolve);
library;

import 'dart:convert';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';

import 'registry_adapter.dart';

class RegistryBridge {
  final Map<Registry, RegistryAdapter> _adapters = {};

  void register(RegistryAdapter adapter) {
    _adapters[adapter.registryType] = adapter;
  }

  /// Resolve a RegistrySource import to a Module.
  /// Designed to be passed as `ModuleResolver(registryResolver: bridge.resolve)`.
  Future<Module> resolve(RegistrySource source) async {
    final adapter = _adapters[source.registry];
    if (adapter == null) {
      throw StateError(
        'No adapter registered for registry ${source.registry.name}. '
        'Register one via RegistryBridge.register().',
      );
    }

    final version = await adapter.resolveVersion(
      source.package,
      source.version,
      registryUrl: source.registryUrl.isEmpty ? null : source.registryUrl,
    );

    try {
      final result = await adapter.fetchModule(
        source.package,
        version,
        modulePath: source.modulePath.isEmpty ? null : source.modulePath,
        encoding: source.encoding,
        registryUrl: source.registryUrl.isEmpty ? null : source.registryUrl,
      );

      if (result.encoding == ModuleEncoding.MODULE_ENCODING_PROTO) {
        return Module.fromBuffer(result.bytes);
      }
      return Module()
        ..mergeFromProto3Json(
          jsonDecode(String.fromCharCodes(result.bytes)),
          ignoreUnknownFields: true,
        );
    } on StateError {
      // If the adapter can't find a pre-packaged Ball artifact (or
      // the download fails because there IS no Ball-specific archive),
      // try the on-the-fly encoding fallback: download the package
      // source and encode it via the Dart encoder.
      if (onTheFlyEncoder != null) {
        return onTheFlyEncoder!(source, version);
      }
      rethrow;
    }
  }

  /// Optional callback that downloads + encodes a package on-the-fly
  /// when no pre-built Ball artifact is found in the registry archive.
  /// Set by the CLI when it has access to the encoder.
  OnTheFlyEncoder? onTheFlyEncoder;
}

/// Callback type for on-the-fly encoding of packages that don't
/// publish Ball artifacts. The CLI provides this using [PubClient]
/// + [PackageEncoder].
typedef OnTheFlyEncoder = Future<Module> Function(
  RegistrySource source,
  String resolvedVersion,
);
