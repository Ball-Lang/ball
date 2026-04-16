/// Round-trip validation: download a pub package, encode to Ball, compile back
/// to Dart, write to a proper package directory, and run `dart analyze`.
///
///   dart run ball_encoder:validate_roundtrip <package_name> [version_constraint]
///
/// Example:
///   dart run ball_encoder:validate_roundtrip path
///   dart run ball_encoder:validate_roundtrip logging any
library;

import 'dart:io';

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run ball_encoder:validate_roundtrip <package_name> '
      '[version_constraint]',
    );
    exit(1);
  }

  final packageName = args[0];
  final constraint = args.length > 1 ? args[1] : 'any';
  final client = PubClient();

  try {
    // 1. Resolve and download the package.
    stdout.writeln('Resolving $packageName ($constraint)...');
    final vi = await client.resolveVersion(packageName, constraint);
    stdout.writeln('Downloading $packageName v${vi.version}...');
    final pkgDir = await client.downloadPackage(
      packageName,
      vi.version,
      archiveUrl: vi.archiveUrl,
    );

    try {
      // 2. Encode to Ball.
      stdout.writeln('Encoding to Ball...');
      final encoder = PackageEncoder(pkgDir);
      final program = encoder.encode();
      stdout.writeln(
        'Encoded ${program.modules.length} modules '
        '(${program.modules.where((m) => m.functions.isNotEmpty).length} with functions)',
      );

      // 3. Compile all modules back to Dart.
      stdout.writeln('Compiling back to Dart...');
      final compiler = DartCompiler(program, noFormat: true);
      final modules = compiler.compileAllModules();
      stdout.writeln('Compiled ${modules.length} modules');

      // 4. Write to a temp directory with proper package structure.
      final outDir = await Directory.systemTemp.createTemp('ball_roundtrip_');
      stdout.writeln('Writing to ${outDir.path}...');

      // Write pubspec.yaml.
      final pubspecFile = File('${outDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString(
        'name: $packageName\n'
        'environment:\n'
        '  sdk: ^3.9.0\n',
      );

      // Write each compiled module to its file path.
      var writtenCount = 0;
      for (final MapEntry(key: moduleName, value: source) in modules.entries) {
        // Skip special modules that don't map to files.
        if (moduleName == 'std' ||
            moduleName == 'dart_std' ||
            moduleName == '__assets__') {
          continue;
        }

        final relPath = PackageEncoder.moduleNameToFilePath(moduleName);
        final outFile = File('${outDir.path}/$relPath');
        await outFile.parent.create(recursive: true);
        await outFile.writeAsString(source);
        writtenCount++;
      }
      stdout.writeln('Wrote $writtenCount files');

      // 5. Run `dart analyze`.
      stdout.writeln('Running dart analyze...');
      final result = await Process.run(
        'dart',
        ['analyze', outDir.path],
        workingDirectory: outDir.path,
      );

      // Parse output.
      final output = '${result.stdout}\n${result.stderr}'.trim();
      var errors = 0;
      var warnings = 0;
      var infos = 0;

      for (final line in output.split('\n')) {
        final lower = line.toLowerCase();
        if (lower.contains('error -') || lower.contains('error •')) {
          errors++;
        } else if (lower.contains('warning -') || lower.contains('warning •')) {
          warnings++;
        } else if (lower.contains('info -') || lower.contains('info •')) {
          infos++;
        }
      }

      // Print the raw analyzer output.
      if (output.isNotEmpty) {
        stdout.writeln();
        stdout.writeln(output);
      }

      // Summary.
      stdout.writeln();
      stdout.writeln('=' * 55);
      stdout.writeln('Package:  $packageName v${vi.version}');
      stdout.writeln('Modules:  ${program.modules.length} encoded, '
          '${modules.length} compiled, $writtenCount written');
      stdout.writeln('Analysis: $errors errors, $warnings warnings, $infos infos');
      stdout.writeln('Exit code: ${result.exitCode}');
      stdout.writeln('Output dir: ${outDir.path}');
      stdout.writeln('=' * 55);

      exit(result.exitCode);
    } finally {
      // Clean up downloaded package.
      try {
        await pkgDir.delete(recursive: true);
      } catch (_) {}
    }
  } catch (e, st) {
    stderr.writeln('Error: $e');
    stderr.writeln(st);
    exit(2);
  } finally {
    client.close();
  }
}
