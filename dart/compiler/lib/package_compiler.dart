/// Package-level ball-to-Dart compiler.
///
/// Compiles a multi-module ball [Program] (as produced by [PackageEncoder])
/// back into a full Dart package directory structure.
///
/// See [PackageCompiler] for the primary entry point.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';

import 'compiler.dart';
import 'package:ball_encoder/package_encoder.dart' show PackageEncoder;

// ─────────────────────────────────────────────────────────────────────────────

/// Compiles a multi-module ball [Program] into a full Dart package, producing
/// one `.dart` file per non-std module.
///
/// ## Output layout
///
/// Module names are converted back to file paths using the inverse of
/// [PackageEncoder.filePathToModuleName]:
///
/// | Ball module     | Output file path        |
/// |-----------------|-------------------------|
/// | `lib.src.models`| `lib/src/models.dart`   |
/// | `bin.main`      | `bin/main.dart`         |
///
/// ## Entry module
///
/// The module referenced by [Program.entryModule] is compiled with a `main()`
/// entry function.  All other user-defined modules are compiled without one.
///
/// ## pubspec.yaml and package manifest files
///
/// [PackageEncoder] embeds `pubspec.yaml`, `pubspec.lock`, and other root-level
/// config files as assets in the `__assets__` module.  [writeToDirectory]
/// extracts them verbatim — no reconstruction needed.
///
/// ## Usage — in memory
///
/// ```dart
/// final compiler = PackageCompiler(program);
/// final files = compiler.compileToMap();
/// // files: { 'lib/src/models.dart': '// Generated ...\nclass User { ... }', ... }
/// ```
///
/// ## Usage — write to disk
///
/// ```dart
/// final compiler = PackageCompiler(program);
/// compiler.writeToDirectory(Directory('/path/to/output'));
/// ```
class PackageCompiler {
  final Program program;

  /// Names of modules that are pure base (std, dart_std, external stubs).
  /// These are skipped during package compilation.
  late final Set<String> _baseModuleNames;

  PackageCompiler(this.program) {
    _baseModuleNames = {
      for (final m in program.modules)
        if (m.functions.isNotEmpty && m.functions.every((f) => f.isBase))
          m.name,
      // Also exclude modules that have no local content (stub-only).
      for (final m in program.modules)
        if (m.functions.isEmpty &&
            m.types.isEmpty &&
            m.typeDefs.isEmpty &&
            m.enums.isEmpty &&
            !_isUserModule(m.name))
          m.name,
    };
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Compile all user-defined modules and return a map from relative file
  /// path to Dart source code.
  ///
  /// Keys follow the layout described in the class documentation.
  /// The entry module is compiled with a `main()` function; all others
  /// are compiled without one.
  Map<String, String> compileToMap() {
    final compiler = DartCompiler(program);
    final result = <String, String>{};

    for (final module in program.modules) {
      if (_baseModuleNames.contains(module.name)) continue;
      if (_isExternalStub(module)) continue;

      final filePath = PackageEncoder.moduleNameToFilePath(module.name);
      final String dartSource;
      if (module.name == program.entryModule) {
        dartSource = compiler.compile();
      } else {
        dartSource = compiler.compileModule(module.name);
      }
      result[filePath] = dartSource;
    }

    return result;
  }

  /// Compile all modules and write the output files under [outputDir].
  ///
  /// Missing parent directories are created automatically.
  /// Existing files are overwritten.
  ///
  /// `pubspec.yaml`, `pubspec.lock`, and other package manifest files are
  /// restored from the embedded `__assets__` module (written by
  /// [PackageEncoder._collectResources]).
  ///
  /// Returns the list of written file paths (relative to [outputDir]).
  List<String> writeToDirectory(Directory outputDir) {
    final files = compileToMap();
    final written = <String>[];

    for (final MapEntry(key: relPath, value: source) in files.entries) {
      final file = File(
        '${outputDir.path}${Platform.pathSeparator}'
        '${relPath.replaceAll('/', Platform.pathSeparator)}',
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(source);
      written.add(relPath);
    }

    // Extract embedded assets — includes pubspec.yaml, pubspec.lock, and
    // any other non-Dart files captured during encoding.
    written.addAll(_extractResources(outputDir));

    return written;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Writes all [ModuleAsset] entries from every module in the program
  /// under [outputDir].
  ///
  /// Assets are de-duplicated by path (first occurrence wins).
  List<String> _extractResources(Directory outputDir) {
    final written = <String>[];
    final seen = <String>{};

    for (final module in program.modules) {
      for (final asset in module.assets) {
        final path = asset.path;
        if (path.isEmpty || !seen.add(path)) continue;

        try {
          var bytes = Uint8List.fromList(asset.content);

          // For pubspec.yaml assets in sub-directories, rewrite `path:`
          // dependencies that point outside the package root so they resolve
          // correctly within the compiled output.
          if (path.endsWith('pubspec.yaml') && path.contains('/')) {
            bytes = _fixResourcePubspec(path, bytes, outputDir);
          }

          final file = File(
            '${outputDir.path}${Platform.pathSeparator}'
            '${path.replaceAll('/', Platform.pathSeparator)}',
          );
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(bytes);
          written.add(path);
        } catch (_) {
          // Skip malformed entries.
        }
      }
    }
    return written;
  }

  /// Rewrite `path:` dependencies in a resource pubspec so that references
  /// to the parent package (e.g. `path: ../../dart/`) point to `../`
  /// (the compiled package root) instead.
  ///
  /// When the output package's own pubspec has `dependency_overrides` that
  /// cover deps listed in the resource pubspec, those overrides are mirrored
  /// (with paths adjusted for the sub-directory depth).
  Uint8List _fixResourcePubspec(
    String relPath,
    Uint8List bytes,
    Directory outputDir,
  ) {
    try {
      var content = utf8.decode(bytes);
      final depth = relPath.split('/').length - 1; // segments before filename

      // 1. Rewrite path: values that climb out of the package root.
      content = content.replaceAllMapped(RegExp(r'(path:\s*)([^\n]+)'), (m) {
        final prefix = m.group(1)!;
        final value = m
            .group(2)!
            .trim()
            .replaceAll("'", '')
            .replaceAll('"', '');
        final ups = '../'.allMatches(value).length;
        if (ups == 0) return m.group(0)!;
        if (ups >= depth) return '$prefix../';
        return m.group(0)!;
      });

      // 2. Propagate dependency_overrides from the parent package's pubspec
      //    so that path-overridden deps resolve correctly in the sub-project.
      final parentPubspec = File(
        '${outputDir.path}${Platform.pathSeparator}pubspec.yaml',
      );
      if (parentPubspec.existsSync()) {
        final parentContent = parentPubspec.readAsStringSync();
        final overrides = _extractDependencyOverrides(parentContent);
        if (overrides.isNotEmpty && !content.contains('dependency_overrides')) {
          final buf = StringBuffer('\ndependency_overrides:\n');
          for (final MapEntry(key: name, value: pathVal) in overrides.entries) {
            if (pathVal != null) {
              // Adjust relative path: parent pubspec says `../out_web`,
              // resource is [depth] levels deeper, so prepend `../` * depth.
              final adjusted = '${"../" * depth}$pathVal';
              buf.writeln('  $name:');
              buf.writeln('    path: $adjusted');
            } else {
              // Non-path override (e.g. version constraint) — copy as-is.
              buf.writeln('  $name: any');
            }
          }
          content += buf.toString();
        }
      }

      return Uint8List.fromList(utf8.encode(content));
    } catch (_) {
      return bytes;
    }
  }

  /// Extract `dependency_overrides` from a pubspec string.
  /// Returns a map of `packageName → pathValue` (null for non-path overrides).
  static Map<String, String?> _extractDependencyOverrides(String pubspec) {
    final result = <String, String?>{};
    final overridesMatch = RegExp(
      r'^dependency_overrides:\s*\r?\n((?:[ \t]+.*\r?\n)*)',
      multiLine: true,
    ).firstMatch(pubspec);
    if (overridesMatch == null) return result;
    final block = overridesMatch.group(1)!;
    if (block.trim().isEmpty) {
      // Regex captured nothing (e.g. section is at EOF without trailing
      // newline on every line).  Fall back to grabbing everything after
      // the `dependency_overrides:` line.
      final idx = pubspec.indexOf('dependency_overrides:');
      if (idx < 0) return result;
      final after = pubspec
          .substring(idx + 'dependency_overrides:'.length)
          .trimLeft();
      return _parseDependencyBlock(after);
    }
    return _parseDependencyBlock(block);
  }

  static Map<String, String?> _parseDependencyBlock(String block) {
    final result = <String, String?>{};
    // Parse simple YAML: "  name:\n    path: value" or "  name: constraint"
    String? currentPkg;
    for (final line in block.split(RegExp(r'\r?\n'))) {
      final pkgMatch = RegExp(r'^  (\w[\w-]*):\s*(.*)').firstMatch(line);
      if (pkgMatch != null) {
        currentPkg = pkgMatch.group(1)!; // ignore: unnecessary_null_checks
        final inline = pkgMatch.group(2)!.trim();
        if (inline.isNotEmpty) {
          result[currentPkg] = null; // inline constraint, not a path
          currentPkg = null;
        }
      } else if (currentPkg != null) {
        final pathMatch = RegExp(r'^\s+path:\s+(.+)').firstMatch(line);
        if (pathMatch != null) {
          result[currentPkg] = pathMatch.group(1)!.trim();
          currentPkg = null;
        }
      }
    }
    return result;
  }

  bool _isExternalStub(Module module) {
    // A stub module has no functions, types, type defs, or assets: it was
    // only added as a placeholder for an external package import.
    // Modules that carry assets (e.g. '__assets__') are NOT stubs even though
    // they have no Dart code — their content is written by _extractResources.
    return module.functions.isEmpty &&
        module.types.isEmpty &&
        module.typeDefs.isEmpty &&
        module.enums.isEmpty &&
        module.typeAliases.isEmpty &&
        module.assets.isEmpty;
  }

  static bool _isUserModule(String name) {
    return name.startsWith('lib.') ||
        name.startsWith('bin.') ||
        name.startsWith('test.') ||
        name == 'main';
  }
}
