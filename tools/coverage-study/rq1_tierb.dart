/// Tier B of the third-party coverage study (issue #493) — **per-file**
/// behavioural substitution.
///
/// Tier A (`rq1_study.dart`) is a *structural* measure: encode → compile back →
/// re-encode → declaration inventory → second-generation fixpoint. By its own
/// documented design it cannot see a construct that round-trips syntactically
/// clean but changes what the program computes. The canonical case is #488:
///
/// ```dart
/// bool remember(String name) {
///   return seen.add(name);      // Set<String>.add returns bool
/// }
/// ```
///
/// The encoder dispatches the method call on its NAME alone, mis-routes it into
/// a cascade-shaped IR node, and `DartCompiler.compileModule` faithfully lowers
/// that to `return seen..add(name);` — which parses, keeps every declaration and
/// reaches the stage-5 fixpoint, so Tier A scores the file **clean**, while the
/// `bool` every caller depends on has silently become a `Set<String>`. Tier A
/// stayed at 61% clean across two full baselines while #488 sat open.
///
/// Tier B is the instrument that sees it. For every library file a package
/// ships, it swaps the file for the pipeline's own compiled-back version, runs
/// **that package's own `dart test`**, and compares the result against a
/// baseline run of the untouched checkout. A construct that changes behaviour
/// shows up as a test that stops passing.
///
/// THE TAXONOMY IS THE POINT (mirrors `rq1_study.dart`'s
/// `encode-error`/`fixpoint-drift`/`skipped` split):
///
///  * `clean` — substituted, the suite still passes exactly as it did.
///  * `behavioral-drift` — substituted, the suite regressed. SCORED, not clean.
///  * `not-compiled` — the file never reached Tier A stage 2 (the encoder
///    refused it, or the compiler could not emit parseable Dart), so there was
///    nothing to substitute. NOT scored: it is a Tier A finding, and counting
///    it here would double-count the same defect.
///  * `test-timeout` — the suite did not finish inside the bound. NOT scored: a
///    hang is inconclusive, never a verdict.
///  * `baseline-unstable` — the package's UNMODIFIED suite is not a usable
///    yardstick: `dart pub get` failed, it has no tests, it does not pass 100%,
///    or two consecutive runs of the untouched checkout disagree. Every file of
///    that package is excluded from the denominator. A flaky or
///    network-touching third-party suite would otherwise manufacture drift one
///    file at a time and charge it to the encoder.
///
/// `test-timeout` and `baseline-unstable` deliberately stay OUT of the drift
/// count rather than being folded into it — a flaky third-party suite must
/// never read as an encoder regression, which is the same rule Tier A applies
/// to an unreachable pin.
///
/// RESTORATION INTEGRITY is the harness's first obligation. A run that leaves a
/// checkout dirty compounds substitutions across files and silently corrupts
/// every later verdict, so the original bytes are snapshotted before the write,
/// restored in a `finally`, and the restored file's SHA-256 is compared against
/// the snapshot's. A mismatch throws — it is never reported as a verdict.
///
/// Usage (from the repo root):
///
///   dart run tools/coverage-study/rq1_tierb.dart \
///       --pins tools/coverage-study/packages/dart.json \
///       --checkouts <dir-with-one-clone-per-package> \
///       [--json <report.json>] [--jobs 2] [--test-timeout 300]
///
///   dart run tools/coverage-study/rq1_tierb.dart \
///       --package <name> --checkout <package-root> [--json <report.json>]
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart' show Module;
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:crypto/crypto.dart' show sha256;

import 'rq1_study.dart' show stageReached, studyFile;

/// Every non-scoring and scoring taxonomy tag Tier B can emit. An unknown tag
/// must never reach the summary — [summaryLines] throws on one, for the same
/// reason Tier A's funnel throws: a new failure mode silently folded into the
/// wrong row is worse than no measurement.
const tierBTags = <String>{
  'clean',
  'behavioral-drift',
  'not-compiled',
  'test-timeout',
  'baseline-unstable',
};

/// Tags that count toward the Tier B denominator. `not-compiled` is a Tier A
/// finding, `test-timeout` is inconclusive and `baseline-unstable` is a
/// property of the third-party suite, not of the pipeline.
const scoredTierBTags = <String>{'clean', 'behavioral-drift'};

/// One substituted file's verdict.
class TierBFileResult {
  TierBFileResult(this.package, this.file, this.reason);

  final String package;
  final String file;

  /// Taxonomy tag plus detail, e.g. `behavioral-drift: 12 → 9 passing`.
  final String reason;

  String get tag => reason.split(':').first;

  /// Counted in the Tier B denominator.
  bool get scored => scoredTierBTags.contains(tag);

  /// Substituted and the package's own suite still passed unchanged.
  bool get clean => tag == 'clean';

  Map<String, Object?> toJson() => {
    'package': package,
    'file': file,
    'scored': scored,
    'clean': clean,
    'reason': reason,
  };
}

/// One package's Tier B run.
class TierBPackageResult {
  TierBPackageResult(this.package, this.status, this.files);

  final String package;

  /// `scored` when the baseline was healthy and files were substituted;
  /// otherwise the `baseline-unstable: …` reason that excluded the package.
  final String status;

  final List<TierBFileResult> files;

  Map<String, Object?> toJson() => {
    'package': package,
    'status': status,
    'files': [for (final f in files) f.toJson()],
  };
}

/// The outcome of one `dart test` invocation.
class TestRunOutcome {
  TestRunOutcome({
    required this.passed,
    required this.failed,
    required this.succeeded,
    required this.timedOut,
    this.detail = '',
  });

  /// Visible, non-skipped tests that passed.
  final int passed;

  /// Visible tests that failed or errored — a suite that fails to COMPILE
  /// reports its `loading <path>` pseudo-test as a visible error, which is
  /// exactly how the #488 shape surfaces.
  final int failed;

  /// The runner's own `done.success` verdict.
  final bool succeeded;

  final bool timedOut;

  final String detail;

  bool get healthy => succeeded && !timedOut && failed == 0 && passed >= 1;

  @override
  String toString() =>
      'passed=$passed failed=$failed success=$succeeded timedOut=$timedOut';
}

/// Module names the encoder synthesizes for std base functions; they carry no
/// user code and are not compiled back. Mirrors `rq1_study.dart`.
bool _isGeneratedStdModule(Module module) {
  if (!module.name.startsWith('std')) return false;
  return module.functions.every((f) => f.isBase);
}

/// The pipeline's own compiled-back Dart for [source], or `null` when there is
/// nothing to substitute.
///
/// Deliberately the SAME two load-bearing settings Tier A documents: per-module
/// `compileModule` (real library files have no entry point, and `compile()`
/// falls back to unformatted output when the formatter throws, turning
/// "emitted Dart that does not parse" into a pass) and format-before-use.
String? compileBack(String source) {
  final program = DartEncoder().encode(source, name: 'main');
  final compiler = DartCompiler(program);
  final buffer = StringBuffer();
  for (final module in program.modules) {
    if (_isGeneratedStdModule(module)) continue;
    buffer.writeln(compiler.compileModule(module.name));
  }
  final compiled = buffer.toString();
  return compiled.trim().isEmpty ? null : compiled;
}

String _firstLine(Object error) {
  final text = error.toString().replaceAll('\r', '');
  final cut = text.indexOf('\n');
  final line = cut == -1 ? text : text.substring(0, cut);
  return line.length > 160 ? '${line.substring(0, 160)}…' : line;
}

/// SHA-256 of [bytes], the restoration-integrity check's currency.
String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

/// Runs [executable] in [dir], killing it after [timeout].
///
/// Returns `null` for stdout when the process was killed — a timed-out run has
/// no verdict, only a timeout.
Future<({int? exitCode, String stdout, bool timedOut})> _run(
  String executable,
  List<String> arguments,
  Directory dir,
  Duration timeout,
) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: dir.path,
  );
  const decoder = Utf8Decoder(allowMalformed: true);
  final out = StringBuffer();
  final stdoutDone = process.stdout
      .transform(decoder)
      .listen(out.write)
      .asFuture<void>();
  final stderrDone = process.stderr
      .transform(decoder)
      .listen(out.write)
      .asFuture<void>();
  int? code;
  var timedOut = false;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
    // Reap the killed process so its pipes close and the drains below finish.
    await process.exitCode;
  }
  await stdoutDone;
  await stderrDone;
  return (exitCode: code, stdout: out.toString(), timedOut: timedOut);
}

/// The Dart binary running this harness — never a bare `dart` on `PATH`, so a
/// second SDK on the machine cannot silently change what is measured.
String get dartExecutable => Platform.resolvedExecutable;

/// Resolves [dir]'s dependencies.
///
/// `--offline` first: every pin's dev-dependencies are ordinary hosted packages
/// the workspace resolution already put in the pub cache, so the common case
/// needs no network at all. A pin that genuinely needs a fetch falls back to an
/// online resolve rather than being written off.
Future<({bool ok, String detail})> pubGet(
  Directory dir, {
  required Duration timeout,
}) async {
  for (final offline in [true, false]) {
    final result = await _run(
      dartExecutable,
      ['pub', 'get', if (offline) '--offline'],
      dir,
      timeout,
    );
    if (result.timedOut) {
      return (
        ok: false,
        detail: 'dart pub get timed out after ${timeout.inSeconds}s',
      );
    }
    if (result.exitCode == 0) return (ok: true, detail: '');
  }
  return (ok: false, detail: 'dart pub get could not resolve the checkout');
}

/// Counts of a `dart test --reporter=json` stream.
///
/// The JSON reporter is used rather than the human summary line on purpose: a
/// suite that fails to COMPILE prints no `+N -M` tally at all, and scraping the
/// human output would silently score that as "0 failures".
TestRunOutcome parseDartTestJson(String output, {required bool timedOut}) {
  var passed = 0;
  var failed = 0;
  bool? success;
  final failures = <String>[];
  final names = <int, String>{};
  // A package that fails to BUILD never reaches the JSON protocol at all:
  // `dart test` prints a plain `Failed to build test:test: …` and exits 65 with
  // zero events. Keeping those lines is what turns an otherwise mute
  // `0 passing, 0 failing` verdict into an actionable one.
  final plain = <String>[];
  for (final line in const LineSplitter().convert(output)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
      if (trimmed.isNotEmpty && plain.length < 2) plain.add(trimmed);
      continue;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    switch (decoded['type']) {
      case 'testStart':
        final test = decoded['test'];
        if (test is Map<String, Object?>) {
          final id = test['id'];
          final name = test['name'];
          if (id is int && name is String) names[id] = name;
        }
      case 'testDone':
        if (decoded['hidden'] == true) continue;
        if (decoded['skipped'] == true) continue;
        if (decoded['result'] == 'success') {
          passed++;
        } else {
          failed++;
          final id = decoded['testID'];
          if (id is int && failures.length < 3) {
            failures.add(names[id] ?? 'test #$id');
          }
        }
      case 'done':
        success = decoded['success'] == true;
    }
  }
  final detail = failures.isNotEmpty
      ? failures.join(', ')
      : (passed == 0 && failed == 0 ? plain.join(' ') : '');
  return TestRunOutcome(
    passed: passed,
    failed: failed,
    // No `done` event means the runner itself died; that is never a pass.
    succeeded: success ?? false,
    timedOut: timedOut,
    detail: detail.length > 200 ? '${detail.substring(0, 200)}…' : detail,
  );
}

/// Runs the package's own suite in [dir].
///
/// `--concurrency=1` is NOT a performance knob, it is a correctness one.
/// `dart test` runs VM suites as isolates inside ONE process, so a suite that
/// mutates process-global state makes an UNRELATED suite flaky. dart-lang/path
/// — a pin this study measures — sets `io.Directory.current` in
/// `test/io_test.dart`, and path equality reads it. Run unserialized, this
/// harness reported `503 → 502 passing, 1 failing` for `src/path_exception.dart`,
/// `src/utils.dart` and `src/path_map.dart`, every failure a `path_map`/
/// `path_set` equality test ("considers unequal two distinct paths") — six
/// invented encoder regressions, charged to files that cannot affect path
/// equality at all. With `--concurrency=1` those same six score `clean` and only
/// the four genuine drifts remain. An instrument that manufactures its own
/// findings is worse than no instrument.
Future<TestRunOutcome> runDartTest(
  Directory dir, {
  required Duration timeout,
}) async {
  final result = await _run(
    dartExecutable,
    ['test', '--reporter=json', '--concurrency=1'],
    dir,
    timeout,
  );
  return parseDartTestJson(result.stdout, timedOut: result.timedOut);
}

/// Every `.dart` file under [dir], sorted, so a run is reproducible.
List<File> dartFilesUnder(Directory dir) =>
    dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

String _relative(File file, Directory root) => file.path
    .substring(root.path.length)
    .replaceAll('\\', '/')
    .replaceFirst(RegExp(r'^/'), '');

/// A file that is eligible for substitution, paired with its compiled-back
/// text, or the `not-compiled` reason it is not.
class _Candidate {
  _Candidate.substitutable(this.file, this.rel, this.compiled) : reason = null;
  _Candidate.excluded(this.file, this.rel, String this.reason)
    : compiled = null;

  final File file;
  final String rel;
  final String? compiled;
  final String? reason;
}

/// Decides, for one file, whether Tier B has anything to substitute.
///
/// The gate is Tier A's OWN stage-2 verdict, not a re-implementation of it: a
/// file the encoder refused or the compiler could not emit parseable Dart for
/// is already counted as a Tier A failure, and scoring it again here would
/// double-count one defect across two tiers.
_Candidate _candidate(File file, Directory libRoot) {
  final rel = _relative(file, libRoot);
  final String source;
  try {
    source = file.readAsStringSync();
  } catch (e) {
    return _Candidate.excluded(
      file,
      rel,
      'not-compiled: read-error: ${_firstLine(e)}',
    );
  }
  final tierA = studyFile('tier-b', rel, source);
  if (!tierA.scored) {
    return _Candidate.excluded(file, rel, 'not-compiled: ${tierA.reason}');
  }
  if (stageReached(tierA.reason) < 2) {
    return _Candidate.excluded(file, rel, 'not-compiled: ${tierA.reason}');
  }
  final String? compiled;
  try {
    compiled = compileBack(source);
  } catch (e) {
    return _Candidate.excluded(
      file,
      rel,
      'not-compiled: compile-error: ${_firstLine(e)}',
    );
  }
  if (compiled == null) {
    return _Candidate.excluded(
      file,
      rel,
      'not-compiled: the file compiles to nothing (no user module)',
    );
  }
  return _Candidate.substitutable(file, rel, compiled);
}

/// Overwrites [file] with [replacement], runs [body], then restores the exact
/// original bytes and PROVES the restoration by digest.
///
/// The digest check is not defensive decoration: a silent restore failure turns
/// every subsequent verdict in the same checkout into a lie, so it throws
/// rather than reporting a tag.
Future<T> withSubstitutedFile<T>(
  File file,
  String replacement,
  Future<T> Function() body,
) async {
  final original = file.readAsBytesSync();
  final originalDigest = digestOf(original);
  try {
    file.writeAsStringSync(replacement, flush: true);
    return await body();
  } finally {
    file.writeAsBytesSync(original, flush: true);
    final restoredDigest = digestOf(file.readAsBytesSync());
    if (restoredDigest != originalDigest) {
      throw StateError(
        'restoration failed for ${file.path}: $restoredDigest != '
        '$originalDigest — every later verdict in this checkout would be '
        'compounded on a dirty tree',
      );
    }
  }
}

/// The options every Tier B run shares.
class TierBOptions {
  const TierBOptions({
    this.libSubdir = 'lib',
    this.testTimeout = const Duration(minutes: 5),
    this.pubTimeout = const Duration(minutes: 10),
    this.maxFilesPerPackage = 0,
  });

  final String libSubdir;
  final Duration testTimeout;
  final Duration pubTimeout;

  /// 0 means "no cap". A cap keeps a scheduled run bounded on a package with
  /// hundreds of files; it changes the denominator, never a verdict.
  final int maxFilesPerPackage;
}

/// Prepares [checkout] and runs its untouched suite.
///
/// Returns the `baseline-unstable: …` reason when the package cannot be a
/// yardstick, or `null` when the baseline is healthy.
Future<({String? unstable, TestRunOutcome baseline})> establishBaseline(
  Directory checkout,
  TierBOptions options,
) async {
  final resolved = await pubGet(checkout, timeout: options.pubTimeout);
  if (!resolved.ok) {
    return (
      unstable: 'baseline-unstable: ${resolved.detail}',
      baseline: TestRunOutcome(
        passed: 0,
        failed: 0,
        succeeded: false,
        timedOut: false,
      ),
    );
  }
  final baseline = await runDartTest(checkout, timeout: options.testTimeout);
  if (baseline.timedOut) {
    return (
      unstable:
          'baseline-unstable: the unmodified suite timed out after '
          '${options.testTimeout.inSeconds}s',
      baseline: baseline,
    );
  }
  if (!baseline.healthy) {
    return (
      unstable:
          'baseline-unstable: the unmodified suite is ${baseline.passed} '
          'passing / ${baseline.failed} failing',
      baseline: baseline,
    );
  }
  // A yardstick has to be REPRODUCIBLE, not merely green once. A suite that
  // returns two different tallies on the same untouched checkout cannot tell a
  // pipeline regression from its own noise, so it is excluded here rather than
  // charging its flakiness to the encoder one file at a time.
  final confirm = await runDartTest(checkout, timeout: options.testTimeout);
  if (confirm.passed != baseline.passed || confirm.failed != baseline.failed) {
    return (
      unstable:
          'baseline-unstable: the unmodified suite is not deterministic — '
          '${baseline.passed}/${baseline.failed} then '
          '${confirm.passed}/${confirm.failed} passing/failing',
      baseline: baseline,
    );
  }
  return (unstable: null, baseline: baseline);
}

/// Classifies one substituted run against [baseline].
String classify(
  TestRunOutcome baseline,
  TestRunOutcome after,
  Duration testTimeout,
) {
  if (after.timedOut) {
    return 'test-timeout: the substituted suite did not finish in '
        '${testTimeout.inSeconds}s';
  }
  if (after.passed < baseline.passed ||
      after.failed > baseline.failed ||
      !after.succeeded) {
    final detail = after.detail.isEmpty ? '' : ' — ${after.detail}';
    return 'behavioral-drift: ${baseline.passed} → ${after.passed} passing, '
        '${after.failed} failing$detail';
  }
  return 'clean';
}

/// Tier B, per-file isolation: substitute ONE file, run the suite, restore,
/// move on. Never compounds two substitutions.
Future<TierBPackageResult> studyPackagePerFile(
  String package,
  Directory checkout, {
  TierBOptions options = const TierBOptions(),
}) async {
  final libRoot = Directory('${checkout.path}/${options.libSubdir}');
  if (!libRoot.existsSync()) {
    return TierBPackageResult(
      package,
      'baseline-unstable: no ${options.libSubdir}/ directory in the checkout',
      const [],
    );
  }

  final (:unstable, :baseline) = await establishBaseline(checkout, options);
  if (unstable != null) return TierBPackageResult(package, unstable, const []);

  var candidates = [
    for (final file in dartFilesUnder(libRoot)) _candidate(file, libRoot),
  ];
  if (options.maxFilesPerPackage > 0) {
    candidates = candidates.take(options.maxFilesPerPackage).toList();
  }

  final results = <TierBFileResult>[];
  for (final candidate in candidates) {
    final excluded = candidate.reason;
    if (excluded != null) {
      results.add(TierBFileResult(package, candidate.rel, excluded));
      continue;
    }
    final after = await withSubstitutedFile(
      candidate.file,
      candidate.compiled!,
      () => runDartTest(checkout, timeout: options.testTimeout),
    );
    results.add(
      TierBFileResult(
        package,
        candidate.rel,
        classify(baseline, after, options.testTimeout),
      ),
    );
  }
  return TierBPackageResult(package, 'scored', results);
}

/// Tier B, whole-package: substitute EVERY eligible file at once, run the suite
/// once, restore everything. The stricter signal — a package is clean only when
/// its entire library survives the round trip simultaneously.
Future<TierBPackageResult> studyPackageWhole(
  String package,
  Directory checkout, {
  TierBOptions options = const TierBOptions(),
}) async {
  final libRoot = Directory('${checkout.path}/${options.libSubdir}');
  if (!libRoot.existsSync()) {
    return TierBPackageResult(
      package,
      'baseline-unstable: no ${options.libSubdir}/ directory in the checkout',
      const [],
    );
  }

  final (:unstable, :baseline) = await establishBaseline(checkout, options);
  if (unstable != null) return TierBPackageResult(package, unstable, const []);

  var candidates = [
    for (final file in dartFilesUnder(libRoot)) _candidate(file, libRoot),
  ];
  if (options.maxFilesPerPackage > 0) {
    candidates = candidates.take(options.maxFilesPerPackage).toList();
  }
  final substitutable = candidates.where((c) => c.reason == null).toList();
  if (substitutable.isEmpty) {
    return TierBPackageResult(
      package,
      'baseline-unstable: no file of this package reached Tier A stage 2, so '
      'there was nothing to substitute',
      const [],
    );
  }

  final originals = <File, List<int>>{};
  final digests = <File, String>{};
  String? reason;
  try {
    for (final candidate in substitutable) {
      final bytes = candidate.file.readAsBytesSync();
      originals[candidate.file] = bytes;
      digests[candidate.file] = digestOf(bytes);
      candidate.file.writeAsStringSync(candidate.compiled!, flush: true);
    }
    final after = await runDartTest(checkout, timeout: options.testTimeout);
    reason = classify(baseline, after, options.testTimeout);
  } finally {
    for (final entry in originals.entries) {
      entry.key.writeAsBytesSync(entry.value, flush: true);
      final restored = digestOf(entry.key.readAsBytesSync());
      if (restored != digests[entry.key]) {
        throw StateError(
          'restoration failed for ${entry.key.path} — the checkout is now '
          'dirty and every later verdict would be compounded on it',
        );
      }
    }
  }

  return TierBPackageResult(package, 'scored', [
    TierBFileResult(
      package,
      '<whole package: ${substitutable.length} file(s)>',
      reason,
    ),
  ]);
}

/// The report lines for a completed run, in print order.
///
/// Returned rather than printed so the self-test can assert on them — an exit
/// code plus a zero failure count cannot tell "everything passed" from
/// "nothing ran".
List<String> summaryLines(
  List<TierBPackageResult> packages, {
  required String tierLabel,
}) {
  final files = [for (final p in packages) ...p.files];
  for (final file in files) {
    if (!tierBTags.contains(file.tag)) {
      throw StateError(
        'unknown Tier B taxonomy tag "${file.tag}" — the summary would '
        'silently lie',
      );
    }
  }
  final scored = files.where((f) => f.scored).toList();
  final clean = scored.where((f) => f.clean).length;
  final total = scored.length;

  final byTag = <String, int>{};
  for (final file in files) {
    byTag[file.tag] = (byTag[file.tag] ?? 0) + 1;
  }

  final lines = <String>[];
  for (final entry
      in (byTag.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))) {
    final suffix = scoredTierBTags.contains(entry.key) ? '' : ' (not scored)';
    lines.add('  ${entry.key}: ${entry.value}$suffix');
  }
  final excluded = packages.where((p) => p.status != 'scored').toList();
  for (final package in excluded) {
    lines.add('  ${package.package}: ${package.status}');
  }
  final pct = total == 0 ? 0 : (clean * 100 / total).round();
  lines.add('$tierLabel: $clean/$total clean ($pct%)');
  lines.add('Results: $clean passed, ${total - clean} failed, $total total');
  return lines;
}

String? argOf(List<String> args, String name) {
  final i = args.indexOf('--$name');
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}

/// Reads the pin list Tier A already uses.
List<({String name, String lib})> readPins(String pinsPath) {
  final pins =
      (jsonDecode(File(pinsPath).readAsStringSync())
              as Map<String, Object?>)['packages']
          as List<Object?>;
  return [
    for (final raw in pins)
      (
        name: (raw as Map<String, Object?>)['name'] as String,
        lib: (raw['lib'] as String?) ?? 'lib',
      ),
  ];
}

/// Runs [study] over every package, at most [jobs] packages at a time.
///
/// Packages are independent checkouts, so they parallelize safely; files within
/// one package never do — two substitutions live in the same working tree.
Future<List<TierBPackageResult>> runPackages(
  List<Future<TierBPackageResult> Function()> study, {
  required int jobs,
}) async {
  final results = List<TierBPackageResult?>.filled(study.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= study.length) return;
      results[index] = await study[index]();
    }
  }

  await Future.wait([
    for (var i = 0; i < jobs.clamp(1, study.length.clamp(1, 64)); i++) worker(),
  ]);
  return [for (final r in results) r!];
}

/// The shared entry point for both modes.
Future<void> runTierB(
  List<String> args, {
  required String tierLabel,
  required Future<TierBPackageResult> Function(
    String package,
    Directory checkout,
    TierBOptions options,
  )
  study,
}) async {
  final options = TierBOptions(
    testTimeout: Duration(
      seconds: int.parse(argOf(args, 'test-timeout') ?? '300'),
    ),
    pubTimeout: Duration(
      seconds: int.parse(argOf(args, 'pub-timeout') ?? '600'),
    ),
    maxFilesPerPackage: int.parse(argOf(args, 'max-files') ?? '0'),
  );
  final jobs = int.parse(argOf(args, 'jobs') ?? '2');

  final pinsPath = argOf(args, 'pins');
  final packageName = argOf(args, 'package');
  final checkoutPath = argOf(args, 'checkout');

  final tasks = <Future<TierBPackageResult> Function()>[];
  final missingPins = <String>[];

  if (pinsPath != null) {
    final checkouts = argOf(args, 'checkouts');
    if (checkouts == null) {
      stderr.writeln('--pins requires --checkouts <dir>');
      exit(2);
    }
    for (final pin in readPins(pinsPath)) {
      final dir = Directory('$checkouts/${pin.name}');
      if (!dir.existsSync()) {
        // An unreachable pin is NOT a pipeline regression — same rule Tier A
        // applies. Report it, never score it.
        missingPins.add(pin.name);
        continue;
      }
      tasks.add(
        () => study(
          pin.name,
          dir,
          TierBOptions(
            libSubdir: pin.lib,
            testTimeout: options.testTimeout,
            pubTimeout: options.pubTimeout,
            maxFilesPerPackage: options.maxFilesPerPackage,
          ),
        ),
      );
    }
  } else if (packageName != null && checkoutPath != null) {
    final dir = Directory(checkoutPath);
    if (!dir.existsSync()) {
      stderr.writeln('--checkout does not exist: $checkoutPath');
      exit(2);
    }
    tasks.add(() => study(packageName, dir, options));
  } else {
    stderr.writeln(
      'Usage: rq1_tierb.dart --pins <file> --checkouts <dir> [--json <out>]\n'
      '       rq1_tierb.dart --package <name> --checkout <dir> [--json <out>]',
    );
    exit(2);
  }

  final packages = await runPackages(tasks, jobs: jobs);

  final jsonOut = argOf(args, 'json');
  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'missingPins': missingPins,
        'packages': [for (final p in packages) p.toJson()],
      })}\n',
    );
  }

  for (final line in summaryLines(packages, tierLabel: tierLabel)) {
    stdout.writeln(line);
  }
  if (missingPins.isNotEmpty) {
    stdout.writeln(
      '  unreachable pins (not scored): ${missingPins.join(', ')}',
    );
  }

  // Positive floor: a run that scored nothing is a checkout/harness failure,
  // never a 0% result.
  final scored = packages.expand((p) => p.files).where((f) => f.scored).length;
  if (scored < 1) {
    stderr.writeln(
      'ERROR: $tierLabel scored 0 files — no package checkout was usable.',
    );
    exit(1);
  }
}

Future<void> main(List<String> args) => runTierB(
  args,
  tierLabel: 'Tier B',
  study: (package, checkout, options) =>
      studyPackagePerFile(package, checkout, options: options),
);
