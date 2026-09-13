/// CI gate: every std base function the Dart ENCODER can emit MUST be exercised
/// by at least one executed conformance fixture (`tests/conformance/src/*.dart`),
/// OR be a documented carve-out in
/// `tests/conformance/ENCODER_COMPLETENESS_CARVEOUTS.md`.
///
/// This is the forward-direction completeness guarantee that was missing when
/// issue #55 slipped through: the encoder emitted `collection_for`,
/// `collection_if`, `spread`, and `null_spread`, but NO source in the corpus
/// used `[for ...]` / `[...x]` / set-or-map comprehensions, so those base
/// functions were never executed and their (then-broken) engine handling
/// produced silent wrong output. `check_conformance_sources.dart` only enforces
/// the REVERSE direction (every `.ball.json` has a source); this closes the gap.
///
/// How it works:
///   * "Emittable" = every base-function name the encoder can produce. We derive
///     it by encoding every `src/*.dart` (the corpus is broad) AND by scanning
///     the encoder's own source for the names it references at its emit sites
///     (`_usedBaseFunctions.add('x')`, `_buildStdCall('x', …)`, `..function =
///     'x'`), plus the VALUE position of the encoder's dispatch tables
///     (`collectionRoutes` and friends — see `_routeTables`, issue #488), plus a
///     small explicit supplement for names emitted via a variable
///     (`spread`/`null_spread`).
///   * "Covered" = the union of `isBase` function names declared by every
///     encoded `src/*.dart` program. The encoder declares EXACTLY the base
///     functions a program used, so a function appearing here means some fixture
///     actually emits — and (via the conformance run) executes — it.
///   * Gate fails if any emittable name is neither covered nor carved out.
///
/// Run from `dart/encoder`:
///   dart run bin/check_encoder_completeness.dart
library;

import 'dart:io';

import 'package:ball_encoder/encoder.dart';

/// Base functions the encoder emits through a *variable* (not a string literal
/// at the emit call), so the source scan below cannot see them. Keep in sync
/// with `_encodeCollectionElement` etc. Each MUST still be covered by a fixture.
const _variableEmittedBaseFns = <String>{'spread', 'null_spread'};

/// Names that appear at an emit site but are NOT base functions to gate (e.g.
/// pseudo-targets). Empty today; documented here so future additions are
/// deliberate rather than silent.
const _notBaseFunctions = <String>{};

/// Dispatch TABLES in `encoder.dart` that name a base function in a map VALUE
/// rather than at the emit call site (issue #488).
///
/// `collectionRoutes`' emit site is `_usedBaseFunctions.add(fnName)` /
/// `..function = fnName`, where `fnName` is destructured from the table's
/// tuple value — never a string literal — so the two emit-site regexes above
/// could not see a single one of these names. Every base function reachable
/// ONLY through one of these tables was therefore exempt from this gate
/// regardless of whether any fixture covered it:
/// `std_collections.map_contains_value` sat in the generated
/// `tests/conformance/std_coverage.json` with `coveredByFixtures: []` and
/// `carvedOut: false` while this very gate reported "No completeness gaps."
///
/// `valueIndex` is which string of the entry's value holds the base-function
/// name: `0` for a `<String, String>` table (`'trim': 'string_trim'`), `1` for
/// a tuple table whose first element is the module
/// (`'add': ('std_collections', 'list_push', 'list', 1, 1)`).
///
/// `protoRoutes` is deliberately absent: it routes into the `ball_proto`
/// module, which is a protobuf ACCESS-PATTERN surface, not a std base-function
/// one, and its names are not part of the std inventory this gate measures.
const _routeTables = <String, int>{
  'getterRoutes': 0,
  'convertTopLevelRoutes': 0,
  'unaryRoutes': 0,
  'collectionRoutes': 1,
  'cascadeCollectionRoutes': 1,
};

/// Extracts the base-function names named in the VALUE position of
/// [_routeTables]' entries.
///
/// Fails loud when a declared table is not found: a rename must not silently
/// shrink this gate's population back to what it was before #488.
Set<String> _routedBaseFunctions(String encoderSrc) {
  final out = <String>{};
  for (final entry in _routeTables.entries) {
    final decl = RegExp('${entry.key}\\s*=\\s*<').firstMatch(encoderSrc);
    if (decl == null) {
      stderr.writeln(
        'ERROR: dispatch table `${entry.key}` was not found in encoder.dart. '
        'It was renamed or removed — update _routeTables, or this gate '
        'silently stops seeing every base function it routes.',
      );
      exit(2);
    }
    final body = _braceBody(encoderSrc, decl.end);
    // Entry values: either `'key': 'fn'` or `'key': ('module', 'fn', …)`.
    final entryRe = RegExp(r"""'[^']+'\s*:\s*(\(\s*)?((?:'[^']*'\s*,?\s*)+)""");
    for (final m in entryRe.allMatches(body)) {
      final strings = RegExp(
        "'([^']*)'",
      ).allMatches(m.group(2)!).map((s) => s.group(1)!).toList();
      if (strings.length > entry.value) out.add(strings[entry.value]);
    }
  }
  return out;
}

/// The text between the first `{` at or after [from] and its matching `}`.
String _braceBody(String src, int from) {
  final open = src.indexOf('{', from);
  if (open < 0) throw StateError('no map literal after offset $from');
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  throw StateError('unbalanced map literal at offset $open');
}

void main() {
  final repoRoot = _findRepoRoot();
  final srcDir = Directory('$repoRoot/tests/conformance/src');
  final encoderLib = File('$repoRoot/dart/encoder/lib/encoder.dart');
  final carveoutsFile = File(
    '$repoRoot/tests/conformance/ENCODER_COMPLETENESS_CARVEOUTS.md',
  );

  if (!srcDir.existsSync()) {
    stderr.writeln('Source directory not found: ${srcDir.path}');
    exit(2);
  }
  if (!encoderLib.existsSync()) {
    stderr.writeln('Encoder source not found: ${encoderLib.path}');
    exit(2);
  }

  // ── Emittable: names the encoder references at its emit sites ──
  final emittable = <String>{..._variableEmittedBaseFns};
  final emitSite = RegExp(
    r"""(?:_usedBaseFunctions\.add|_buildStdCall)\(\s*'([a-z][a-z0-9_]*)'""",
  );
  final functionAssign = RegExp(r"""\.\.function\s*=\s*'([a-z][a-z0-9_]*)'""");
  final encoderSrc = encoderLib.readAsStringSync();
  for (final m in emitSite.allMatches(encoderSrc)) {
    emittable.add(m.group(1)!);
  }
  for (final m in functionAssign.allMatches(encoderSrc)) {
    emittable.add(m.group(1)!);
  }
  emittable.addAll(_routedBaseFunctions(encoderSrc));
  emittable.removeAll(_notBaseFunctions);

  // ── Covered: base functions actually emitted by encoding every fixture ──
  final covered = <String>{};
  final srcFiles =
      srcDir
          .listSync()
          .whereType<File>()
          .where(
            (f) => f.path.endsWith('.dart') && !f.path.contains('generate_'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  var encodeFailures = 0;
  for (final f in srcFiles) {
    try {
      final program = DartEncoder().encode(f.readAsStringSync());
      for (final module in program.modules) {
        for (final fn in module.functions) {
          if (fn.isBase) covered.add(fn.name);
        }
      }
    } catch (e) {
      encodeFailures++;
      stderr.writeln('  encode failed: ${f.path.split('/').last}: $e');
    }
  }
  if (encodeFailures > 0) {
    stderr.writeln('ERROR: $encodeFailures source(s) failed to encode.');
    exit(1);
  }

  // ── Carve-outs ──
  final carveouts = <String>{};
  if (carveoutsFile.existsSync()) {
    final re = RegExp(r'^-\s+`([a-z][a-z0-9_]*)`');
    for (final line in carveoutsFile.readAsLinesSync()) {
      final m = re.firstMatch(line.trim());
      if (m != null) carveouts.add(m.group(1)!);
    }
  }

  final missing = emittable.difference(covered).difference(carveouts).toList()
    ..sort();
  final staleCarveouts = carveouts.intersection(covered).toList()..sort();

  var failed = false;
  if (missing.isNotEmpty) {
    failed = true;
    stderr.writeln(
      'ERROR: ${missing.length} encoder-emittable base function(s) are NOT '
      'exercised by any conformance fixture and are not carved out:',
    );
    for (final name in missing) {
      stderr.writeln(
        "  - $name  (add a tests/conformance/src/*.dart that uses it, or list "
        "it in ENCODER_COMPLETENESS_CARVEOUTS.md with a justification)",
      );
    }
  }
  if (staleCarveouts.isNotEmpty) {
    failed = true;
    stderr.writeln(
      'ERROR: ${staleCarveouts.length} ENCODER_COMPLETENESS_CARVEOUTS.md '
      'entr(y/ies) are now covered by a fixture — remove them:',
    );
    for (final name in staleCarveouts) {
      stderr.writeln('  - $name');
    }
  }

  if (failed) exit(1);

  stdout.writeln(
    'OK: ${covered.length} base functions covered by ${srcFiles.length} '
    'fixtures; ${emittable.length} emittable, '
    '${carveouts.length} documented carve-outs. No completeness gaps.',
  );
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
