/// Round-trip validation comparing stub-only vs resolved external deps.
///
/// Downloads a single pub package, encodes it twice:
///   1. Without dependency resolution (stubs only) -- baseline
///   2. With `resolveExternalDeps: true` via `encodeAsync()` -- resolved
///
/// Compiles both back to Dart, writes to proper directory structures,
/// runs `dart analyze` on each, and reports the error delta.
///
///   dart run ball_encoder:roundtrip_resolved <package_name> [--max-depth <n>]
///
/// Example:
///   dart run ball_encoder:roundtrip_resolved logging
///   dart run ball_encoder:roundtrip_resolved term_glyph --max-depth 3
library;

import 'dart:io';

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run ball_encoder:roundtrip_resolved <package_name> '
      '[--max-depth <n>]',
    );
    exit(1);
  }

  final packageName = args.first;
  final depthIdx = args.indexOf('--max-depth');
  final maxDepth =
      depthIdx >= 0 && depthIdx + 1 < args.length
          ? int.tryParse(args[depthIdx + 1]) ?? 5
          : 5;

  final client = PubClient();

  try {
    // ── 1. Download the package ──────────────────────────────────────────
    stdout.writeln('Ball Round-Trip: Stub vs Resolved Comparison');
    stdout.writeln('=' * 60);
    stdout.writeln('Package: $packageName');
    stdout.writeln('');

    stdout.writeln('1. Resolving $packageName from pub.dev...');
    final vi = await client.resolveVersion(packageName, 'any');
    stdout.writeln('   Version: ${vi.version}');

    stdout.writeln('2. Downloading package archive...');
    final pkgDir = await client.downloadPackage(
      packageName,
      vi.version,
      archiveUrl: vi.archiveUrl,
    );

    try {
      // ── 2. Encode WITHOUT dep resolution (baseline) ──────────────────
      stdout.writeln('');
      stdout.writeln('--- Phase A: Encode with STUBS (no dep resolution) ---');
      final stubEncoder = PackageEncoder(pkgDir);
      final stubProgram = stubEncoder.encode();

      final stubCompiler = DartCompiler(stubProgram, noFormat: true);
      final stubModules = stubCompiler.compileAllModules();
      stdout.writeln(
        '   Encoded ${stubProgram.modules.length} modules, '
        'compiled ${stubModules.length}',
      );

      final stubDir = await _writePackage(
        packageName,
        stubModules,
        stubProgram,
        'stubs',
      );
      stdout.writeln('   Written to: ${stubDir.path}');

      stdout.writeln('   Running dart analyze (stubs)...');
      final stubAnalysis = await _runAnalyze(stubDir);

      // ── 3. Encode WITH dep resolution ────────────────────────────────
      stdout.writeln('');
      stdout.writeln(
        '--- Phase B: Encode with RESOLVED deps '
        '(maxDepth=$maxDepth) ---',
      );

      final resolverClient = PubClient();
      final resolvedEncoder = PackageEncoder(
        pkgDir,
        resolveExternalDeps: true,
        pubClient: resolverClient,
        maxDepth: maxDepth,
      );

      late final resolvedProgram;
      try {
        resolvedProgram = await resolvedEncoder.encodeAsync();
      } catch (e, st) {
        stdout.writeln('');
        stdout.writeln('   ERROR: encodeAsync() failed!');
        stdout.writeln('   $e');
        stdout.writeln('   ${st.toString().split('\n').take(10).join('\n')}');
        stdout.writeln('');
        stdout.writeln('--- Stub-Only Results (baseline) ---');
        _printAnalysis('Stubs', stubAnalysis);
        stdout.writeln('');
        stdout.writeln(
          'Cannot compare -- encodeAsync() failed. '
          'See error above for what needs fixing.',
        );
        resolverClient.close();
        return;
      }

      // Print warnings from dependency resolution.
      if (resolvedEncoder.warnings.isNotEmpty) {
        stdout.writeln('   Dep resolution warnings:');
        for (final w in resolvedEncoder.warnings) {
          stdout.writeln('     ! $w');
        }
      }

      final resolvedCompiler = DartCompiler(resolvedProgram, noFormat: true);
      final resolvedModules = resolvedCompiler.compileAllModules();
      stdout.writeln(
        '   Encoded ${resolvedProgram.modules.length} modules, '
        'compiled ${resolvedModules.length}',
      );

      final resolvedDir = await _writePackage(
        packageName,
        resolvedModules,
        resolvedProgram,
        'resolved',
      );
      stdout.writeln('   Written to: ${resolvedDir.path}');

      stdout.writeln('   Running dart analyze (resolved)...');
      final resolvedAnalysis = await _runAnalyze(resolvedDir);

      resolverClient.close();

      // ── 4. Report ────────────────────────────────────────────────────
      stdout.writeln('');
      stdout.writeln('=' * 60);
      stdout.writeln('RESULTS: $packageName v${vi.version}');
      stdout.writeln('=' * 60);
      stdout.writeln('');

      _printAnalysis('Stubs (no dep resolution)', stubAnalysis);
      stdout.writeln('');
      _printAnalysis('Resolved (with dep resolution)', resolvedAnalysis);
      stdout.writeln('');

      final errorDelta = resolvedAnalysis.errors - stubAnalysis.errors;
      final warningDelta = resolvedAnalysis.warnings - stubAnalysis.warnings;
      stdout.writeln('--- Delta (resolved - stubs) ---');
      stdout.writeln(
        '  Errors:   ${_delta(errorDelta)} '
        '(${stubAnalysis.errors} -> ${resolvedAnalysis.errors})',
      );
      stdout.writeln(
        '  Warnings: ${_delta(warningDelta)} '
        '(${stubAnalysis.warnings} -> ${resolvedAnalysis.warnings})',
      );
      stdout.writeln(
        '  Infos:    ${_delta(resolvedAnalysis.infos - stubAnalysis.infos)} '
        '(${stubAnalysis.infos} -> ${resolvedAnalysis.infos})',
      );
      stdout.writeln('');

      if (errorDelta < 0) {
        stdout.writeln(
          'IMPROVEMENT: Dep resolution reduced errors by '
          '${-errorDelta}!',
        );
      } else if (errorDelta == 0) {
        stdout.writeln('NO CHANGE: Same number of errors with dep resolution.');
      } else {
        stdout.writeln(
          'REGRESSION: Dep resolution increased errors by $errorDelta. '
          'This may indicate issues with resolved module compilation.',
        );
      }

      stdout.writeln('');
      stdout.writeln('Output directories (preserved for inspection):');
      stdout.writeln('  Stubs:    ${stubDir.path}');
      stdout.writeln('  Resolved: ${resolvedDir.path}');

      // Print first 30 error lines from each for quick comparison.
      if (stubAnalysis.errorLines.isNotEmpty) {
        stdout.writeln('');
        stdout.writeln('--- Sample errors (stubs) ---');
        for (final line in stubAnalysis.errorLines.take(30)) {
          stdout.writeln('  $line');
        }
        if (stubAnalysis.errorLines.length > 30) {
          stdout.writeln(
            '  ... and ${stubAnalysis.errorLines.length - 30} more',
          );
        }
      }

      if (resolvedAnalysis.errorLines.isNotEmpty) {
        stdout.writeln('');
        stdout.writeln('--- Sample errors (resolved) ---');
        for (final line in resolvedAnalysis.errorLines.take(30)) {
          stdout.writeln('  $line');
        }
        if (resolvedAnalysis.errorLines.length > 30) {
          stdout.writeln(
            '  ... and ${resolvedAnalysis.errorLines.length - 30} more',
          );
        }
      }
    } finally {
      try {
        await pkgDir.delete(recursive: true);
      } catch (_) {}
    }
  } catch (e, st) {
    stderr.writeln('Fatal error: $e');
    stderr.writeln(st);
    exit(2);
  } finally {
    client.close();
  }
}

/// Write compiled modules to a proper Dart package directory.
Future<Directory> _writePackage(
  String packageName,
  Map<String, String> modules,
  dynamic program,
  String suffix,
) async {
  final outDir = await Directory.systemTemp.createTemp(
    'ball_rt_${packageName}_${suffix}_',
  );

  // Write a minimal pubspec.yaml.
  final pubspecFile = File('${outDir.path}/pubspec.yaml');
  await pubspecFile.writeAsString(
    'name: $packageName\n'
    'environment:\n'
    '  sdk: ^3.9.0\n',
  );

  // Write each compiled module.
  for (final MapEntry(key: moduleName, value: source) in modules.entries) {
    if (moduleName == 'std' ||
        moduleName == 'dart_std' ||
        moduleName == '__assets__') {
      continue;
    }
    final relPath = PackageEncoder.moduleNameToFilePath(moduleName);
    final outFile = File('${outDir.path}/$relPath');
    await outFile.parent.create(recursive: true);
    await outFile.writeAsString(source);
  }

  return outDir;
}

/// Run `dart analyze` on a directory and parse the results.
Future<_AnalysisResult> _runAnalyze(Directory dir) async {
  final result = await Process.run(
    'dart',
    ['analyze', dir.path],
    workingDirectory: dir.path,
  );

  final output = '${result.stdout}\n${result.stderr}'.trim();
  var errors = 0;
  var warnings = 0;
  var infos = 0;
  final errorLines = <String>[];

  for (final line in output.split('\n')) {
    final lower = line.toLowerCase();
    if (lower.contains('error -') || lower.contains('error •')) {
      errors++;
      errorLines.add(line.trim());
    } else if (lower.contains('warning -') || lower.contains('warning •')) {
      warnings++;
    } else if (lower.contains('info -') || lower.contains('info •')) {
      infos++;
    }
  }

  return _AnalysisResult(
    errors: errors,
    warnings: warnings,
    infos: infos,
    exitCode: result.exitCode,
    rawOutput: output,
    errorLines: errorLines,
  );
}

void _printAnalysis(String label, _AnalysisResult a) {
  stdout.writeln('  $label:');
  stdout.writeln('    Errors:   ${a.errors}');
  stdout.writeln('    Warnings: ${a.warnings}');
  stdout.writeln('    Infos:    ${a.infos}');
  stdout.writeln('    Exit code: ${a.exitCode}');
}

String _delta(int n) => n >= 0 ? '+$n' : '$n';

class _AnalysisResult {
  final int errors;
  final int warnings;
  final int infos;
  final int exitCode;
  final String rawOutput;
  final List<String> errorLines;

  _AnalysisResult({
    required this.errors,
    required this.warnings,
    required this.infos,
    required this.exitCode,
    required this.rawOutput,
    required this.errorLines,
  });
}
