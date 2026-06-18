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
///     'x'`), plus a small explicit supplement for names emitted via a variable
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
