/// Abstract interface for resolving Ball modules from package registries.
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';

/// Result of fetching a module from a registry.
class ResolvedRegistryModule {
  final List<int> bytes;
  final ModuleEncoding encoding;
  final String resolvedVersion;
  final String sourceUrl;

  const ResolvedRegistryModule({
    required this.bytes,
    required this.encoding,
    required this.resolvedVersion,
    required this.sourceUrl,
  });
}

/// Abstract adapter for a specific package registry.
///
/// Each registry (pub, npm, nuget, etc.) implements this interface.
/// The resolver dispatches RegistrySource imports to the matching adapter.
abstract class RegistryAdapter {
  Registry get registryType;
  String get defaultUrl;

  /// Resolve a version constraint to the best matching concrete version.
  Future<String> resolveVersion(
    String package,
    String constraint, {
    String? registryUrl,
    Map<String, String>? headers,
  });

  /// Download the package archive and extract the Ball module bytes.
  Future<ResolvedRegistryModule> fetchModule(
    String package,
    String version, {
    String? modulePath,
    ModuleEncoding encoding,
    String? registryUrl,
    Map<String, String>? headers,
  });
}
