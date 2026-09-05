/// Self-test for the Tier B coverage-study harness (issue #493).
///
/// SCOPE, stated plainly: this is TDD scaffolding for a NEW instrument. It is
/// not evidence that an existing gate missed a bug — Tier B is the epic's own
/// previously-documented remaining slice, and Tier A's structural-only limit is
/// a deliberate, documented design, not an oversight.
///
/// What it has to prove is that the new instrument is worth trusting, against
/// the REAL pipeline and a REAL `dart test` run:
///
///  1. **Restoration integrity.** Per-file substitution puts the original bytes
///     back after every run, verified by SHA-256. A harness that leaves a
///     checkout dirty compounds substitutions across files and silently
///     corrupts every later verdict, so this is the first assertion, not an
///     afterthought.
///  2. A file whose compiled-back Dart still passes the package's suite is
///     scored `clean` — the harness cannot pass by calling everything dirty.
///  3. **The load-bearing one.** A file carrying the #488 shape — a
///     `Set<T>.add(x)` whose `bool` result is returned — is scored
///     `behavioral-drift`, *while Tier A scores the very same source `clean`*.
///     Both verdicts are asserted here, side by side, because the pair is the
///     entire justification for Tier B existing: the construct parses, keeps
///     every declaration and reaches the stage-5 fixpoint, and only the
///     package's own tests can see that `bool` became `Set<String>`.
///  4. A package whose UNMODIFIED suite does not pass 100% is reported
///     `baseline-unstable` and excluded from the denominator — never silently
///     defaulted to clean or dirty, which is how a flaky third-party suite
///     would otherwise manufacture (or mask) an encoder regression.
///  5. **Positive floor.** At least one file was scored, and a `Results:`-shaped
///     line was actually printed. An exit code plus a zero failure count cannot
///     distinguish "everything passed" from "nothing ran".
///
/// It also covers the whole-package mode (`rq1_tierb_all.dart`), whose stricter
/// signal is one verdict per package with no restore between files, and the
/// non-scoring `not-compiled` category (a directives-only facade library, which
/// never reaches Tier A stage 2 and so has nothing to substitute).
///
/// Run from the repo root:
///   dart run tools/coverage-study/test/rq1_tierb_self_test.dart
library;

import 'dart:io';

import '../rq1_study.dart' as tier_a;
import '../rq1_tierb.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _passed++;
    stdout.writeln('PASS  $name');
  } else {
    _failed++;
    stdout.writeln('FAIL  $name${detail.isEmpty ? '' : ' — $detail'}');
  }
}

const _pubspec = '''
name: ball_tierb_synthetic
publish_to: none
environment:
  sdk: ^3.9.0
dev_dependencies:
  test: any
''';

/// `lib/helper.dart` — a plain library file. Its compiled-back form renames the
/// parameter to Ball's single `input` and re-binds it to a local, which is a
/// faithful lowering: positional callers cannot tell, so the suite still passes
/// and the file must score `clean`.
const _helperSource = '''
class Helper {
  int twice(int value) {
    return value * 2;
  }

  String shout(String word) {
    return word.toUpperCase();
  }
}
''';

/// `lib/registry.dart` — the #488 shape, and the reason Tier B exists.
///
/// `seen.add(name)` on a `Set<String>` returns `bool`. The encoder dispatches
/// the call on its NAME alone, mis-routes it into a cascade-shaped IR node, and
/// `DartCompiler.compileModule` faithfully lowers that back to
/// `return seen..add(name);` — whose static type is `Set<String>`, not `bool`.
/// The file still parses, keeps every declaration and reaches the stage-5
/// fixpoint, so Tier A calls it clean; only running the suite sees the loss.
const _registrySource = '''
class Registry {
  final Set<String> seen = <String>{};

  bool remember(String name) {
    return seen.add(name);
  }

  int count() {
    return seen.length;
  }
}
''';

/// `lib/facade.dart` — a directives-only re-export library. Nothing to compile
/// back, so Tier A never scores it and Tier B must report `not-compiled`
/// (non-scoring) rather than inventing a verdict.
const _facadeSource = "export 'helper.dart';\n";

const _suite = '''
import 'package:ball_tierb_synthetic/helper.dart';
import 'package:ball_tierb_synthetic/registry.dart';
import 'package:test/test.dart';

void main() {
  test('helper doubles and shouts', () {
    expect(Helper().twice(21), 42);
    expect(Helper().shout('ball'), 'BALL');
  });

  test('registry reports whether a name was new', () {
    final registry = Registry();
    expect(registry.remember('a'), isTrue);
    expect(registry.remember('a'), isFalse);
    expect(registry.count(), 1);
  });
}
''';

/// Added only for the `baseline-unstable` scenario: a package whose own
/// UNMODIFIED suite is already red is not a yardstick for anything.
const _failingSuite = '''
import 'package:test/test.dart';

void main() {
  test('this package is already broken before any substitution', () {
    expect(1, 2);
  });
}
''';

Map<String, String> _digests(Directory libRoot) => {
  for (final file in dartFilesUnder(libRoot))
    file.path: digestOf(file.readAsBytesSync()),
};

Future<void> main() async {
  final tempDir = Directory.systemTemp.createTempSync('rq1_tierb_self_test');
  try {
    Directory('${tempDir.path}/lib').createSync(recursive: true);
    Directory('${tempDir.path}/test').createSync(recursive: true);
    File('${tempDir.path}/pubspec.yaml').writeAsStringSync(_pubspec);
    File('${tempDir.path}/lib/helper.dart').writeAsStringSync(_helperSource);
    File(
      '${tempDir.path}/lib/registry.dart',
    ).writeAsStringSync(_registrySource);
    File('${tempDir.path}/lib/facade.dart').writeAsStringSync(_facadeSource);
    File('${tempDir.path}/test/synthetic_test.dart').writeAsStringSync(_suite);

    final libRoot = Directory('${tempDir.path}/lib');

    // ── The contrast that justifies the whole tier ──────────────────────────
    // Tier A, on the EXACT source Tier B is about to fail, says `clean`.
    final tierAVerdict = tier_a.studyFile(
      'synthetic',
      'registry.dart',
      _registrySource,
    );
    check(
      'Tier A scores the #488-shaped file CLEAN (it parses, keeps every '
          'declaration and reaches the fixpoint)',
      tierAVerdict.scored && tierAVerdict.clean,
      'scored=${tierAVerdict.scored} clean=${tierAVerdict.clean} '
          'reason="${tierAVerdict.reason}"',
    );

    // ── Per-file substitution ───────────────────────────────────────────────
    final digestsBefore = _digests(libRoot);
    final perFile = await studyPackagePerFile('synthetic', tempDir);

    check(
      'a package with a healthy baseline is scored, not excluded',
      perFile.status == 'scored',
      'status was "${perFile.status}"',
    );

    final helper = perFile.files.where((f) => f.file == 'helper.dart').toList();
    check(
      'a file whose compiled-back Dart still passes the suite is scored clean',
      helper.length == 1 && helper.single.clean,
      helper.isEmpty ? 'not reported' : 'reason was "${helper.single.reason}"',
    );

    final registry = perFile.files
        .where((f) => f.file == 'registry.dart')
        .toList();
    check(
      'THE LOAD-BEARING ONE: the #488-shaped file Tier A called clean is '
      'scored behavioral-drift by Tier B',
      registry.length == 1 &&
          registry.single.scored &&
          registry.single.tag == 'behavioral-drift',
      registry.isEmpty
          ? 'not reported'
          : 'reason was "${registry.single.reason}"',
    );

    final facade = perFile.files.where((f) => f.file == 'facade.dart').toList();
    check(
      'a file that never reaches Tier A stage 2 is not-compiled and NOT scored',
      facade.length == 1 &&
          facade.single.tag == 'not-compiled' &&
          !facade.single.scored,
      facade.isEmpty ? 'not reported' : 'reason was "${facade.single.reason}"',
    );

    check(
      'per-file substitution restores every file BYTE-FOR-BYTE (SHA-256)',
      _mapsEqual(_digests(libRoot), digestsBefore),
      'digests changed: ${_digests(libRoot)} vs $digestsBefore',
    );

    // ── The positive floor ──────────────────────────────────────────────────
    final scored = perFile.files.where((f) => f.scored).length;
    check(
      'at least one file was actually scored (a zero-scored run is a harness '
          'failure, never a 0% result)',
      scored >= 1,
      'scored=$scored',
    );

    final lines = summaryLines([perFile], tierLabel: 'Tier B');
    final resultsLine = lines.firstWhere(
      (l) => l.startsWith('Results: '),
      orElse: () => '',
    );
    check(
      'the harness prints a Results:-shaped line CI can parse',
      RegExp(
        r'^Results: \d+ passed, \d+ failed, \d+ total$',
      ).hasMatch(resultsLine),
      'line was "$resultsLine"',
    );
    check(
      'the harness prints the Tier B percentage line',
      lines.any((l) => RegExp(r'^Tier B: \d+/\d+ clean \(\d+%\)$').hasMatch(l)),
      lines.join(' | '),
    );

    // ── Whole-package substitution ──────────────────────────────────────────
    final whole = await studyPackageWhole('synthetic', tempDir);
    check(
      'whole-package substitution yields exactly one verdict for the package',
      whole.status == 'scored' && whole.files.length == 1,
      'status="${whole.status}" files=${whole.files.length}',
    );
    check(
      'a package containing the #488 shape is NOT clean whole-package',
      whole.files.length == 1 && whole.files.single.tag == 'behavioral-drift',
      whole.files.isEmpty
          ? 'not reported'
          : 'reason was "${whole.files.single.reason}"',
    );
    check(
      'whole-package substitution restores every file BYTE-FOR-BYTE (SHA-256)',
      _mapsEqual(_digests(libRoot), digestsBefore),
      'digests changed after the whole-package run',
    );

    // ── A package whose own suite is already red ─────────────────────────────
    final failing = File('${tempDir.path}/test/already_failing_test.dart')
      ..writeAsStringSync(_failingSuite);
    final unstable = await studyPackagePerFile('synthetic', tempDir);
    failing.deleteSync();
    check(
      'a package whose UNMODIFIED suite does not pass 100% is reported '
          'baseline-unstable',
      unstable.status.startsWith('baseline-unstable'),
      'status was "${unstable.status}"',
    );
    check(
      'and every one of its files is excluded from the denominator, never '
          'mis-scored',
      unstable.files.isEmpty &&
          summaryLines([
            unstable,
          ], tierLabel: 'Tier B').contains('Tier B: 0/0 clean (0%)'),
      'files=${unstable.files.length}',
    );
  } finally {
    tempDir.deleteSync(recursive: true);
  }

  final total = _passed + _failed;
  stdout.writeln('Results: $_passed passed, $_failed failed, $total total');
  if (total < 1) {
    stderr.writeln('ERROR: the self-test asserted nothing.');
    exit(1);
  }
  if (_failed > 0) exit(1);
}

bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
