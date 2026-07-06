/// Generates the std base-function coverage inventory FROM the canonical
/// source of truth — the `buildStd*Module()` builders in `package:ball_base`
/// (the same builders `dart/shared/bin/gen_std.dart` calls to produce
/// `std.json`) — instead of any hand-maintained matrix.
///
/// Replaces the hand-kept `docs/STD_COMPLETENESS.md` (issue #135). For every
/// base function across all 8 universal std modules (`std`,
/// `std_collections`, `std_io`, `std_memory`, `std_convert`, `std_fs`,
/// `std_time`, `std_concurrency`) it answers three questions:
///
///   1. **encoder-emittable?**  Can the Dart encoder (`dart/encoder/lib/
///      encoder.dart`) produce a call to this base function from some Dart
///      source? Extends `check_encoder_completeness.dart`'s literal-scan
///      technique (the same file is the "emittable" oracle for that CI gate)
///      with additional emit-site shapes (route-table map/tuple literals,
///      `addAll([...])` bulk adds) so more of the encoder's real emit
///      surface is captured. Over-matching is harmless here — the result is
///      only ever consulted by canonical function name.
///   2. **covered-by-fixture?** Which `tests/conformance/*.ball.json` fixture
///      IDs declare this function `isBase`? Reads the *committed* fixtures
///      directly (not a live re-encode), so it also credits hand-authored
///      fixtures that the Dart encoder cannot itself produce (e.g.
///      `188_std_time_now`, `256_editions_resolver` — see
///      `tests/conformance/CARVEOUTS.md`). Matches by function name only,
///      mirroring `check_encoder_completeness.dart`'s own flattening across
///      `program.modules`.
///   3. **engine-implemented (Dart)?** Does `dart/engine/lib/*.dart` (the
///      reference engine) dispatch on this function name? Dart is the
///      reference implementation the TS/C++ self-hosted engines are
///      generated from (`docs/TESTING_STRATEGY.md` §5), so this is scoped to
///      the Dart engine's dispatch tables, not TS/C++.
///
/// Outputs (both generated — never hand-edit):
///   tests/conformance/std_coverage.json — machine-readable inventory
///   tests/conformance/STD_COVERAGE.md   — rendered table + gap summary
///
/// Run from `dart/encoder`:
///   dart run bin/gen_std_coverage.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart' as base;

/// One row of the inventory: a single (module, function) pair.
class _FnEntry {
  _FnEntry(this.module, this.name, this.inputType, this.outputType);

  final String module;
  final String name;
  final String inputType;
  final String outputType;
  bool encoderEmittable = false;
  bool engineImplementedDart = false;
  bool carvedOut = false;
  final Set<String> fixtures = <String>{};

  Map<String, Object?> toJson() => {
    'module': module,
    'name': name,
    if (inputType.isNotEmpty) 'inputType': inputType,
    if (outputType.isNotEmpty) 'outputType': outputType,
    'encoderEmittable': encoderEmittable,
    'coveredByFixtures': fixtures.toList()..sort(),
    'engineImplementedDart': engineImplementedDart,
    'carvedOut': carvedOut,
  };
}

void main() {
  final repoRoot = _findRepoRoot();

  // ── 1. Canonical function list: call the SAME builders gen_std.dart uses,
  // so there is zero risk of drifting from std.json / the runtime modules.
  final canonicalModules = <base.Module>[
    base.buildStdModule(),
    base.buildStdCollectionsModule(),
    base.buildStdIoModule(),
    base.buildStdMemoryModule(),
    base.buildStdConvertModule(),
    base.buildStdFsModule(),
    base.buildStdTimeModule(),
    base.buildStdConcurrencyModule(),
  ];

  final entries = <_FnEntry>[];
  for (final module in canonicalModules) {
    for (final fn in module.functions) {
      if (!fn.isBase) continue;
      entries.add(_FnEntry(module.name, fn.name, fn.inputType, fn.outputType));
    }
  }
  entries.sort(
    (a, b) => a.module == b.module
        ? a.name.compareTo(b.name)
        : a.module.compareTo(b.module),
  );

  // ── 2. Encoder-emittable: harvest candidate names from every emit-site
  // shape in encoder.dart, then test membership by canonical name.
  final encoderSrc = File(
    '$repoRoot/dart/encoder/lib/encoder.dart',
  ).readAsStringSync();
  final emittable = _harvestEmittable(encoderSrc);

  // ── 3. Fixture coverage: read every COMMITTED conformance fixture
  // directly (not a live re-encode) so hand-authored fixtures count too.
  final confDir = Directory('$repoRoot/tests/conformance');
  final fixtureCoverage = <String, Set<String>>{}; // fn name -> fixture ids
  final ballFiles =
      confDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.ball.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in ballFiles) {
    final fixtureId = f.uri.pathSegments.last.replaceAll('.ball.json', '');
    Map<String, Object?> program;
    try {
      program = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    } catch (e) {
      stderr.writeln('WARN: failed to parse ${f.path}: $e');
      continue;
    }
    final modules = (program['modules'] as List?) ?? const [];
    for (final m in modules) {
      if (m is! Map) continue;
      final functions = (m['functions'] as List?) ?? const [];
      for (final fn in functions) {
        if (fn is! Map) continue;
        if (fn['isBase'] != true) continue;
        final name = fn['name'] as String?;
        if (name == null) continue;
        (fixtureCoverage[name] ??= <String>{}).add(fixtureId);
      }
    }
  }

  // ── 4. Engine-implemented (Dart reference engine dispatch tables) ──
  final engineDir = Directory('$repoRoot/dart/engine/lib');
  final engineImplemented = <String>{};
  for (final f
      in engineDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
    _harvestEngineDispatch(f.readAsStringSync(), engineImplemented);
  }

  // ── 5. Carve-outs (encoder-completeness escape hatch) ──
  final carveoutsFile = File(
    '$repoRoot/tests/conformance/ENCODER_COMPLETENESS_CARVEOUTS.md',
  );
  final carveouts = <String>{};
  if (carveoutsFile.existsSync()) {
    final re = RegExp(r'^-\s+`([a-z][a-z0-9_]*)`');
    for (final line in carveoutsFile.readAsLinesSync()) {
      final m = re.firstMatch(line.trim());
      if (m != null) carveouts.add(m.group(1)!);
    }
  }

  // ── Assemble ──
  for (final e in entries) {
    e.encoderEmittable = emittable.contains(e.name);
    e.fixtures.addAll(fixtureCoverage[e.name] ?? const <String>{});
    e.engineImplementedDart = engineImplemented.contains(e.name);
    e.carvedOut = carveouts.contains(e.name);
  }

  final uncovered =
      entries
          .where(
            (e) => e.encoderEmittable && e.fixtures.isEmpty && !e.carvedOut,
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  final notEmittable = entries.where((e) => !e.encoderEmittable).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final notEngineImplemented =
      entries.where((e) => !e.engineImplementedDart).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  // ── Write JSON ──
  final byModule = <String, int>{};
  for (final e in entries) {
    byModule[e.module] = (byModule[e.module] ?? 0) + 1;
  }
  final inventory = <String, Object?>{
    'generatedBy': 'dart/encoder/bin/gen_std_coverage.dart',
    'generatedFrom': [
      'package:ball_base buildStdModule()',
      'package:ball_base buildStdCollectionsModule()',
      'package:ball_base buildStdIoModule()',
      'package:ball_base buildStdMemoryModule()',
      'package:ball_base buildStdConvertModule()',
      'package:ball_base buildStdFsModule()',
      'package:ball_base buildStdTimeModule()',
      'package:ball_base buildStdConcurrencyModule()',
    ],
    'totalFunctions': entries.length,
    'functionsByModule': byModule,
    'summary': {
      'encoderEmittable': entries.where((e) => e.encoderEmittable).length,
      'coveredByFixture': entries.where((e) => e.fixtures.isNotEmpty).length,
      'engineImplementedDart': entries
          .where((e) => e.engineImplementedDart)
          .length,
      'carvedOut': entries.where((e) => e.carvedOut).length,
    },
    'functions': entries.map((e) => e.toJson()).toList(),
    'gaps': {
      'notEncoderEmittable': notEmittable.map((e) => e.name).toList(),
      'emittableButUncoveredByFixture': uncovered.map((e) => e.name).toList(),
      'notEngineImplementedDart': notEngineImplemented
          .map((e) => e.name)
          .toList(),
    },
  };
  final jsonOut = File('${confDir.path}/std_coverage.json');
  jsonOut.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(inventory)}\n',
  );

  // ── Write Markdown ──
  final md = StringBuffer();
  md.writeln('<!-- GENERATED FILE — do not hand-edit.');
  md.writeln(
    'Regenerate with: cd dart/encoder && dart run bin/gen_std_coverage.dart',
  );
  md.writeln('Source of truth: dart/shared/std.json + the buildStd*Module()');
  md.writeln('builders in package:ball_base. See issue #135. -->');
  md.writeln();
  md.writeln('# Std Base-Function Coverage Inventory');
  md.writeln();
  md.writeln(
    'Every base function across the 8 universal std modules, generated '
    'directly from the canonical builders (never hand-maintained).',
  );
  md.writeln();
  md.writeln(
    '> Coverage here is *function-name presence* in an executed conformance '
    'fixture, not full behavioral completeness — see '
    '[`docs/TESTING_STRATEGY.md`](../../docs/TESTING_STRATEGY.md) §2. '
    '"Engine-implemented" is scoped to the **Dart** reference engine '
    '(`dart/engine/lib/`); the TS/C++ self-hosted engines are generated from '
    'it (`docs/TESTING_STRATEGY.md` §5).',
  );
  md.writeln();
  md.writeln('## Summary');
  md.writeln();
  md.writeln('| Metric | Count |');
  md.writeln('|---|---|');
  md.writeln('| Total base functions | ${entries.length} |');
  md.writeln(
    '| Encoder-emittable | ${entries.where((e) => e.encoderEmittable).length} |',
  );
  md.writeln(
    '| Covered by a conformance fixture | ${entries.where((e) => e.fixtures.isNotEmpty).length} |',
  );
  md.writeln(
    '| Dart engine-implemented | ${entries.where((e) => e.engineImplementedDart).length} |',
  );
  md.writeln('| Documented carve-outs | ${carveouts.length} |');
  md.writeln();

  for (final module in canonicalModules) {
    final rows = entries.where((e) => e.module == module.name).toList();
    if (rows.isEmpty) continue;
    md.writeln('## `${module.name}` (${rows.length} functions)');
    md.writeln();
    if (module.description.isNotEmpty) {
      md.writeln('${module.description}');
      md.writeln();
    }
    md.writeln(
      '| Function | Encoder-emittable | Covered by fixture | Dart engine |',
    );
    md.writeln('|---|---|---|---|');
    for (final e in rows) {
      final emit = e.encoderEmittable ? '✅' : '❌';
      final String cov;
      if (e.fixtures.isNotEmpty) {
        // Full list lives in std_coverage.json; the table shows a few
        // examples so it stays scannable for functions used everywhere
        // (e.g. `add`, `assign` are in 80+ fixtures).
        final ids = (e.fixtures.toList()..sort());
        const maxShown = 3;
        final shown = ids.take(maxShown).map((id) => '`$id`').join(', ');
        final more = ids.length > maxShown
            ? ' +${ids.length - maxShown} more'
            : '';
        cov = '✅ ${ids.length} fixture(s): $shown$more';
      } else if (e.carvedOut) {
        cov = '⚠️ carve-out';
      } else {
        cov = '❌';
      }
      final eng = e.engineImplementedDart ? '✅' : '❌';
      md.writeln('| `${e.name}` | $emit | $cov | $eng |');
    }
    md.writeln();
  }

  md.writeln('## Gaps');
  md.writeln();
  md.writeln(
    '### Not encoder-emittable (${notEmittable.length}) — no Dart-source '
    'construct routes to this function',
  );
  md.writeln();
  if (notEmittable.isEmpty) {
    md.writeln('_None._');
  } else {
    for (final e in notEmittable) {
      md.writeln('- `${e.module}.${e.name}`');
    }
  }
  md.writeln();
  md.writeln(
    '### Emittable but uncovered by any fixture (${uncovered.length}) — '
    'genuine conformance gaps, not carved out',
  );
  md.writeln();
  if (uncovered.isEmpty) {
    md.writeln('_None._');
  } else {
    for (final e in uncovered) {
      md.writeln('- `${e.module}.${e.name}`');
    }
  }
  md.writeln();
  md.writeln(
    '### Not Dart engine-implemented (${notEngineImplemented.length})',
  );
  md.writeln();
  if (notEngineImplemented.isEmpty) {
    md.writeln('_None._');
  } else {
    for (final e in notEngineImplemented) {
      md.writeln('- `${e.module}.${e.name}`');
    }
  }
  md.writeln();

  File('${confDir.path}/STD_COVERAGE.md').writeAsStringSync(md.toString());

  stdout.writeln(
    'OK: ${entries.length} base functions across ${canonicalModules.length} '
    'modules; ${entries.where((e) => e.encoderEmittable).length} '
    'encoder-emittable, ${entries.where((e) => e.fixtures.isNotEmpty).length} '
    'covered by a fixture, '
    '${entries.where((e) => e.engineImplementedDart).length} Dart '
    'engine-implemented.',
  );
  stdout.writeln('  -> ${jsonOut.path}');
  stdout.writeln('  -> ${confDir.path}/STD_COVERAGE.md');
}

/// Harvest candidate encoder-emittable names from every emit-site shape in
/// `encoder.dart`. Extends `check_encoder_completeness.dart`'s narrower
/// `_usedBaseFunctions.add(...)` / `_buildStdCall(...)` scan with:
///   - the other three tracked sets (`_usedCollectionsFunctions`,
///     `_usedConvertFunctions`, `_usedProtoFunctions`)
///   - `.function = '...'` assignments
///   - bulk `addAll([...])` list literals
///   - route-table map literals (`'dartName': 'ball_name'`)
///   - route-table tuple literals (`('std_collections', 'ball_name', ...)`)
///
/// Over-matching is safe: the result set is only ever queried by exact
/// canonical function name, so stray matches that aren't real base-function
/// names are simply never looked up.
Set<String> _harvestEmittable(String src) {
  final candidates = <String>{
    // Emitted via a variable (e.g. spread/null_spread) — no literal at the
    // emit call site for the regexes below to find. Keep in sync with
    // check_encoder_completeness.dart's `_variableEmittedBaseFns`.
    'spread',
    'null_spread',
    // Built via string interpolation (`'${typeName}_$methodName'` for
    // `utf8.encode/decode` / `base64.encode/decode`) — no regex over a
    // static file can see an interpolated result, since the literal
    // substring never appears in the source.
    'utf8_encode',
    'utf8_decode',
    'base64_encode',
    'base64_decode',
  };

  void addAllMatches(RegExp re, {int group = 1}) {
    for (final m in re.allMatches(src)) {
      final v = m.group(group);
      if (v != null) candidates.add(v);
    }
  }

  addAllMatches(
    RegExp(r"_used\w*Functions\.add\(\s*'([a-zA-Z_][a-zA-Z0-9_]*)'"),
  );
  addAllMatches(RegExp(r"_buildStdCall\(\s*'([a-zA-Z_][a-zA-Z0-9_]*)'"));
  addAllMatches(RegExp(r"\.\.function\s*=\s*'([a-zA-Z_][a-zA-Z0-9_]*)'"));
  addAllMatches(
    RegExp(r"'[a-zA-Z_][a-zA-Z0-9_]*'\s*:\s*'([a-zA-Z_][a-zA-Z0-9_]*)'"),
  );
  addAllMatches(RegExp(r"\(\s*'std\w*'\s*,\s*'([a-zA-Z_][a-zA-Z0-9_]*)'"));
  // `switch (op) { '+' => 'add', ... }` operator-lexeme route tables
  // (e.g. `_dartOpToBallFunction`) — the case pattern is a symbol literal
  // (not `[a-zA-Z_]`), so the generic map-literal regex above can't see it.
  addAllMatches(RegExp(r"'[^']*'\s*=>\s*'([a-zA-Z_][a-zA-Z0-9_]*)'"));

  for (final m in RegExp(
    r'_used\w*Functions\.addAll\(\[([^\]]*)\]\)',
  ).allMatches(src)) {
    final body = m.group(1)!;
    for (final n in RegExp(r"'([a-zA-Z_][a-zA-Z0-9_]*)'").allMatches(body)) {
      candidates.add(n.group(1)!);
    }
  }

  // Safety net: some emit sites assign the ball-function name to a local
  // (e.g. `op == '++' ? 'post_increment' : 'post_decrement'` in
  // `_encodePostfixExpression`) that none of the shape-specific regexes
  // above can trace back to the `.add(...)`/`.function =` call. A plain
  // single-quoted-identifier scan of the whole file closes that gap. This
  // is deliberately broad — over-matching is harmless (candidates are only
  // ever consulted by exact canonical function name), but it does mean a
  // function name mentioned only in a comment would be misreported as
  // emittable; spot-check the gap report rather than trusting it blindly.
  addAllMatches(RegExp(r"'([a-zA-Z_][a-zA-Z0-9_]*)'"));

  // The broad single-quoted scan above also matches base-function names the
  // encoder mentions but never emits as a std CALL. `length` is such a case:
  // its only occurrence in encoder.dart is the `unaryFunctions` input-type
  // selection set — there is no `_buildStdCall('length')` / `..function =
  // 'length'` emit site, because `.length` encodes to a FieldAccess, not a
  // `std.length` call. The strict gate `check_encoder_completeness.dart`
  // agrees (it scans only emit sites, so it never treats `length` as
  // emittable). Subtract it so the coverage report shows no phantom gap.
  candidates.remove('length');

  return candidates;
}

/// Harvest candidate dispatched-on names from an engine source file: map
/// literal keys (`'name': handler`), `case 'name':`, and `== 'name'` /
/// `'name' ==` comparisons. Same over-matching-is-safe reasoning as
/// [_harvestEmittable] — results are only ever queried by canonical name.
void _harvestEngineDispatch(String src, Set<String> out) {
  void addAllMatches(RegExp re) {
    for (final m in re.allMatches(src)) {
      final v = m.group(1);
      if (v != null) out.add(v);
    }
  }

  addAllMatches(RegExp(r"'([a-zA-Z_][a-zA-Z0-9_]*)'\s*:\s"));
  addAllMatches(RegExp(r"case\s+'([a-zA-Z_][a-zA-Z0-9_]*)'"));
  addAllMatches(RegExp(r"==\s*'([a-zA-Z_][a-zA-Z0-9_]*)'"));
  addAllMatches(RegExp(r"'([a-zA-Z_][a-zA-Z0-9_]*)'\s*=="));
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
