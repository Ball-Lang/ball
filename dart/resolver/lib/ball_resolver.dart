/// Ball module resolver — fetches, verifies, and caches modules from
/// HTTP, file, git, inline, and registry sources.
library;

export 'adapters/npm_adapter.dart' show NpmAdapter;
export 'adapters/pub_adapter.dart' show PubAdapter;
export 'adapters/registry_adapter.dart' show RegistryAdapter, ResolvedRegistryModule;
export 'adapters/registry_bridge.dart' show RegistryBridge, OnTheFlyEncoder;
export 'cache.dart' show ContentAddressableCache;
export 'integrity.dart'
    show computeIntegrity, computeIntegrityFromBytes, verifyIntegrity;
export 'resolver.dart' show ModuleResolver, RegistryResolver;
