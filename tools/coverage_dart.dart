/// Dart line-coverage measurement + ratchet for the WHOLE workspace.
///
/// Best-practice completeness on two axes:
///   1. EVERY package — `dart/*/pubspec.yaml` discovered dynamically, so a new
///      package can never silently drop out of coverage (the bug this script
///      used to have: a hand-maintained 4-package allowlist).
///   2. EVERY authored file, credited by EVERY test that exercises it — each
///      package's `dart test --coverage` already reports the workspace
///      path-deps it loads (e.g. the engine suite exercises `shared`), so a
///      file's coverage is max-merged across all suites, not just its own
///      package's. Files no test ever loads are emitted at 0% (never dropped —
///      omitting untested files is what makes a coverage number lie).
///
/// Generated/never-authored files are excluded (CLAUDE.md "Never edit generated
/// files"). The bar is 100%; the floor is raised one PR at a time and must
/// never regress.
///
///   dart run tools/coverage_dart.dart                 # report only
///   dart run tools/coverage_dart.dart --floor 60.0    # gate (CI)
///
/// Writes a single merged `coverage/dart.lcov` (repo-relative paths, every
/// file) for the Codecov upload.
library;

import 'dart:io';

/// Path fragments that mark a generated/never-authored OR not-product file
/// (excluded from the coverage %).
const _excludedFragments = <String>[
  '/gen/', // protobuf-generated types (dart/*/lib/gen/**, *.pb.dart live here)
  '.pb.dart',
  '.pbenum.dart',
  '.pbjson.dart',
  '.pbserver.dart',
  '.g.dart', // build_runner output
  'engine_roundtrip.dart', // dart/self_host (generated, gitignored)
  'compiled_engine.ts',
  'engine_rt.cpp',
  // dart/*/bin/** — CLI / codegen / CI-gate / protoc-plugin ENTRY POINTS:
  // thin `main()` glue over argv + stdin/stdout + exit(), whose product logic
  // lives in `lib/` (which IS measured here). Entry-point I/O wrappers are
  // validated by integration/CI execution, not unit coverage — measuring them
  // would penalise the product number for untestable process plumbing. The
  // shipped CLI surface is covered in-process via `cli/lib/src/runner.dart`.
  '/bin/',
];

bool _isExcluded(String path) {
  final p = path.replaceAll('\\', '/');
  return _excludedFragments.any(p.contains);
}

String _norm(String path) => path.replaceAll('\\', '/');

void main(List<String> args) async {
  final floorIdx = args.indexOf('--floor');
  final double? floor = floorIdx >= 0 && floorIdx + 1 < args.length
      ? double.tryParse(args[floorIdx + 1])
      : null;

  final repoRoot = _norm(_findRepoRoot());
  final dartPrefix = '$repoRoot/dart/';
  final dartDir = Directory('$repoRoot/dart');
  final covDir = Directory('$repoRoot/coverage')..createSync(recursive: true);

  // Discover EVERY package (dart/*/pubspec.yaml). No hand-maintained allowlist.
  final packages =
      dartDir
          .listSync()
          .whereType<Directory>()
          .where((d) => File('${d.path}/pubspec.yaml').existsSync())
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  // The single source of truth: repo-relative file -> {line -> max hits across
  // ALL suites}. Per-package and total are both derived from this at the end.
  final repoLines = <String, Map<int, int>>{};
  // Packages whose suite didn't fully pass — coverage is still measured (so the
  // folder isn't dropped) but UNDER-counted, and surfaced loudly. This tool
  // MEASURES coverage; the test gate is ci.yml's own test steps.
  final failedPackages = <String>[];

  String? toRepoRel(String absPath) {
    final p = _norm(absPath);
    if (!p.startsWith(dartPrefix)) return null; // skip pub-cache/external deps
    return p.substring(repoRoot.length + 1); // -> dart/<pkg>/...
  }

  void fold(String repoRelFile, Map<int, int> lines) {
    if (_isExcluded(repoRelFile)) return;
    final dst = repoLines.putIfAbsent(repoRelFile, () => <int, int>{});
    for (final e in lines.entries) {
      final cur = dst[e.key] ?? 0;
      // ALWAYS store (max) — including 0-hit lines, or untested lines vanish and
      // the percentage lies high.
      dst[e.key] = e.value > cur ? e.value : cur;
    }
  }

  for (final pkgDir in packages) {
    final name = pkgDir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

    // Authored source files under lib/ + bin/ (generated excluded).
    final sources = <String>[];
    for (final sub in const ['lib', 'bin']) {
      final d = Directory('${pkgDir.path}/$sub');
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (f.path.endsWith('.dart') && !_isExcluded(f.path)) {
          final rel = toRepoRel(f.absolute.path);
          if (rel != null) sources.add(rel);
        }
      }
    }
    if (sources.isEmpty) continue; // e.g. self_host: only generated engine_rt.

    final testDir = Directory('${pkgDir.path}/test');
    final hasTests =
        testDir.existsSync() &&
        testDir
            .listSync(recursive: true)
            .whereType<File>()
            .any((f) => f.path.endsWith('_test.dart'));

    if (hasTests) {
      final lcovPath = '${covDir.path}/$name.lcov';
      stdout.writeln('Running $name tests with coverage...');
      // `--exclude-tags slow` mirrors what ci.yml gates (the compiler's slow
      // round-trip carries known-failing legs for not-yet-complete features).
      // Capture stdout/stderr as RAW BYTES (encoding: null), never UTF-8. A
      // suite may legitimately print binary to stdout (e.g. the cli's
      // `encode --format binary` path), and decoding that as UTF-8 throws
      // `FormatException: Missing extension byte`, crashing the whole coverage
      // run. We only need the exit code + the lcov file written to disk.
      final result = await Process.run(
        'dart',
        [
          'test',
          '--coverage-path=$lcovPath',
          '--branch-coverage',
          '--exclude-tags',
          'slow',
        ],
        workingDirectory: pkgDir.path,
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (result.exitCode != 0) {
        failedPackages.add(name);
        stderr.writeln(
          '  WARNING: $name tests did not fully pass (exit '
          '${result.exitCode}) — coverage may be under-counted. The test gate '
          'is ci.yml; fix the suite there.',
        );
      }
      final lcov = File(lcovPath);
      if (lcov.existsSync()) {
        final parsed = <String, Map<int, int>>{};
        _parseLcovInto(lcov.readAsLinesSync(), parsed);
        // Fold EVERY workspace file this suite reported (incl. path-deps like
        // shared) so cross-package coverage is credited.
        for (final e in parsed.entries) {
          final rel = toRepoRel(e.key);
          if (rel != null) fold(rel, e.value);
        }
      }
    } else {
      stdout.writeln('Package $name has no tests.');
    }

    // Completeness: every authored source MUST appear, even if no suite loaded
    // it (→ 0%, never silently dropped). putIfAbsent so real coverage wins.
    for (final src in sources) {
      repoLines.putIfAbsent(src, () => _zeroLineMap(File('$repoRoot/$src')));
    }
  }

  // Derive per-package + total from the merged map, and write the lcov.
  final perPackage = <String, ({int found, int hit})>{};
  final mergedLcov = StringBuffer();
  var totalFound = 0, totalHit = 0;
  for (final file in repoLines.keys.toList()..sort()) {
    final raw = repoLines[file]!;
    if (raw.isEmpty) continue;
    // Honor `// coverage:ignore-*` markers — truly-untestable code (unreachable
    // defensive throws, pure-IO dev/CI tool entry points) is excluded from the
    // %, the same standard `package:coverage` supports. `{-1}` ⇒ whole file.
    final ignored = _ignoredLines(File('$repoRoot/$file'));
    if (ignored.contains(-1)) continue; // // coverage:ignore-file
    final lines = ignored.isEmpty
        ? raw
        : {
            for (final e in raw.entries)
              if (!ignored.contains(e.key)) e.key: e.value,
          };
    if (lines.isEmpty) continue;
    final f = lines.length;
    final h = lines.values.where((v) => v > 0).length;
    totalFound += f;
    totalHit += h;
    // dart/<pkg>/...
    final parts = file.split('/');
    final pkg = parts.length > 1 ? parts[1] : file;
    final cur = perPackage[pkg] ?? (found: 0, hit: 0);
    perPackage[pkg] = (found: cur.found + f, hit: cur.hit + h);

    mergedLcov.writeln('SF:$file');
    for (final ln in lines.keys.toList()..sort()) {
      mergedLcov.writeln('DA:$ln,${lines[ln]}');
    }
    mergedLcov.writeln('LF:$f');
    mergedLcov.writeln('LH:$h');
    mergedLcov.writeln('end_of_record');
  }
  File('${covDir.path}/dart.lcov').writeAsStringSync(mergedLcov.toString());

  String pct(int hit, int found) =>
      found == 0 ? 'n/a' : '${(100.0 * hit / found).toStringAsFixed(2)}%';

  stdout.writeln('');
  stdout.writeln('Dart line coverage — ALL packages, ALL authored files:');
  for (final pkg in perPackage.keys.toList()..sort()) {
    final p = perPackage[pkg]!;
    stdout.writeln(
      '  ${pkg.padRight(18)} ${pct(p.hit, p.found).padLeft(8)}  '
      '(${p.hit}/${p.found})',
    );
  }
  final overall = totalFound == 0 ? 0.0 : 100.0 * totalHit / totalFound;
  stdout.writeln(
    '  ${'TOTAL'.padRight(18)} '
    '${pct(totalHit, totalFound).padLeft(8)}  ($totalHit/$totalFound)',
  );

  if (failedPackages.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln(
      'WARNING: ${failedPackages.length} package suite(s) failed/incomplete '
      '(coverage may be under-counted): ${failedPackages.join(', ')}. '
      'These need fixing / ci.yml gating.',
    );
  }

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

/// Parse lcov `SF`/`DA` records into [out] (file -> {line -> hits}), skipping
/// excluded (generated) files. Multiple records for one file are max-merged.
void _parseLcovInto(List<String> lines, Map<String, Map<int, int>> out) {
  String? current;
  var skip = false;
  for (final line in lines) {
    if (line.startsWith('SF:')) {
      current = _norm(line.substring(3));
      skip = _isExcluded(current);
      if (!skip) out.putIfAbsent(current, () => <int, int>{});
    } else if (!skip && current != null && line.startsWith('DA:')) {
      final body = line.substring(3);
      final comma = body.indexOf(',');
      if (comma < 0) continue;
      final ln = int.tryParse(body.substring(0, comma));
      final hits = int.tryParse(body.substring(comma + 1));
      if (ln == null || hits == null) continue;
      final m = out[current]!;
      final cur = m[ln] ?? 0;
      m[ln] = hits > cur ? hits : cur;
    } else if (line == 'end_of_record') {
      current = null;
      skip = false;
    }
  }
}

/// For a file no test loaded, build a {line -> 0} map over its executable-ish
/// lines (non-blank, not a pure comment/brace/annotation). A conservative proxy
/// of "lines of code": it treats the whole file as uncovered (honest); the exact
/// instrumentable-line count only matters once the file gets real tests (then
/// dart's own lcov replaces this proxy via the max-merge).
Map<int, int> _zeroLineMap(File f) {
  final out = <int, int>{};
  List<String> lines;
  try {
    lines = f.readAsLinesSync();
  } catch (_) {
    return out;
  }
  final punct = RegExp(r'^[{}()\[\];,]+$');
  var inBlockComment = false;
  for (var i = 0; i < lines.length; i++) {
    var t = lines[i].trim();
    if (inBlockComment) {
      final end = t.indexOf('*/');
      if (end < 0) continue;
      t = t.substring(end + 2).trim();
      inBlockComment = false;
    }
    final blockStart = t.indexOf('/*');
    if (blockStart >= 0 && !t.contains('*/', blockStart)) {
      t = t.substring(0, blockStart).trim();
      inBlockComment = true;
    }
    if (t.isEmpty) continue;
    if (t.startsWith('//')) continue; // line + doc comments
    if (t.startsWith('*') || t.startsWith('@'))
      continue; // doc cont. / annotation
    if (punct.hasMatch(t)) continue; // pure structural punctuation
    if (t == 'else' || t == 'try' || t == 'do') continue;
    // Directives aren't instrumentable — a barrel file of pure `export`s has no
    // executable lines (dart wouldn't count them), so it must not look like
    // uncovered code.
    if (t.startsWith('export ') ||
        t.startsWith('import ') ||
        t.startsWith('part ') ||
        t.startsWith('part of') ||
        t.startsWith('library ') ||
        t == 'library;') {
      continue;
    }
    out[i + 1] = 0;
  }
  return out;
}

/// 1-based line numbers carrying a `// coverage:ignore-*` marker (the standard
/// `package:coverage` syntax), excluded from the coverage %. Returns `{-1}` for
/// `// coverage:ignore-file` (exclude the whole file). Use ONLY for genuinely
/// untestable code: unreachable defensive `throw`s, or pure-IO dev/CI tool
/// entry points — never to paper over missing tests.
Set<int> _ignoredLines(File f) {
  final out = <int>{};
  List<String> lines;
  try {
    lines = f.readAsLinesSync();
  } catch (_) {
    return out;
  }
  var inBlock = false;
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].toLowerCase();
    if (t.contains('// coverage:ignore-file')) return {-1};
    if (t.contains('// coverage:ignore-start')) {
      inBlock = true;
      out.add(i + 1);
      continue;
    }
    if (t.contains('// coverage:ignore-end')) {
      inBlock = false;
      out.add(i + 1);
      continue;
    }
    if (inBlock || t.contains('// coverage:ignore-line')) out.add(i + 1);
  }
  return out;
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
