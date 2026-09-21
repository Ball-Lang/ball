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
///  1. **The checkout is left byte-for-byte as it was found**, verified by
///     SHA-256 after every mode. A harness that leaves a checkout dirty
///     compounds substitutions across files and silently corrupts every later
///     verdict, so this is the first assertion, not an afterthought. Since
///     #653 it holds for a stronger reason than a careful restore: the harness
///     substitutes into a private COPY and never writes the checkout at all.
///  2. A file whose compiled-back Dart still passes the package's suite is
///     scored `clean` — the harness cannot pass by calling everything dirty.
///  3. **The load-bearing one.** A file carrying the #488 shape — a
///     `Set<T>.add(x)` whose `bool` result is returned — is measured through
///     the RECEIVER-TYPE-AWARE seam and scored `clean`, *while the
///     resolution-free `compileBack` still emits the broken cascade for the
///     very same source*. Both are asserted here, side by side, because the
///     pair is what proves the harness is wired to the code path under test.
///
///     This assertion INVERTED in #488 slice 2, and the inversion is the
///     point. Tier B originally called `DartEncoder().encode(source)` directly,
///     whose `parseString` AST leaves every `staticType` null — so every
///     receiver-type-aware branch in the encoder was structurally unreachable
///     from here and `registry.dart` scored `behavioral-drift` no matter what
///     the encoder did. Slice 1's fix for exactly this shape had already landed
///     on `main` and Tier B still reported the defect. The harness now runs one
///     `PackageEncoder.prepareStaticTypes()` + `encode()` per package, so the
///     fix is visible and the file is clean. A regression that un-wires the
///     seam turns this assertion red again.
///  4. A package whose UNMODIFIED suite does not pass 100% is reported
///     `baseline-unstable` and excluded from the denominator — never silently
///     defaulted to clean or dirty, which is how a flaky third-party suite
///     would otherwise manufacture (or mask) an encoder regression.
///  5. **Positive floor.** At least one file was scored, and a `Results:`-shaped
///     line was actually printed. An exit code plus a zero failure count cannot
///     distinguish "everything passed" from "nothing ran".
///  6. **PER-FILE ISOLATION (issue #653).** A package that contains ONE file
///     whose substitute breaks the build must not score its OTHER files red.
///     The negative control is a two-file scratch package where `lib/aa_*`'s
///     substitute does not compile and `lib/bb_*`'s substitute is BYTE-IDENTICAL
///     to its own source: `bb` cannot possibly change behaviour, so any verdict
///     other than `clean` is the instrument inventing a finding.
///
///     The load-bearing half is the WATCHER. `dart test` builds the whole
///     package, so a verdict is only about the substituted file if nothing else
///     in that checkout differs from the pristine tree while the suite runs —
///     and the checkout is an ordinary directory that a second Tier B process,
///     a diagnostic script or a re-clone can be walking at the same time. A
///     poller hashes every `lib/` file throughout the run and must never see a
///     single byte differ: the harness has to do its substituting somewhere it
///     owns, not in the tree it was pointed at. That is what produced 8 false
///     `behavioral-drift` rows on `collection` (12/23 where the same pin
///     measured 20/23 in CI, with no encoder or compiler change in between),
///     every one of them carrying a build error anchored in a DIFFERENT file
///     than the one it says it substituted.
///
///     Isolation makes this run harmless to others; it cannot make others
///     harmless to it, since the copy is taken FROM the shared checkout. So the
///     last two rows cover [verifyTreeUnchanged]: an unchanged tree passes, and
///     a tree that changed under the run FAILS LOUD rather than charging a
///     stranger's edit to the substituted file.
///  7. **THE YARDSTICK IS MEASURED THE SAME WAY (issue #705).** A package whose
///     suite depends on WHERE it runs must come back `baseline-unstable`, never
///     a package of `behavioral-drift`. The baseline used to run in the
///     pointed-at checkout while every candidate runs in a copy, so the
///     instrument manufactured one drift row per file for any path-sensitive
///     suite. The fixture asserts its own directory NAME — a full path would
///     also be sensitive to `/tmp` vs `/private/tmp` and would prove nothing.
///  8. **A LINK STOPS THE COPY (issue #705).** `_copyTree` skipped links on the
///     assertion that no pinned package ships one; an assertion is not a guard,
///     and a copy that quietly lost a path charges whatever it carried to the
///     substituted file. Not platform-gated: an unavailable link API FAILS this
///     check with a configuration message rather than skipping it.
///  9. **WHOLE MODE CHECKS THE TREE BEFORE COPYING (issue #705).** It has one
///     scored run and so no between-candidate window, but it has the window
///     between the baseline and the copy. The `afterBaseline` seam produces that
///     window deterministically instead of racing a timer against two real
///     `dart test` runs.
///
/// It also covers the whole-package mode (`rq1_tierb_all.dart`), whose stricter
/// signal is one verdict per package with no restore between files, and the
/// non-scoring `not-compiled` category (a directives-only facade library, which
/// never reaches Tier A stage 2 and so has nothing to substitute).
///
/// Run from the repo root:
///   dart run tools/coverage-study/test/rq1_tierb_self_test.dart
library;

import 'dart:async';
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

/// ── The issue-#653 negative control: a two-file scratch package ─────────────
///
/// `lib/aa_alpha.dart` sorts FIRST in `dartFilesUnder`'s order, so its
/// (deliberately unbuildable) substitute is the one that runs before `bb`'s.
const _isolationPubspec = '''
name: ball_tierb_isolation
publish_to: none
environment:
  sdk: ^3.9.0
dev_dependencies:
  test: any
''';

const _alphaSource = '''
class Alpha {
  int value() {
    return 1;
  }
}
''';

/// `aa_alpha.dart`'s substitute: it PARSES (so Tier A's stage-2 gate is not
/// what rejects it) and fails the CFE build the package's own `dart test`
/// performs — the same shape as the real
/// `Failed to build test:test: lib/src/list_extensions.dart:114:7: Error: …`.
const _alphaBrokenSubstitute = '''
class Alpha {
  int value() {
    return undefinedNameThatCannotPossiblyCompile;
  }
}
''';

const _betaSource = '''
class Beta {
  int value() {
    return 2;
  }
}
''';

const _isolationSuite = '''
import 'package:ball_tierb_isolation/aa_alpha.dart';
import 'package:ball_tierb_isolation/bb_beta.dart';
import 'package:test/test.dart';

void main() {
  test('alpha', () {
    expect(Alpha().value(), 1);
  });

  test('beta', () {
    expect(Beta().value(), 2);
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

    // ── The seam Tier B measures through ────────────────────────────────────
    // The resolution-free path is NOT going away: it is still what a checkout
    // with no `.dart_tool/package_config.json` falls back to, and it is exactly
    // what `dart/self_host/engine.ball.json` is generated with. Pin its
    // behaviour so a future change cannot quietly make the two paths identical
    // and leave this file asserting nothing.
    final syntaxOnly = compileBack(_registrySource) ?? '';
    check(
      'the resolution-free compileBack still emits the #488 cascade (the '
          'path a pub-get-less checkout falls back to is unchanged)',
      syntaxOnly.contains('seen..add(name)'),
      'compiled output was: $syntaxOnly',
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
      'THE LOAD-BEARING ONE: the #488-shaped file is measured through the '
      'receiver-type-aware seam and scored clean',
      registry.length == 1 && registry.single.scored && registry.single.clean,
      registry.isEmpty
          ? 'not reported'
          : 'reason was "${registry.single.reason}"',
    );

    // The verdict above could in principle go clean for the wrong reason (a
    // fallback that happened to work), so assert the seam itself produced the
    // receiver-type-aware text. `pubGet` has run by now, which is what
    // `prepareStaticTypes()` needs.
    final seam = await preparePackageCompileBack(tempDir);
    check(
      'the per-package receiver-type-aware context is actually built (a silent '
      'fallback to the resolution-free path would score by luck)',
      seam != null && seam.length >= 1,
      seam == null ? 'no context' : 'files=${seam.length}',
    );
    final seamRegistry = seam?['lib/registry.dart'] ?? '';
    check(
      'and it compiles Set<T>.add(x) as a plain call, not the cascade',
      seamRegistry.contains('return seen.add(name);') &&
          !seamRegistry.contains('seen..add(name)'),
      'compiled output was: $seamRegistry',
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
      'the whole package survives simultaneous substitution through the seam',
      whole.files.length == 1 && whole.files.single.clean,
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

  await _perFileIsolation();
  await _baselineIsMeasuredInTheSameKindOfCopy();
  await _copyRefusesSymlinks();
  await _wholeModeVerifiesTheTreeBeforeCopying();

  final total = _passed + _failed;
  stdout.writeln('Results: $_passed passed, $_failed failed, $total total');
  if (total < 1) {
    stderr.writeln('ERROR: the self-test asserted nothing.');
    exit(1);
  }
  if (_failed > 0) exit(1);
}

/// Issue #653: one broken file must not red the rest of its package.
///
/// The substitutions are INJECTED rather than encoded, for two reasons. A
/// negative control has to be unfalsifiable: `bb_beta.dart`'s substitute is the
/// byte-identical source, so it cannot change behaviour and `clean` is the only
/// honest verdict for it — no encoder or compiler change can ever make that
/// assertion pass or fail for the wrong reason. And `aa_alpha.dart`'s substitute
/// has to be reliably unbuildable, which is precisely what the pipeline tries
/// NOT to emit; manufacturing it through the real encoder would leave the
/// control hostage to the next encoder fix.
Future<void> _perFileIsolation() async {
  final dir = Directory.systemTemp.createTempSync('rq1_tierb_isolation');
  try {
    Directory('${dir.path}/lib').createSync(recursive: true);
    Directory('${dir.path}/test').createSync(recursive: true);
    File('${dir.path}/pubspec.yaml').writeAsStringSync(_isolationPubspec);
    File('${dir.path}/lib/aa_alpha.dart').writeAsStringSync(_alphaSource);
    File('${dir.path}/lib/bb_beta.dart').writeAsStringSync(_betaSource);
    File(
      '${dir.path}/test/isolation_test.dart',
    ).writeAsStringSync(_isolationSuite);

    final substitutions = PackageCompileBack({
      'lib/aa_alpha.dart': _alphaBrokenSubstitute,
      'lib/bb_beta.dart': _betaSource,
    }, const []);

    // A second pair of eyes on the checkout for the whole run. Anything that
    // ever differs from the pristine tree while a verdict is being taken is,
    // by construction, attributable to the wrong file.
    final libRoot = Directory('${dir.path}/lib');
    final pristine = _digests(libRoot);
    final seenDifferent = <String>{};
    final watcher = Timer.periodic(const Duration(milliseconds: 25), (_) {
      for (final file in dartFilesUnder(libRoot)) {
        try {
          if (digestOf(file.readAsBytesSync()) != pristine[file.path]) {
            seenDifferent.add(file.path);
          }
        } catch (_) {
          // Unreadable mid-write is a difference too.
          seenDifferent.add(file.path);
        }
      }
    });

    final TierBPackageResult run;
    try {
      run = await studyPackagePerFile(
        'isolation',
        dir,
        substitutions: substitutions,
      );
    } finally {
      watcher.cancel();
    }

    check(
      'ISSUE #653: the pristine checkout is never modified while it is being '
          'scored — a concurrent reader of that directory sees every lib/ file '
          'byte-identical for the whole run',
      seenDifferent.isEmpty,
      'these files differed from the pristine tree during the run: '
          '${seenDifferent.map((p) => p.split(Platform.pathSeparator).last).toList()}',
    );

    check(
      'the two-file isolation package has a healthy baseline and is scored',
      run.status == 'scored',
      'status was "${run.status}"',
    );

    final alpha = run.files.where((f) => f.file == 'aa_alpha.dart').toList();
    check(
      'the file whose substitute does not build is scored behavioral-drift '
      '(the instrument still reports the TRUE red)',
      alpha.length == 1 && alpha.single.scored && !alpha.single.clean,
      alpha.isEmpty ? 'not reported' : 'reason was "${alpha.single.reason}"',
    );

    final beta = run.files.where((f) => f.file == 'bb_beta.dart').toList();
    check(
      'ISSUE #653: the neighbour whose substitute is BYTE-IDENTICAL to its own '
      'source is scored clean — one broken file cannot red the rest of its '
      'package',
      beta.length == 1 && beta.single.clean,
      beta.isEmpty ? 'not reported' : 'reason was "${beta.single.reason}"',
    );

    // The other half of the same leak: `dart test` persists its incremental
    // kernel under the CHECKOUT's `.dart_tool/`, so a substitution can outlive
    // the harness process itself and poison the very first file of the next
    // run — which is how files sorting BEFORE `list_extensions.dart` came back
    // red with an error anchored in it. The untouched checkout is the yardstick
    // every later verdict is compared against, so prove it is still healthy.
    final afterwards = await runDartTest(
      dir,
      timeout: const Duration(minutes: 5),
    );
    check(
      'ISSUE #653: the UNTOUCHED checkout still builds and passes after the '
          'run — no substitution survived into the next invocation',
      afterwards.healthy,
      'outcome was $afterwards — ${afterwards.detail}',
    );

    // Isolation makes this run harmless to others; it cannot make others
    // harmless to it, because the copy is taken FROM the shared checkout. When
    // a stranger does change the tree, the only honest answer is to stop: the
    // baseline no longer describes what is being scored.
    final snapshot = snapshotTree(libRoot);
    check(
      'an unchanged checkout passes the between-candidate integrity check',
      () {
        try {
          verifyTreeUnchanged(libRoot, snapshot, package: 'isolation');
          return true;
        } catch (_) {
          return false;
        }
      }(),
    );

    final betaFile = File('${dir.path}/lib/bb_beta.dart');
    final betaBytes = betaFile.readAsBytesSync();
    betaFile.writeAsStringSync('class Beta { int value() => 3; }\n');
    var threw = false;
    try {
      verifyTreeUnchanged(libRoot, snapshot, package: 'isolation');
    } on StateError {
      threw = true;
    } finally {
      betaFile.writeAsBytesSync(betaBytes, flush: true);
    }
    check(
      'ISSUE #653: a checkout that changed under the run FAILS LOUD instead of '
          'scoring — a stranger\'s edit is never charged to the substituted file',
      threw,
      'verifyTreeUnchanged accepted a modified tree',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Issue #705, advisory 1 on PR #668: the yardstick and the thing measured
/// against it must be measured the SAME WAY.
///
/// The baseline used to run `dart test` in the checkout the harness was pointed
/// at, while every candidate runs it in a temp copy. Any suite whose result
/// depends on WHERE it runs — a test asserting a path, reading a fixture by
/// absolute path, or keyed on its own directory name — therefore passed for the
/// baseline and failed for every candidate, and the harness charged that
/// difference to the encoder: a whole package of `behavioral-drift` produced by
/// the instrument, one row per file.
///
/// The honest answer is not "make the copy look like the checkout" — it is to
/// measure the baseline in the same kind of copy, so a path-sensitive suite
/// fails the baseline and the package is excluded as `baseline-unstable`, which
/// is exactly what the taxonomy already says about a suite that cannot be a
/// yardstick.
///
/// The fixture asserts its own directory NAME rather than a full path: a full
/// path comparison would also be sensitive to `/tmp` vs `/private/tmp` symlink
/// resolution and tell us nothing about the property under test.
Future<void> _baselineIsMeasuredInTheSameKindOfCopy() async {
  final dir = Directory.systemTemp.createTempSync('rq1_tierb_pathsensitive');
  try {
    final checkoutName = dir.path.split(Platform.pathSeparator).last;
    Directory('${dir.path}/lib').createSync(recursive: true);
    Directory('${dir.path}/test').createSync(recursive: true);
    File('${dir.path}/pubspec.yaml').writeAsStringSync('''
name: ball_tierb_pathsensitive
publish_to: none
environment:
  sdk: ^3.9.0
dev_dependencies:
  test: any
''');
    File('${dir.path}/lib/sensitive.dart').writeAsStringSync('''
class Sensitive {
  int twice(int value) {
    return value * 2;
  }
}
''');
    File('${dir.path}/test/path_test.dart').writeAsStringSync('''
import 'dart:io';

import 'package:ball_tierb_pathsensitive/sensitive.dart';
import 'package:test/test.dart';

void main() {
  test('doubles', () {
    expect(Sensitive().twice(21), 42);
  });

  test('runs in the directory it was written for', () {
    expect(
      Directory.current.path.split(Platform.pathSeparator).last,
      '$checkoutName',
    );
  });
}
''');

    final run = await studyPackagePerFile('pathsensitive', dir);

    check(
      'ISSUE #705: a package whose suite depends on WHERE it runs is excluded '
          'as baseline-unstable — the baseline is measured in the same kind of '
          'copy as every candidate, so the harness cannot manufacture drift out '
          'of its own temp directory',
      run.status.startsWith('baseline-unstable'),
      'status was "${run.status}", files=${[for (final f in run.files) '${f.file}: ${f.reason}']}',
    );
    check(
      'and not one of its files is scored behavioral-drift',
      run.files.every((f) => f.tag != 'behavioral-drift'),
      'drifted: ${[for (final f in run.files)
        if (f.tag == 'behavioral-drift') '${f.file}: ${f.reason}']}',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Issue #705, advisory 2 on PR #668: `_copyTree` skipped links on the
/// ASSERTION that no pinned package ships one. An assertion is not a guard.
///
/// A checkout containing a link is copied without it, the copy is silently
/// incomplete, and whatever the missing path carried is charged to the file the
/// harness believes it substituted — the #653 failure again, one layer down and
/// with nothing left to notice it. Following the link instead is not the fix
/// either: it would copy whatever lies outside the checkout. So the only honest
/// answer is to refuse, by name.
///
/// Deliberately NOT platform-gated. Creating a link needs privilege on Windows
/// (Developer Mode or an elevated shell) and the Dart CI job runs on
/// `ubuntu-latest`; a self-test that quietly opts out on one platform is a fake
/// green, so an unavailable link API fails this check with a configuration
/// message instead of skipping it.
Future<void> _copyRefusesSymlinks() async {
  final dir = Directory.systemTemp.createTempSync('rq1_tierb_symlink');
  try {
    Directory('${dir.path}/lib').createSync(recursive: true);
    File('${dir.path}/lib/real.dart').writeAsStringSync('const answer = 42;\n');

    final link = Link('${dir.path}/lib/aliased.dart');
    var created = true;
    try {
      link.createSync('${dir.path}/lib/real.dart');
    } on FileSystemException catch (e) {
      created = false;
      check(
        'the self-test can create a link (Windows needs symlink-creation '
            'privilege: enable Developer Mode, or run elevated)',
        false,
        '$e',
      );
    }

    if (created) {
      var thrown = '';
      try {
        await withSubstitutedCopy(
          dir,
          const <String, String>{},
          (workspace) async => workspace.path,
        );
      } catch (e) {
        thrown = e.toString();
      }
      check(
        'ISSUE #705: a checkout containing a link FAILS LOUD instead of being '
        'copied without it — a silently incomplete copy charges whatever '
        'the missing path carried to the substituted file',
        thrown.contains('aliased.dart'),
        thrown.isEmpty
            ? 'the copy succeeded and dropped the link on the floor'
            : 'threw, but without naming the link: $thrown',
      );
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Issue #705, advisory 2 on PR #668: whole-package mode took its copy with no
/// [verifyTreeUnchanged] guard, the one per-file mode applies before every
/// candidate.
///
/// Whole mode takes exactly one copy, so there is no BETWEEN-candidate window —
/// which is the reason the guard was left out. But the window that matters is
/// the one between the BASELINE and the copy, and whole mode has it too: the
/// baseline is what the single verdict is compared against, and if the tree
/// changed after it was measured then the copy is not the tree the baseline
/// describes. One verdict built on that is exactly as wrong as a hundred.
///
/// The window is produced deterministically through the `afterBaseline` seam
/// rather than by racing a timer against two real `dart test` runs.
Future<void> _wholeModeVerifiesTheTreeBeforeCopying() async {
  final dir = Directory.systemTemp.createTempSync('rq1_tierb_wholeguard');
  try {
    Directory('${dir.path}/lib').createSync(recursive: true);
    Directory('${dir.path}/test').createSync(recursive: true);
    File('${dir.path}/pubspec.yaml').writeAsStringSync(_isolationPubspec);
    File('${dir.path}/lib/aa_alpha.dart').writeAsStringSync(_alphaSource);
    File('${dir.path}/lib/bb_beta.dart').writeAsStringSync(_betaSource);
    File(
      '${dir.path}/test/isolation_test.dart',
    ).writeAsStringSync(_isolationSuite);

    final stranger = File('${dir.path}/lib/bb_beta.dart');
    var thrown = '';
    try {
      await studyPackageWhole(
        'wholeguard',
        dir,
        afterBaseline: () async {
          // A second Tier B process, a diagnostic script or a re-clone, in the
          // window between the baseline and the copy.
          stranger.writeAsStringSync('class Beta { int value() => 3; }\n');
        },
      );
    } on StateError catch (e) {
      thrown = e.message;
    }

    check(
      'ISSUE #705: whole-package mode verifies the tree against the baseline '
      'snapshot BEFORE copying — a checkout that changed under the run '
      'fails loud instead of producing one verdict the baseline no longer '
      'describes',
      thrown.contains('bb_beta.dart'),
      thrown.isEmpty
          ? 'studyPackageWhole scored a tree that changed after its baseline'
          : 'threw, but without naming the changed file: $thrown',
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
