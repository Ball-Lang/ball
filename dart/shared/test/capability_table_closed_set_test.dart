/// CLOSED-SET gates for the capability table (issues #682, #683).
///
/// `capability_table.dart` opens with the claim that the table is *provably
/// complete* — "no function can perform I/O, access the filesystem, or spawn
/// threads without appearing here". Nothing in CI ever checked that claim
/// against a source of truth, and it was false: `std.type_of`, `std.to_int`,
/// `std_collections.list_join` and 60+ more base functions were declared,
/// emitted, dispatched and executed while the table never keyed them. That gap
/// is what blocked #683's real fix — a base function the table does not key
/// cannot be classified `custom`, so a program-supplied module *squatting* a
/// std name (`std.exec_shell`) audited as an ordinary user call, i.e. **pure**.
///
/// Three closed sets are pinned here, each derived from a source of truth —
/// never from a hand-maintained list:
///
///  1. **The std module builders** (`buildStd*Module()` in
///     `package:ball_base`). Every base function they DECLARE must be keyed.
///     Derived from the builders directly rather than by parsing
///     `dart/shared/std.json`, because `gen_std.dart` serializes only
///     `buildStdModule()` — the `std` slice — while the table models eight
///     modules and the other seven have no committed JSON artifact.
///     `std_builders_test.dart` already pins `buildStdModule()` byte-for-byte
///     against `std.json`, so the builders are the strictly wider spelling of
///     the same inventory.
///  2. **The executed conformance corpus** (`tests/conformance/*.ball.json`).
///     Every `isBase` function a fixture DECLARES must RESOLVE to a capability
///     — directly, or through the #402 bare-name fallback. This is the exact
///     predicate `_collectCustomBaseFns` applies after #683, so it is the set
///     that decides whether the name-scoped `custom` rule lights up the whole
///     corpus. The builders alone cannot see it: the corpus declares
///     `std.typed_list`, `std.symbol`, `std.switch_expr`, `std.map_create`,
///     `std.collection_for` and friends, which the engine dispatches and no
///     builder declares (a separate, pre-existing #505-class drift).
///  3. **`ball.proto`'s `CapabilityEntry` doc comment** (#682 DoD 2). The
///     category and risk-level enumerations a consumer reads out of the schema
///     must equal the sets the analyzer can actually emit.
///
/// Each set is checked in ONE direction — declared/emitted ⊆ keyed. The reverse
/// (every key is declared by a builder) is deliberately NOT asserted: the
/// corpus proves the builders themselves are incomplete (`std.paren`,
/// `std.labeled`, `std.yield_each` are keyed, executed, and undeclared), so a
/// two-way assertion here would gate a different bug in the wrong place.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show
        Module,
        buildBallProtoModule,
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

/// Locates a repo-relative path, tolerating whichever directory the suite is
/// launched from (package dir, repo root, sibling package).
Directory _repoRoot() {
  for (final base in ['.', '..', '../..', '../../..']) {
    if (Directory('$base/tests/conformance').existsSync() &&
        File('$base/proto/ball/v1/ball.proto').existsSync()) {
      return Directory(base);
    }
  }
  throw StateError(
    'could not locate the repo root from ${Directory.current.path}',
  );
}

/// The eight universal std modules the capability table models, each paired
/// with the builder that DECLARES its base functions.
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
Set<String> _declaredBaseFns() {
  final declared = <String>{};
  _stdBuilders.forEach((name, build) {
    final m = build();
    for (final f in m.functions) {
      if (f.isBase) declared.add('$name.${f.name}');
    }
  });
  return declared;
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

/// The comment lines directly above `<field>` inside `message CapabilityEntry`,
/// with the leading `//` stripped.
String _capabilityEntryComment(Directory root, String field) {
  final src = File('${root.path}/proto/ball/v1/ball.proto').readAsStringSync();
  final start = src.indexOf('message CapabilityEntry {');
  if (start < 0) {
    throw StateError('message CapabilityEntry not found in ball.proto');
  }
  final end = src.indexOf('\n}', start);
  final body = src.substring(start, end < 0 ? src.length : end);
  final lines = body.split('\n');
  final fieldIndex = lines.indexWhere((l) => l.trim().startsWith(field));
  if (fieldIndex < 0) {
    throw StateError('field "$field" not found in CapabilityEntry');
  }
  final comment = <String>[];
  for (var i = fieldIndex - 1; i >= 0; i--) {
    final trimmed = lines[i].trim();
    if (!trimmed.startsWith('//')) break;
    comment.insert(0, trimmed.substring(2).trim());
  }
  return comment.join(' ');
}

/// Every double-quoted token in [text].
Set<String> _quoted(String text) =>
    RegExp(r'"([a-z_]+)"').allMatches(text).map((m) => m.group(1)!).toSet();

void main() {
  final table = buildCapabilityTable();
  final root = _repoRoot();

  group('closed set 1 — the std builders (#683 DoD 1)', () {
    late final Set<String> declared;

    setUpAll(() => declared = _declaredBaseFns());

    // POSITIVE FLOOR — a derivation that silently collapses to the empty set
    // (a builder renamed, `isBase` spelled differently) would make the subset
    // assertion below pass vacuously. Assert the derivation found a realistic
    // inventory spanning every module the table claims to model.
    test('the builder derivation is non-vacuous', () {
      expect(
        declared.length,
        greaterThan(250),
        reason:
            'the std builders declare 270+ base functions; got '
            '${declared.length} — the derivation is broken, not the table',
      );
      for (final module in _stdBuilders.keys) {
        expect(
          declared.any((k) => k.startsWith('$module.')),
          isTrue,
          reason: '$module contributed no base function',
        );
      }
    });

    test('the table models exactly the eight std builder modules', () {
      expect(
        capabilityModuleNames().toSet(),
        _stdBuilders.keys.toSet(),
        reason:
            'capabilityModuleNames() and the std builders disagree — the '
            'bare-name fallback scans the former, so a module in one and not '
            'the other is a hole (#402)',
      );
    });

    test('every base function the std builders declare is keyed', () {
      final missing = declared.difference(table.keys.toSet()).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason:
            'capability_table.dart claims to be provably complete, but these '
            '${missing.length} DECLARED base functions have no entry. An '
            'unkeyed base function cannot be classified at all — which is why '
            'a program-supplied `std.exec_shell` audited as pure (#683):\n'
            '  ${missing.join('\n  ')}',
      );
    });

    test(
      'ball_proto is EXCLUDED by design — it is the host-extension seam',
      () {
        // `buildBallProtoModule()` is a std-shaped builder but `ball_proto` is
        // NOT one of the eight universal std modules: its implementation is
        // supplied by the host (`BallModuleHandler`), exactly like a program's
        // own `ui`/`evil` module. It is therefore deliberately absent from the
        // table so a program declaring it audits `custom` (#609) rather than
        // being silently blessed. Pinned so a future edit that keys it is a
        // deliberate decision, not a drive-by.
        final ballProto = buildBallProtoModule();
        final baseFns = ballProto.functions.where((f) => f.isBase).toList();
        expect(baseFns, isNotEmpty, reason: 'ball_proto declares no base fns');
        for (final f in baseFns) {
          expect(
            lookupCapability(table, 'ball_proto', f.name),
            '',
            reason:
                'ball_proto.${f.name} is keyed — ball_proto is the host '
                'extension seam and must stay `custom`',
          );
        }
        expect(capabilityModuleNames(), isNot(contains('ball_proto')));
      },
    );
  });

  group('closed set 2 — the executed conformance corpus (#683 DoD 3)', () {
    late final Map<String, Set<String>> corpus;

    setUpAll(() => corpus = _corpusBaseDecls(root));

    // POSITIVE FLOOR — same reasoning as above: an empty scan passes every
    // subset assertion. The corpus is 350 fixtures declaring 150+ distinct
    // base functions.
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

    test('every base function the corpus declares resolves to a capability', () {
      // This is the exact predicate the name-scoped `custom` rule applies: a
      // DECLARED base function whose (module, function) misses the table and
      // whose bare name resolves to nothing is a host extension. Anything in
      // this list would light up as `custom` across the conformance corpus the
      // moment #683's rule lands — the failure mode #683 warns about.
      final unresolved = <String>[];
      for (final key in corpus.keys) {
        final bare = key.substring(key.indexOf('.') + 1);
        if (table.containsKey(key)) continue;
        if (lookupCapabilityByName(table, bare).isNotEmpty) continue;
        unresolved.add(
          '$key  (${corpus[key]!.length} fixtures, e.g. '
          '${(corpus[key]!.toList()..sort()).first})',
        );
      }
      unresolved.sort();
      expect(
        unresolved,
        isEmpty,
        reason:
            'these ${unresolved.length} executed base functions resolve to no '
            'capability, so the name-scoped `custom` rule would misclassify '
            'real std calls as host extensions:\n  ${unresolved.join('\n  ')}',
      );
    });
  });

  group('closed set 3 — ball.proto CapabilityEntry doc comments (#682)', () {
    test('the comment extraction is non-vacuous', () {
      expect(
        _capabilityEntryComment(root, 'string capability = 1;'),
        isNotEmpty,
      );
      expect(
        _capabilityEntryComment(root, 'string risk_level = 2;'),
        isNotEmpty,
      );
    });

    test('the documented categories equal the analyzer\'s emitted set', () {
      final documented = _quoted(
        _capabilityEntryComment(root, 'string capability = 1;'),
      );
      expect(
        documented,
        capabilityNames().toSet(),
        reason:
            'ball.proto is the contract a consumer reads. Its CapabilityEntry '
            'category list must enumerate exactly what capabilityNames() can '
            'emit — no more, no less',
      );
    });

    test('the documented risk levels equal the analyzer\'s emitted set', () {
      final documented = _quoted(
        _capabilityEntryComment(root, 'string risk_level = 2;'),
      );
      final emitted = <String>{
        for (final c in capabilityNames()) capabilityRisk(c),
      };
      expect(
        documented,
        emitted,
        reason:
            'risk_level carries `unknown` since #609; the schema comment must '
            'enumerate exactly the levels capabilityRisk() can return',
      );
    });
  });
}
