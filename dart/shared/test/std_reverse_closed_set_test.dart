/// REVERSE closed-set gate for the std module builders (issue #702).
///
/// `std_routed_declarations_test.dart` (#505) and
/// `capability_table_closed_set_test.dart` (#686) both run in the FORWARD
/// direction — *declared* ⊆ routed/keyed. Neither can see the opposite drift,
/// and the opposite drift is the live one: a base function the Dart engine
/// dispatches, the capability table keys, and a fixture executes, while **no
/// `buildStd*Module()` builder declares it**. #686's own header records three
/// such names (`std.paren`, `std.labeled`, `std.yield_each`) and its RED output
/// listed ~40 more.
///
/// That is exactly the #505 class. A function no builder declares is invisible
/// to every other gate in the repo:
///
///   * `dart/shared/std.json` / `std.bin` — the canonical inventory
///     `gen_std.dart` emits — cannot list it, so no target has a machine-
///     readable contract to implement;
///   * `tests/conformance/std_coverage.json` + `STD_COVERAGE.md` derive their
///     canonical list from these very builders, so it can never surface there;
///   * `check_encoder_completeness.dart` demands an executed fixture for every
///     std function the encoder can emit — but only for functions it can see,
///     i.e. declared ones;
///   * a target that simply forgets to implement it fails at RUNTIME, on a
///     user's program, instead of at build time.
///
/// Three populations are pinned here, each derived from its own source of
/// truth (never a hand-maintained list), each with a POSITIVE FLOOR so a
/// derivation that silently collapses to the empty set fails loudly instead of
/// passing vacuously:
///
///  1. **The Dart engine's dispatch surface** — the `_buildStdDispatch()` map
///     literal in `dart/engine/lib/engine_std.dart`, which is what
///     `StdModuleHandler.init()` loads and therefore the exact set of names the
///     reference engine answers to.
///  2. **The capability table** — every key of `buildCapabilityTable()`. #686
///     proved declared ⊆ keyed; this proves keyed ⊆ declared, so the two
///     together make the table and the builders one inventory. A key naming a
///     function that exists nowhere else is dead policy: it documents a
///     capability decision for a construct no engine dispatches and no encoder
///     emits.
///  3. **The executed conformance corpus** — every `isBase` function a
///     `tests/conformance/*.ball.json` fixture declares (the same scan #686's
///     closed set 2 uses).
///
/// ### Why the engine surface is PARSED rather than imported
///
/// `ball_base` (this package) is the bottom of the Dart dependency graph:
/// `ball_engine` depends on it, not the other way round. Importing
/// `StdModuleHandler` here to read its public `registeredFunctions` getter
/// would invert that edge and make the shared package depend on an engine — so
/// the derivation reads the dispatch map out of the engine's source text, the
/// same shape `std_routed_declarations_test.dart` uses to read the encoder's
/// `collectionRoutes` table. The floor below is what keeps that parse honest.
///
/// ### Why the predicates differ per population
///
/// `StdModuleHandler`'s dispatch map is keyed by BARE function name and its
/// `handles()` accepts all eight std module names, so the engine resolves
/// `std.list_push` and `std_collections.list_push` through the same entry.
/// Population 1 is therefore checked against the bare-name union of all eight
/// builders, and population 3 — whose fixtures really do declare collection
/// functions under the `std` module name — accepts an exact `module.function`
/// match OR a bare-name match, mirroring #686's `lookupCapabilityByName`
/// fallback and the engine's own resolution. Population 2 is checked exactly:
/// the capability table is `module.function`-keyed by construction (#683), so a
/// key must match a declaration in THAT module.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show
        Module,
        buildStdCollectionsModule,
        buildStdConcurrencyModule,
        buildStdConvertModule,
        buildStdFsModule,
        buildStdIoModule,
        buildStdMemoryModule,
        buildStdModule,
        buildStdTimeModule;
import 'package:ball_base/cli_core.dart';
import 'package:test/test.dart';

/// Locates the repo root, tolerating whichever directory the suite is launched
/// from (package dir, repo root, sibling package).
Directory _repoRoot() {
  for (final base in ['.', '..', '../..', '../../..']) {
    if (Directory('$base/tests/conformance').existsSync() &&
        File('$base/dart/engine/lib/engine_std.dart').existsSync()) {
      return Directory(base);
    }
  }
  throw StateError(
    'could not locate the repo root from ${Directory.current.path}',
  );
}

/// The eight universal std modules, each paired with the builder that DECLARES
/// its base functions. Identical to the set `capabilityModuleNames()` models;
/// `capability_table_closed_set_test.dart` pins that equality.
const _stdBuilders = <String, Module Function()>{
  'std': buildStdModule,
  'std_collections': buildStdCollectionsModule,
  'std_io': buildStdIoModule,
  'std_memory': buildStdMemoryModule,
  'std_convert': buildStdConvertModule,
  'std_fs': buildStdFsModule,
  'std_time': buildStdTimeModule,
  'std_concurrency': buildStdConcurrencyModule,
};

/// `"module.function"` for every base function the eight std builders declare.
Set<String> _declaredQualified() {
  final declared = <String>{};
  _stdBuilders.forEach((name, build) {
    for (final f in build().functions) {
      if (f.isBase) declared.add('$name.${f.name}');
    }
  });
  return declared;
}

/// The bare function names of [_declaredQualified] — the spelling
/// `StdModuleHandler` dispatches on.
Set<String> _declaredBare() =>
    _declaredQualified().map((k) => k.substring(k.indexOf('.') + 1)).toSet();

/// Opening line of the engine's dispatch-table builder. Matched literally so a
/// rename fails the extraction (and therefore the floor) rather than silently
/// yielding an empty set.
const _dispatchSignature =
    'Map<String, FutureOr<Object?> Function(Object?)> _buildStdDispatch() {';

/// A top-level entry of that map literal: exactly six spaces of indentation
/// (map entries inside `return { … };` within a method), a single-quoted
/// identifier, a colon. Nested closures indent deeper, so this reads the
/// dispatch keys and nothing else.
final _dispatchKey = RegExp(r"^      '([A-Za-z0-9_]+)':", multiLine: true);

/// Every function name `StdModuleHandler` dispatches, read from the engine's
/// source (see the "Why the engine surface is PARSED" note above).
Set<String> _engineDispatchNames(Directory root) {
  final src = File(
    '${root.path}/dart/engine/lib/engine_std.dart',
  ).readAsStringSync();
  final start = src.indexOf(_dispatchSignature);
  if (start < 0) {
    throw StateError(
      '_buildStdDispatch() not found in engine_std.dart — its signature '
      'changed; update _dispatchSignature',
    );
  }
  // The map literal closes on the method's own `};` at four-space indentation.
  final end = src.indexOf('\n    };', start);
  if (end < 0) {
    throw StateError('could not find the end of the _buildStdDispatch() map');
  }
  return _dispatchKey
      .allMatches(src.substring(start, end))
      .map((m) => m.group(1)!)
      .toSet();
}

/// `"module.function"` -> the fixture files declaring it `isBase`, across the
/// whole committed conformance corpus. Read as raw JSON (not through the proto
/// decoder) so a fixture that fails to parse as a `Program` is still scanned.
Map<String, Set<String>> _corpusBaseDecls(Directory root) {
  final out = <String, Set<String>>{};
  final dir = Directory('${root.path}/tests/conformance');
  for (final entry in dir.listSync()) {
    if (entry is! File || !entry.path.endsWith('.ball.json')) continue;
    final raw = jsonDecode(entry.readAsStringSync()) as Map<String, dynamic>;
    for (final m in (raw['modules'] as List? ?? const <dynamic>[])) {
      final module = m as Map<String, dynamic>;
      final moduleName = module['name'] as String? ?? '';
      for (final f in (module['functions'] as List? ?? const <dynamic>[])) {
        final fn = f as Map<String, dynamic>;
        if (fn['isBase'] != true) continue;
        out
            .putIfAbsent('$moduleName.${fn['name']}', () => <String>{})
            .add(entry.uri.pathSegments.last);
      }
    }
  }
  return out;
}

/// The remediation every failure message ends with — one place, so the three
/// populations cannot drift apart on the instructions they give.
const _howToFix =
    'FIX: declare each name with its REAL signature (read the handler in '
    'dart/engine/lib/engine_std.dart for the input field names) in the '
    'matching dart/shared/lib/std*.dart builder, then regenerate with\n'
    '  cd dart/shared  && dart run bin/gen_std.dart\n'
    '  cd dart/encoder && dart run bin/gen_std_coverage.dart\n'
    'and satisfy dart/encoder/bin/check_encoder_completeness.dart with a real '
    'fixture or a documented CARVEOUTS.md entry — never by weakening the gate. '
    'A name that exists ONLY in the capability table is dead policy: unkey it '
    'instead (issues #702, #505).';

void main() {
  final root = _repoRoot();
  final declaredQualified = _declaredQualified();
  final declaredBare = _declaredBare();

  group('reverse closed set 0 — the builder derivation (#702)', () {
    // POSITIVE FLOOR for the shared denominator of all three populations: an
    // empty `declared` set would make every "is declared" check below fail
    // rather than pass, but a derivation that quietly lost ONE module would
    // produce a plausible-looking failure list pointing at the wrong bug.
    test('the builder derivation is non-vacuous', () {
      expect(
        declaredQualified.length,
        greaterThan(250),
        reason:
            'the std builders declare 270+ base functions; got '
            '${declaredQualified.length} — the derivation is broken',
      );
      for (final module in _stdBuilders.keys) {
        expect(
          declaredQualified.any((k) => k.startsWith('$module.')),
          isTrue,
          reason: '$module contributed no base function',
        );
      }
    });
  });

  group('reverse closed set 1 — the Dart engine dispatch surface (#702)', () {
    late final Set<String> dispatched;

    setUpAll(() => dispatched = _engineDispatchNames(root));

    // POSITIVE FLOOR — the extraction is a regex over engine source. If the map
    // is renamed, reformatted or re-indented the match count collapses and
    // every subset assertion below passes vacuously.
    test('the dispatch extraction is non-vacuous', () {
      expect(
        dispatched.length,
        greaterThan(250),
        reason:
            'extracted only ${dispatched.length} dispatch keys from '
            '_buildStdDispatch() in dart/engine/lib/engine_std.dart — it has '
            'always had 250+. The regex has stopped matching; fix it before '
            'trusting the assertion below.',
      );
      // Anchor names from opposite ends of the map, so a partial match (the
      // regex stopping early at some nested construct) is caught too.
      for (final anchor in ['print', 'add', 'if', 'math_lcm']) {
        expect(
          dispatched,
          contains(anchor),
          reason: 'the dispatch extraction missed the well-known "$anchor"',
        );
      }
    });

    test('every base function the engine dispatches is declared by a '
        'builder', () {
      final missing = dispatched.difference(declaredBare).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason:
            'ENGINE-DISPATCHED but UNDECLARED (${missing.length}):\n'
            '  ${missing.join('\n  ')}\n'
            'StdModuleHandler answers to these names, so programs call them '
            'and every self-hosted engine must implement them — yet they are '
            'absent from dart/shared/std.json, from STD_COVERAGE.md and from '
            "the encoder-completeness gate's view of the world.\n"
            '$_howToFix',
      );
    });
  });

  group('reverse closed set 2 — the capability table (#702)', () {
    late final Map<String, String> table;

    setUpAll(() => table = buildCapabilityTable());

    // POSITIVE FLOOR — mirrors #686's floor on the same table.
    test('the capability table is non-vacuous', () {
      expect(
        table.length,
        greaterThan(250),
        reason:
            'buildCapabilityTable() returned ${table.length} keys; it has '
            'keyed 300+ since #686',
      );
    });

    test('every base function the capability table keys is declared by a '
        'builder', () {
      final missing =
          table.keys.where((k) => !declaredQualified.contains(k)).toList()
            ..sort();
      expect(
        missing,
        isEmpty,
        reason:
            'TABLE-KEYED but UNDECLARED (${missing.length}):\n'
            '  ${missing.join('\n  ')}\n'
            'capability_table.dart opens by claiming to be provably complete. '
            '#686 proved declared ⊆ keyed; this is the other half. A key whose '
            '(module, function) no builder declares is either a real function '
            'missing from the inventory, or dead policy for a construct no '
            'engine dispatches and no encoder emits.\n'
            '$_howToFix',
      );
    });
  });

  group('reverse closed set 3 — the executed conformance corpus (#702)', () {
    late final Map<String, Set<String>> corpus;

    setUpAll(() => corpus = _corpusBaseDecls(root));

    // POSITIVE FLOOR — identical reasoning to #686's closed set 2: an empty
    // scan passes every subset assertion.
    test('the corpus scan is non-vacuous', () {
      final fixtures = <String>{};
      for (final files in corpus.values) {
        fixtures.addAll(files);
      }
      expect(
        fixtures.length,
        greaterThan(300),
        reason: 'scanned only ${fixtures.length} fixtures',
      );
      expect(
        corpus.length,
        greaterThan(150),
        reason: 'found only ${corpus.length} distinct base declarations',
      );
    });

    test('every base function an executed fixture declares is declared by a '
        'builder', () {
      final missing = <String>[];
      for (final key in corpus.keys) {
        final module = key.substring(0, key.indexOf('.'));
        final bare = key.substring(key.indexOf('.') + 1);
        // A fixture declaring a std function under a foreign module name is a
        // different question (#683 owns it); this gate only asks whether the
        // NAME is in the canonical inventory at all.
        if (!_stdBuilders.containsKey(module)) continue;
        if (declaredQualified.contains(key)) continue;
        if (declaredBare.contains(bare)) continue;
        missing.add(
          '$key  (${corpus[key]!.length} fixtures, e.g. '
          '${(corpus[key]!.toList()..sort()).first})',
        );
      }
      missing.sort();
      expect(
        missing,
        isEmpty,
        reason:
            'CORPUS-EXECUTED but UNDECLARED (${missing.length}):\n'
            '  ${missing.join('\n  ')}\n'
            'These run on every engine in the conformance matrix, so they are '
            'load-bearing by definition — and no builder declares them.\n'
            '$_howToFix',
      );
    });
  });
}
