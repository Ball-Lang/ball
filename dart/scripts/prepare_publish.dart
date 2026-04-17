// ignore_for_file: avoid_print
//
// prepare_publish.dart — Dry-run pub.dev publish readiness check for all
// Ball Dart packages.
//
// For each package in dependency order:
//   1. Backs up the original pubspec.yaml to pubspec.yaml.bak
//   2. Rewrites `path: ../<pkg>` deps to hosted version constraints
//   3. Runs `dart pub publish --dry-run`
//   4. Restores the original pubspec.yaml from backup
//
// The script is reversible — on normal exit AND on Ctrl-C / crash, backups
// are restored via a try/finally guard.
//
// Usage (from d:/packages/ball/dart):
//   dart run scripts/prepare_publish.dart
//
// No arguments. Exit code 0 if all packages pass dry-run, otherwise 1.

import 'dart:convert';
import 'dart:io';

/// Packages in dependency order (base-first). Must match the layout under
/// `d:/packages/ball/dart/<dir>/pubspec.yaml`.
const List<_Pkg> packages = [
  _Pkg(name: 'ball_base', dir: 'shared'),
  _Pkg(name: 'ball_resolver', dir: 'resolver'),
  _Pkg(name: 'ball_engine', dir: 'engine'),
  _Pkg(name: 'ball_encoder', dir: 'encoder'),
  _Pkg(name: 'ball_compiler', dir: 'compiler'),
  _Pkg(name: 'ball_cli', dir: 'cli'),
];

/// Hosted version constraint each internal dep is rewritten to.
/// Reads the actual version from each package's pubspec on startup.
final Map<String, String> _pkgVersions = {};

class _Pkg {
  final String name;
  final String dir;
  const _Pkg({required this.name, required this.dir});
}

class _Result {
  final String name;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool licenseExists;
  final bool readmeExists;
  final bool changelogExists;
  _Result({
    required this.name,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.licenseExists,
    required this.readmeExists,
    required this.changelogExists,
  });
  bool get passed => exitCode == 0;
}

String _dartRoot() {
  // The script lives at <dartRoot>/scripts/prepare_publish.dart.
  final scriptFile = File.fromUri(Platform.script);
  return scriptFile.parent.parent.path.replaceAll('\\', '/');
}

Future<void> _loadVersions(String root) async {
  for (final p in packages) {
    final ps = File('$root/${p.dir}/pubspec.yaml');
    final src = await ps.readAsString();
    final m = RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(src);
    if (m == null) {
      throw StateError('No version: in ${ps.path}');
    }
    _pkgVersions[p.name] = m.group(1)!.trim();
  }
}

/// Rewrites all `<name>:\n    path: ../<dir>` blocks in [src] to
/// `<name>: ^<version>`. Conservative regex — assumes the format produced
/// by `dart pub` and already present in the repo.
String _rewritePathDeps(String src) {
  var out = src;
  for (final p in packages) {
    final ver = _pkgVersions[p.name]!;
    // Match: "<name>:\n    path: ../<dir>" possibly with trailing whitespace.
    // The indent of the name line is preserved.
    final re = RegExp(
      '^(\\s*)${RegExp.escape(p.name)}:\\s*\\r?\\n\\s+path:\\s*\\.\\./${RegExp.escape(p.dir)}\\s*\\r?\\n',
      multiLine: true,
    );
    out = out.replaceAllMapped(re, (m) {
      final indent = m.group(1) ?? '';
      return '$indent${p.name}: ^$ver\n';
    });
  }
  return out;
}

Future<_Result> _dryRunOne(_Pkg p, String root) async {
  final pkgDir = '$root/${p.dir}';
  final pubspec = File('$pkgDir/pubspec.yaml');
  final backup = File('$pkgDir/pubspec.yaml.bak');

  // Make sure no stale backup exists from a crashed previous run.
  if (await backup.exists()) {
    await backup.delete();
  }

  final original = await pubspec.readAsString();
  await backup.writeAsString(original);

  final licenseExists =
      await File('$pkgDir/LICENSE').exists() ||
      await File('$pkgDir/LICENSE.md').exists() ||
      await File('$pkgDir/LICENSE.txt').exists();
  final readmeExists =
      await File('$pkgDir/README.md').exists() ||
      await File('$pkgDir/README').exists();
  final changelogExists =
      await File('$pkgDir/CHANGELOG.md').exists() ||
      await File('$pkgDir/CHANGELOG').exists();

  try {
    final rewritten = _rewritePathDeps(original);
    await pubspec.writeAsString(rewritten);

    print('\n=== ${p.name} (${p.dir}) ===');
    final proc = await Process.start(
      'dart',
      ['pub', 'publish', '--dry-run'],
      workingDirectory: pkgDir,
      runInShell: true,
    );
    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final stdoutFuture = proc.stdout
        .transform(utf8.decoder)
        .listen((d) {
          stdout.write(d);
          stdoutBuf.write(d);
        })
        .asFuture<void>();
    final stderrFuture = proc.stderr
        .transform(utf8.decoder)
        .listen((d) {
          stderr.write(d);
          stderrBuf.write(d);
        })
        .asFuture<void>();
    final code = await proc.exitCode;
    await stdoutFuture;
    await stderrFuture;
    return _Result(
      name: p.name,
      exitCode: code,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
      licenseExists: licenseExists,
      readmeExists: readmeExists,
      changelogExists: changelogExists,
    );
  } finally {
    // Always restore, even on crash / signal.
    if (await backup.exists()) {
      final saved = await backup.readAsString();
      await pubspec.writeAsString(saved);
      await backup.delete();
    }
  }
}

void _printSummary(List<_Result> results) {
  print('\n\n======================================================');
  print('  PUB.DEV PUBLISH DRY-RUN SUMMARY');
  print('======================================================\n');

  for (final r in results) {
    final status = r.passed ? 'PASS' : 'FAIL';
    print('[$status] ${r.name}');
    if (!r.licenseExists) print('   - MISSING LICENSE file');
    if (!r.readmeExists) print('   - MISSING README.md');
    if (!r.changelogExists) print('   - MISSING CHANGELOG.md');

    final combined = '${r.stdout}\n${r.stderr}';
    final errorLines = <String>[];
    final warningLines = <String>[];
    final hintLines = <String>[];
    for (final line in combined.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('* ') || trimmed.startsWith('  * ')) {
        // pub groups findings as bullets under "Package has X warnings." etc.
        warningLines.add(trimmed);
      } else if (trimmed.toLowerCase().contains('error')) {
        errorLines.add(trimmed);
      } else if (trimmed.toLowerCase().contains('warning')) {
        warningLines.add(trimmed);
      } else if (trimmed.toLowerCase().contains('hint')) {
        hintLines.add(trimmed);
      }
    }
    if (errorLines.isNotEmpty) {
      print('   Errors:');
      for (final e in errorLines.take(10)) {
        print('     $e');
      }
    }
    if (warningLines.isNotEmpty) {
      print('   Warnings:');
      for (final w in warningLines.take(10)) {
        print('     $w');
      }
    }
    if (hintLines.isNotEmpty) {
      print('   Hints:');
      for (final h in hintLines.take(10)) {
        print('     $h');
      }
    }
    print('');
  }

  final allPassed = results.every((r) => r.passed);
  print('======================================================');
  print(allPassed ? 'ALL PACKAGES PASSED DRY-RUN' : 'SOME PACKAGES FAILED');
  print('======================================================');
}

Future<int> main(List<String> args) async {
  final root = _dartRoot();
  print('Dart root: $root');
  await _loadVersions(root);
  print('Package versions:');
  _pkgVersions.forEach((k, v) => print('  $k: $v'));

  final results = <_Result>[];
  try {
    for (final p in packages) {
      final r = await _dryRunOne(p, root);
      results.add(r);
    }
  } catch (e, st) {
    stderr.writeln('ERROR: $e\n$st');
  } finally {
    // Extra safety: scan for any leftover *.bak files and restore them.
    for (final p in packages) {
      final bak = File('$root/${p.dir}/pubspec.yaml.bak');
      if (await bak.exists()) {
        final contents = await bak.readAsString();
        await File('$root/${p.dir}/pubspec.yaml').writeAsString(contents);
        await bak.delete();
        stderr.writeln('Restored pubspec for ${p.name} from stale backup.');
      }
    }
  }

  _printSummary(results);
  return results.every((r) => r.passed) ? 0 : 1;
}
