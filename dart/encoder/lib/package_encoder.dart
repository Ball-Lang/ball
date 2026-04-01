/// Package-level Dart-to-ball encoder.
///
/// Encodes a full Dart package (a directory containing `pubspec.yaml`) into a
/// single ball [Program] where each `.dart` source file becomes its own ball
/// [Module].
///
/// See [PackageEncoder] for the primary entry point.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart' show parseString;
import 'package:analyzer/dart/ast/ast.dart' as ast;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';

import 'encoder.dart';
import 'pubspec_manifest.dart';
import 'pubspec_parser.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Encodes a full Dart package directory into a single ball [Program].
///
/// ## Module naming
///
/// Each `.dart` file is mapped to a ball module whose name is derived from its
/// path relative to the package root, with `/` replaced by `.` and the
/// `.dart` suffix removed:
///
/// | File path                  | Ball module name   |
/// |----------------------------|--------------------|
/// | `lib/src/models.dart`      | `lib.src.models`   |
/// | `lib/my_lib.dart`          | `lib.my_lib`       |
/// | `bin/server.dart`          | `bin.server`       |
///
/// ## Import resolution
///
/// Relative imports (`import 'src/utils.dart'`) and same-package imports
/// (`import 'package:mypkg/src/utils.dart'`) are both mapped to the
/// corresponding ball module.  External package imports (`import
/// 'package:other/...'`) are kept as empty stub modules.
///
/// ## Entry point
///
/// By default the encoder looks for `bin/main.dart`; if that does not exist
/// it picks the lexically first file that contains `void main`.  Override with
/// the [entryFile] / [entryFunction] parameters.
///
/// ## Usage
///
/// ```dart
/// final enc = PackageEncoder(Directory('/path/to/my_package'));
/// final program = enc.encode();
/// print(program.modules.length); // one module per .dart file + std
/// ```
class PackageEncoder {
  /// Root directory of the Dart package (must contain `pubspec.yaml`).
  final Directory packageDir;

  /// Full manifest parsed from `pubspec.yaml` + `pubspec.lock`.
  final PackageManifest manifest;

  /// Package name read from `pubspec.yaml` (convenience getter).
  String get packageName => manifest.name;

  /// Package version read from `pubspec.yaml` (convenience getter).
  String get packageVersion => manifest.version;

  /// Whether to also scan `test/` files.  Defaults to `false`.
  final bool includeTests;

  /// `relPath → moduleName` for every discovered `.dart` file.
  late final Map<String, String> _fileToModule;

  PackageEncoder(
    this.packageDir, {
    this.includeTests = false,
  })  : manifest = PubspecParser.fromDirectory(packageDir) {
    _fileToModule = _buildFileMap();
  }

  // ── Main public method ──────────────────────────────────────────────────

  /// Encode the whole package and return a ball [Program].
  ///
  /// [entryFile] is the relative path from [packageDir] to the Dart file that
  /// provides the package's `void main()` entry point (e.g. `'bin/main.dart'`).
  /// When omitted, the encoder auto-detects the entry file.
  ///
  /// [entryFunction] is the name of the entry function (default `'main'`).
  ///
  /// [scanDirs] overrides the set of top-level directories that are scanned for
  /// `.dart` files.  Defaults to `['lib', 'bin']` (plus `['test']` when
  /// [includeTests] is true).
  Program encode({
    String? entryFile,
    String entryFunction = 'main',
  }) {
    final String resolvedEntry =
        entryFile ?? _detectEntryFile() ?? 'bin/main.dart';
    final String entryModuleName =
        _fileToModule[resolvedEntry] ?? filePathToModuleName(resolvedEntry);

    final encoder = DartEncoder();
    // Accumulate all base functions across files; build std once at the end.

    final userModules = <Module>[];
    // External import stubs — deduplicated across all files.
    final externalStubs = <String, Module>{};
    // Internal module names already known (avoid duplicating in-package stubs).
    final inPackageModules = <String>{
      'std',
      'dart_std',
      ..._fileToModule.values,
    };

    for (final MapEntry(key: relPath, value: moduleName)
        in _fileToModule.entries) {
      final file = File('${packageDir.path}${Platform.pathSeparator}'
          '${relPath.replaceAll('/', Platform.pathSeparator)}');
      if (!file.existsSync()) continue;

      final source = file.readAsStringSync();
      // Parse once: reused for both URI-override resolution and encoding.
      final parseResult =
          parseString(content: source, throwIfDiagnostics: false);
      final uriOverrides =
          _computeUriOverridesFromUnit(relPath, parseResult.unit);

      final (:module, :importStubs) = encoder.encodeModuleFromUnit(
        parseResult.unit,
        moduleName: moduleName,
        uriToModuleOverrides: uriOverrides,
      );
      userModules.add(module);

      for (final stub in importStubs) {
        if (!inPackageModules.contains(stub.name) &&
            !externalStubs.containsKey(stub.name)) {
          externalStubs[stub.name] = stub;
        }
      }
    }

    final (:stdModule, :dartStdModule) = encoder.buildStdModules();

    // Sort user modules so the entry module is last (conventional positioning).
    userModules.sort((a, b) {
      if (a.name == entryModuleName) return 1;
      if (b.name == entryModuleName) return -1;
      return a.name.compareTo(b.name);
    });

    // Collect package manifest files (pubspec.yaml, pubspec.lock, etc.) and
    // any other non-Dart resources into a special __assets__ module.
    final resourceModule = _collectResources();

    return Program()
      ..name = packageName
      ..version = packageVersion
      ..entryModule = entryModuleName
      ..entryFunction = entryFunction
      ..modules.addAll([
        stdModule,
        ?dartStdModule,
        ...externalStubs.values,
        ...userModules,
        ?resourceModule,
      ]);
  }

  // ── File map ─────────────────────────────────────────────────────────────

  /// `relPath → moduleName` for every `.dart` file under the scanned dirs.
  ///
  /// Files that contain a `part of` directive (i.e. they are part-files, not
  /// standalone libraries) are excluded — they belong to their containing
  /// library and must not be encoded as independent modules.
  Map<String, String> _buildFileMap() {
    final map = <String, String>{};
    final dirs = ['lib', 'bin', if (includeTests) 'test'];
    for (final dirName in dirs) {
      final dir = Directory(
          '${packageDir.path}${Platform.pathSeparator}$dirName');
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;
        final rel = _relPath(entity.path, packageDir.path);
        // Skip `part of` files — they are not standalone libraries.
        if (_isPartFile(entity)) continue;
        map[rel] = filePathToModuleName(rel);
      }
    }
    return map;
  }

  /// Returns `true` if [file] starts with a `part of` directive (i.e. it is
  /// a library fragment, not an independent library).
  static bool _isPartFile(File file) {
    try {
      final source = file.readAsStringSync();
      final result = parseString(content: source, throwIfDiagnostics: false);
      return result.unit.directives.any((d) => d is ast.PartOfDirective);
    } catch (_) {
      return false;
    }
  }

  // ── Import resolution ─────────────────────────────────────────────────────

  /// Build a `rawImportUri → ballModuleName` map for all imports in [unit]
  /// that resolve to a known in-package file.
  ///
  /// Accepts a pre-parsed [ast.CompilationUnit] to avoid redundant parsing.
  Map<String, String> _computeUriOverridesFromUnit(
    String fileRelPath,
    ast.CompilationUnit unit,
  ) {
    final overrides = <String, String>{};
    for (final directive in unit.directives) {
      if (directive is ast.ImportDirective) {
        final uri = directive.uri.stringValue ?? '';
        if (uri.isEmpty) continue;
        final resolved = _resolveImportPath(fileRelPath, uri);
        if (resolved != null) {
          final moduleName = _fileToModule[resolved];
          if (moduleName != null) overrides[uri] = moduleName;
        }
      }
    }
    return overrides;
  }

  /// Resolve [importUri] relative to [fileRelPath] within the package.
  ///
  /// Returns the normalised package-relative path (e.g. `'lib/src/utils.dart'`)
  /// or `null` for external imports (`dart:` / external `package:`).
  String? _resolveImportPath(String fileRelPath, String importUri) {
    if (importUri.startsWith('dart:')) return null;
    if (importUri.startsWith('package:')) {
      final prefix = 'package:$packageName/';
      if (!importUri.startsWith(prefix)) return null; // external package
      // package:mypkg/src/utils.dart → lib/src/utils.dart
      return 'lib/${importUri.substring(prefix.length)}';
    }
    // Relative import: resolve against the directory of fileRelPath.
    final base = Uri.parse(fileRelPath.replaceAll('\\', '/'));
    final resolved = base.resolve(importUri);
    var path = resolved.path;
    // Normalise: strip leading slash that Uri.resolve may add.
    if (path.startsWith('/')) path = path.substring(1);
    return path;
  }

  // ── Entry point detection ─────────────────────────────────────────────────

  String? _detectEntryFile() {
    // Prefer bin/main.dart.
    if (_fileToModule.containsKey('bin/main.dart')) return 'bin/main.dart';
    // Find first bin/ file containing `void main` or `Future<void> main`.
    final binFiles = _fileToModule.keys
        .where((p) => p.startsWith('bin/'))
        .toList()
      ..sort();
    for (final path in binFiles) {
      final file = File('${packageDir.path}${Platform.pathSeparator}'
          '${path.replaceAll('/', Platform.pathSeparator)}');
      if (!file.existsSync()) continue;
      final content = file.readAsStringSync();
      if (_hasMainFunction(content)) return path;
    }
    return binFiles.isEmpty ? null : binFiles.first;
  }

  static bool _hasMainFunction(String source) {
    return RegExp(r'\bvoid\s+main\s*\(').hasMatch(source) ||
        RegExp(r'\bFuture<void>\s+main\s*\(').hasMatch(source) ||
        RegExp(r'\bFuture\s+main\s*\(').hasMatch(source);
  }

  // ── Resource collection ────────────────────────────────────────────────

  /// Well-known directories whose `.dart` files are already encoded as
  /// ball modules — we never treat these as opaque resources.
  static const _dartSourceDirs = {'lib', 'bin', 'test'};

  /// Directories to always skip (build artefacts, VCS, etc.).
  static const _ignoredDirs = {'.dart_tool', '.git', 'build', '.packages'};

  /// Maximum total size of resources to embed (50 MB).
  static const _maxResourceBytes = 50 * 1024 * 1024;

  /// Collect package manifest and resource files into a special
  /// `__assets__` [Module] whose [Module.assets] list carries every file
  /// as a [ModuleAsset].
  ///
  /// **Always embedded** (root-level):
  ///   - `pubspec.yaml`          — exact original, restored losslessly on compile-out
  ///   - `pubspec.lock`          — pinned resolved versions (if present)
  ///   - `analysis_options.yaml` — lint config
  ///   - `build.yaml`            — build_runner config
  ///   - `dart_test.yaml`        — test config
  ///   - `l10n.yaml`             — localisation config
  ///
  /// **Recursively embedded** (non-source sub-directories):
  ///   - Any directory that is not `lib/`, `bin/`, or `test/`.
  ///   - This covers fixture files, web assets, generated resources, etc.
  ///
  /// Test resources under `test/` are included when [includeTests] is `true`.
  Module? _collectResources() {
    final assets = <ModuleAsset>[];
    var totalBytes = 0;

    void addFile(String relPath, File file) {
      final bytes = file.readAsBytesSync();
      totalBytes += bytes.length;
      if (totalBytes > _maxResourceBytes) return;
      assets.add(ModuleAsset()
        ..path = relPath.replaceAll('\\', '/')
        ..content = bytes);
    }

    // Discover resource directories at the package root.
    for (final entity in packageDir.listSync()) {
      final name = entity.uri.pathSegments
          .lastWhere((s) => s.isNotEmpty, orElse: () => '');
      if (name.isEmpty || name.startsWith('.')) continue;
      if (_ignoredDirs.contains(name)) continue;

      if (entity is Directory && !_dartSourceDirs.contains(name)) {
        // Recursively collect everything under this non-Dart directory.
        for (final child in entity.listSync(recursive: true)) {
          if (child is! File) continue;
          final rel = _relPath(child.path, packageDir.path);
          addFile(rel, child);
        }
      } else if (entity is File && !entity.path.endsWith('.dart')) {
        // Embed package manifest files so the round-trip is lossless:
        // pubspec.yaml restores the exact original on compile-out.
        // pubspec.lock preserves pinned resolved versions.
        // analysis_options.yaml, dart_test.yaml etc. are also useful.
        // Skip everything else (README, CHANGELOG, etc.).
        if (name == 'pubspec.yaml' ||
            name == 'pubspec.lock' ||
            name == 'analysis_options.yaml' ||
            name == 'dart_test.yaml' ||
            name == 'build.yaml' ||
            name == 'l10n.yaml') {
          addFile(name, entity);
        }
      }
    }

    // Also collect non-Dart files inside test/ (e.g. test/test_resources/).
    if (includeTests) {
      final testDir = Directory(
          '${packageDir.path}${Platform.pathSeparator}test');
      if (testDir.existsSync()) {
        for (final child in testDir.listSync(recursive: true)) {
          if (child is! File) continue;
          if (child.path.endsWith('.dart')) continue;
          final rel = _relPath(child.path, packageDir.path);
          addFile(rel, child);
        }
      }
    }

    if (assets.isEmpty) return null;

    return Module()
      ..name = '__assets__'
      ..assets.addAll(assets);
  }

  // ── Utilities ────────────────────────────────────────────────────────────

  /// Convert a package-relative file path to a ball module name.
  ///
  /// Examples:
  /// - `lib/src/utils.dart` → `lib.src.utils`
  /// - `bin/main.dart`       → `bin.main`
  static String filePathToModuleName(String relPath) {
    var name = relPath.replaceAll('\\', '/');
    if (name.endsWith('.dart')) name = name.substring(0, name.length - 5);
    // Replace all separators and normalise non-identifier chars.
    return name.replaceAll('/', '.').replaceAll('-', '_');
  }

  /// Convert a ball module name back to a relative file path.
  ///
  /// Examples:
  /// - `lib.src.utils` → `lib/src/utils.dart`
  /// - `bin.main`       → `bin/main.dart`
  static String moduleNameToFilePath(String moduleName) =>
      '${moduleName.replaceAll('.', '/')}.dart';

  static String _relPath(String absPath, String basePath) {
    // Normalise separators.
    final abs = absPath.replaceAll('\\', '/');
    var base = basePath.replaceAll('\\', '/');
    if (!base.endsWith('/')) base += '/';
    if (abs.startsWith(base)) return abs.substring(base.length);
    return abs; // fallback: return as-is
  }

  // ── Read-only accessors ───────────────────────────────────────────────────

  /// All discovered source files and their ball module names.
  ///
  /// Keys are package-relative paths; values are ball module names.
  Map<String, String> get fileToModuleMap =>
      Map.unmodifiable(_fileToModule);
}
