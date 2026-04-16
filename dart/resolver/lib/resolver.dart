/// Core module resolver for Ball programs.
///
/// Given a [ModuleImport], resolves it to a [Module] by dispatching to
/// the appropriate fetcher (inline, file, HTTP, git, or registry), verifying
/// integrity, caching the result, and recursively resolving transitive imports.
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:http/http.dart' as http;

import 'cache.dart';
import 'fetchers/file_fetcher.dart' as file_fetcher;
import 'fetchers/git_fetcher.dart' as git_fetcher;
import 'fetchers/http_fetcher.dart' as http_fetcher;
import 'fetchers/inline_fetcher.dart' as inline_fetcher;
import 'integrity.dart';

/// Callback for resolving RegistrySource imports. Provided by Stage 4
/// registry adapters. When null, RegistrySource imports fail with an error.
typedef RegistryResolver = Future<Module> Function(RegistrySource source);

/// Resolves [ModuleImport] entries to concrete [Module] instances.
class ModuleResolver {
  final ContentAddressableCache cache;
  final http.Client? httpClient;
  final RegistryResolver? registryResolver;
  final String? basePath;

  final Set<String> _resolving = {};

  ModuleResolver({
    ContentAddressableCache? cache,
    this.httpClient,
    this.registryResolver,
    this.basePath,
  }) : cache = cache ?? ContentAddressableCache();

  /// Resolve a single ModuleImport to a Module.
  Future<Module> resolve(ModuleImport import_) async {
    // Fast path: integrity hash present and cached.
    if (import_.integrity.isNotEmpty && cache.has(import_.integrity)) {
      return cache.get(import_.integrity)!;
    }

    // Dispatch on source type.
    final module = await _fetch(import_);

    // Verify integrity if specified.
    if (import_.integrity.isNotEmpty) {
      if (!verifyIntegrity(module, import_.integrity)) {
        throw StateError(
          'Integrity check failed for module "${import_.name}". '
          'Expected: ${import_.integrity}, '
          'Got: ${computeIntegrity(module)}',
        );
      }
    }

    // Cache the resolved module.
    cache.put(module);

    // Recursively resolve this module's own imports.
    await _resolveTransitive(module);

    return module;
  }

  /// Resolve all ModuleImport entries in a Program, returning a new
  /// Program with all imports inlined as concrete modules.
  Future<Program> resolveAll(Program program) async {
    final resolvedModules = <String, Module>{};
    for (final m in program.modules) {
      resolvedModules[m.name] = m;
    }

    for (final m in program.modules) {
      for (final import_ in m.moduleImports) {
        if (resolvedModules.containsKey(import_.name)) continue;
        try {
          final resolved = await resolve(import_);
          resolvedModules[import_.name] = resolved;
        } catch (e) {
          // If resolution fails, leave the import unresolved.
          // Engines/compilers will report the missing module.
        }
      }
    }

    return Program()
      ..name = program.name
      ..version = program.version
      ..entryModule = program.entryModule
      ..entryFunction = program.entryFunction
      ..metadata = program.metadata
      ..modules.addAll(resolvedModules.values);
  }

  Future<Module> _fetch(ModuleImport import_) async {
    if (import_.hasInline()) {
      return inline_fetcher.fetchInline(import_.inline);
    }
    if (import_.hasFile()) {
      return file_fetcher.fetchFile(import_.file, basePath: basePath);
    }
    if (import_.hasHttp()) {
      return http_fetcher.fetchHttp(import_.http, client: httpClient);
    }
    if (import_.hasGit()) {
      return git_fetcher.fetchGit(import_.git);
    }
    if (import_.hasRegistry()) {
      if (registryResolver == null) {
        throw StateError(
          'RegistrySource import "${import_.name}" requires a registry '
          'resolver, but none was configured. Install registry adapters '
          'or use `ball fetch` to pre-resolve.',
        );
      }
      return registryResolver!(import_.registry);
    }
    throw StateError(
      'ModuleImport "${import_.name}" has no source set. '
      'Specify one of: http, file, inline, git, or registry.',
    );
  }

  Future<void> _resolveTransitive(Module module) async {
    for (final import_ in module.moduleImports) {
      final key = import_.name;
      if (_resolving.contains(key)) continue;
      _resolving.add(key);
      try {
        await resolve(import_);
      } catch (_) {
        // Transitive resolution failures are non-fatal.
      } finally {
        _resolving.remove(key);
      }
    }
  }
}
