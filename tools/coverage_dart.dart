/// Dart line-coverage ratchet for the correctness-critical packages.
///
/// Runs each package's test suite with coverage, aggregates the lcov reports
/// (EXCLUDING generated/never-authored files), reports overall line coverage,
/// and — when given `--floor <pct>` — fails if coverage dropped below the floor.
/// The bar is 100%; the floor is raised one PR at a time and must never regress.
///
///   dart run tools/coverage_dart.dart                 # report only
///   dart run tools/coverage_dart.dart --floor 85.0    # gate (CI)
///
/// Generated files are excluded because they are regenerated, not authored
/// (see CLAUDE.md "Never edit generated files").
library;

import 'dart:io';

/// Packages whose authored code must be covered. CLI/glue and roadmap packages
/// can be added as their suites mature.
const _packages = <String>['shared', 'engine', 'encoder', 'compiler'];

/// Path fragments that mark a generated/never-authored file (excluded from %).
const _excludedFragments = <String>[
  '/gen/', // protobuf-generated types
  '/lib/gen/',
  'compiled_engine.ts',
  'engine_rt.cpp',
  'engine_roundtrip.dart',
  '.g.dart', // build_runner output, if any
];

bool _isExcluded(String path) {
  final p = path.replaceAll('\\', '/');
  return _excludedFragments.any(p.contains);
}

Future<void> main(List<String> args) async {
  final floorIdx = args.indexOf('--floor');
  final double? floor = floorIdx >= 0 && floorIdx + 1 < args.length
      ? double.tryParse(args[floorIdx + 1])
      : null;

  final repoRoot = _findRepoRoot();
  final covDir = Directory('$repoRoot/coverage')..createSync(recursive: true);

  var totalFound = 0;
  var totalHit = 0;
  final perPackage = <String, ({int found, int hit})>{};

  for (final pkg in _packages) {
    final pkgDir = Directory('$repoRoot/dart/$pkg');
    if (!pkgDir.existsSync()) {
      stderr.writeln('  skip $pkg (no package dir)');
      continue;
    }
    final lcovPath = '${covDir.path}/$pkg.lcov';
    stdout.writeln('Running $pkg tests with coverage...');
    // Exclude `slow`-tagged tests, matching what ci.yml actually gates (the
    // compiler's conformance_roundtrip_test is `slow` and carries known-failing
    // legs for not-yet-complete compiler features — tracked separately). The
    // ratchet must measure the SAME suite CI gates, or it fails on bugs the
    // gated build never sees.
    final result = await Process.run('dart', [
      'test',
      '--coverage-path=$lcovPath',
      '--branch-coverage',
      '--exclude-tags',
      'slow',
    ], workingDirectory: pkgDir.path);
    if (result.exitCode != 0) {
      stderr.writeln('  $pkg tests FAILED (exit ${result.exitCode}):');
      stderr.writeln(result.stdout);
      stderr.writeln(result.stderr);
      exit(1);
    }
    final lcov = File(lcovPath);
    if (!lcov.existsSync()) {
      stderr.writeln('  $pkg produced no lcov at $lcovPath');
      continue;
    }
    final (found, hit) = _parseLcov(lcov.readAsLinesSync());
    perPackage[pkg] = (found: found, hit: hit);
    totalFound += found;
    totalHit += hit;
  }

  String pct(int hit, int found) =>
      found == 0 ? 'n/a' : '${(100.0 * hit / found).toStringAsFixed(2)}%';

  stdout.writeln('');
  stdout.writeln('Dart line coverage (generated files excluded):');
  for (final pkg in _packages) {
    final p = perPackage[pkg];
    if (p == null) continue;
    stdout.writeln(
      '  ${pkg.padRight(10)} ${pct(p.hit, p.found).padLeft(8)}  '
      '(${p.hit}/${p.found})',
    );
  }
  final overall = totalFound == 0 ? 0.0 : 100.0 * totalHit / totalFound;
  stdout.writeln(
    '  ${'TOTAL'.padRight(10)} '
    '${pct(totalHit, totalFound).padLeft(8)}  ($totalHit/$totalFound)',
  );

  if (floor != null) {
    if (overall + 1e-9 < floor) {
      stderr.writeln('');
      stderr.writeln(
        'ERROR: line coverage ${overall.toStringAsFixed(2)}% is below the '
        'floor of ${floor.toStringAsFixed(2)}%. Add tests (target: 100%) or, '
        'only with justification, lower the floor in CI.',
      );
      exit(1);
    }
    stdout.writeln('');
    stdout.writeln(
      'OK: ${overall.toStringAsFixed(2)}% ≥ floor ${floor.toStringAsFixed(2)}%.',
    );
  }
}

/// Sum LF (lines found) / LH (lines hit) across all non-excluded SF records.
(int, int) _parseLcov(List<String> lines) {
  var found = 0;
  var hit = 0;
  var excluded = false;
  for (final line in lines) {
    if (line.startsWith('SF:')) {
      excluded = _isExcluded(line.substring(3));
    } else if (!excluded && line.startsWith('LF:')) {
      found += int.tryParse(line.substring(3)) ?? 0;
    } else if (!excluded && line.startsWith('LH:')) {
      hit += int.tryParse(line.substring(3)) ?? 0;
    }
  }
  return (found, hit);
}

String _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path.replaceAll('\\', '/');
    }
    dir = dir.parent;
  }
  throw StateError('Cannot find repo root from ${Directory.current.path}');
}
