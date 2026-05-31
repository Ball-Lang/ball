/// Conformance round-trip harness.
///
/// Drives the entire `tests/conformance/` corpus (every `NNN_name.ball.json`
/// with a sibling `NNN_name.expected_output.txt` golden) through multiple
/// Ball toolchain legs and asserts each leg reproduces the golden output:
///
///   - `engine`          — Dart [BallEngine] interprets the program.
///   - `dart-compiled`   — Ball → [DartCompiler] → `dart run`.
///   - `ts-compiled`     — Ball → `@ball-lang/compiler` → `node`.
///   - `dart-roundtrip`  — Ball → [DartCompiler] → Dart source →
///                         [DartEncoder] → Ball' → [DartCompiler] → `dart run`.
///                         (Exercises the Dart ENCODER inside the loop.)
///
/// Some legs are EXPECTED to fail: the TS compiler and the Dart
/// compiler/encoder don't yet support every construct the corpus covers.
/// Those known failures are recorded in `tests/conformance/roundtrip_baseline.txt`
/// (one `NNN_name:leg` line each). The suite asserts the SET of actual
/// failures EQUALS the baseline set — mirroring the upstream protobuf
/// `failure_list` discipline:
///
///   - a NEW failure (not in the baseline)  → regression → suite FAILS.
///   - a combo that newly PASSES (stale baseline) → suite FAILS, prompting
///     the maintainer to delete that line from the baseline.
///
/// A leg whose toolchain is absent (e.g. `node` not on PATH, or the TS
/// compiler not built) is recorded as SKIPPED — counted and surfaced in the
/// output, never silently treated as a pass.
///
/// Tagged `slow`: each program spawns several `dart run` / `node` processes.
/// Run with `dart test -t slow test/conformance_roundtrip_test.dart`.
///
/// Regenerating the baseline (after a deliberate compiler/encoder change):
///   BALL_RT_UPDATE_BASELINE=1 dart test -t slow test/conformance_roundtrip_test.dart
/// (writes tests/conformance/roundtrip_baseline.txt from the real failures,
/// then still asserts green against the freshly-written baseline).
@TestOn('vm')
@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart' show decodeProgramJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

import 'support/pipeline_runners.dart';

/// All legs this harness exercises, in a stable order.
const _legs = <String>[
  'engine',
  'dart-compiled',
  'ts-compiled',
  'dart-roundtrip',
];

/// Result of running one leg against one program.
enum _Outcome { pass, fail, skip }

/// Locates `tests/conformance/` by walking up from the current directory to
/// the repo root. CWD-independent: works whether tests run from
/// `dart/compiler/`, the repo root, or anywhere in between.
Directory _findConformanceDir() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory('${dir.path}/tests/conformance');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'could not locate tests/conformance walking up from '
        '${Directory.current.absolute.path}',
      );
    }
    dir = parent;
  }
}

/// Parses a baseline file into a set of `NNN_name:leg` strings, ignoring
/// blank lines and `#` comments. Missing file ⇒ empty set.
Set<String> _readBaseline(File f) {
  if (!f.existsSync()) return <String>{};
  final out = <String>{};
  for (final raw in f.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    out.add(line);
  }
  return out;
}

/// One discovered corpus entry: program path + parsed [Program] + golden.
class _Case {
  _Case(this.name, this.program, this.expected, this.jsonFile);
  final String name;
  final Program program;
  final String expected;
  final File jsonFile;
}

/// Runs a single leg for a single case. Returns the [_Outcome] plus, on
/// failure, a short diagnostic. Toolchain-absent legs return [_Outcome.skip].
/// All execution steps are timeout-guarded against infinite loops.
Future<({_Outcome outcome, String? detail})> _runLeg(
  String leg,
  _Case c,
  Directory scratch,
) async {
  try {
    switch (leg) {
      case 'dart-compiled':
        final out = await runRecompiledDart(c.program, scratch, c.name);
        return out == c.expected
            ? (outcome: _Outcome.pass, detail: null)
            : (outcome: _Outcome.fail, detail: _diff(c.expected, out));
      case 'ts-compiled':
        final out = await runTsCompiled(c.program, scratch, c.name);
        if (out == null) return (outcome: _Outcome.skip, detail: null);
        return out == c.expected
            ? (outcome: _Outcome.pass, detail: null)
            : (outcome: _Outcome.fail, detail: _diff(c.expected, out));
      case 'dart-roundtrip':
        // Ball → Dart source → DartEncoder → Ball' → Dart → run.
        final dartSource = DartCompiler(c.program).compile();
        final Program reencoded;
        try {
          reencoded = DartEncoder().encode(dartSource);
        } catch (e) {
          return (outcome: _Outcome.fail, detail: 'encoder threw: $e');
        }
        final out = await runRecompiledDart(reencoded, scratch, '${c.name}.rt');
        return out == c.expected
            ? (outcome: _Outcome.pass, detail: null)
            : (outcome: _Outcome.fail, detail: _diff(c.expected, out));
      default:
        throw StateError('unknown leg: $leg');
    }
  } catch (e) {
    return (outcome: _Outcome.fail, detail: e.toString());
  }
}

String _diff(String expected, String actual) {
  final e = expected.replaceAll('\n', '\\n');
  final a = actual.replaceAll('\n', '\\n');
  return 'expected="$e" actual="$a"';
}

/// Evaluates every leg of [c], returning a map leg → outcome and a map of
/// failure details for surfaced diagnostics.
Future<Map<String, ({_Outcome outcome, String? detail})>> _evaluate(
  _Case c,
  Directory scratch,
) async {
  final results = <String, ({_Outcome outcome, String? detail})>{};

  // engine leg (async).
  try {
    final out = await runBallEngine(c.program);
    results['engine'] = out == c.expected
        ? (outcome: _Outcome.pass, detail: null)
        : (outcome: _Outcome.fail, detail: _diff(c.expected, out));
  } catch (e) {
    results['engine'] = (outcome: _Outcome.fail, detail: e.toString());
  }

  for (final leg in _legs) {
    if (leg == 'engine') continue;
    results[leg] = await _runLeg(leg, c, scratch);
  }
  return results;
}

/// Discovers and parses every corpus entry that has a golden. Programs that
/// fail to PARSE are still surfaced (as a synthetic case whose every leg
/// fails) so a malformed corpus file can't silently disappear.
List<_Case> _discover(Directory conformanceDir) {
  final jsonFiles =
      conformanceDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.ball.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final cases = <_Case>[];
  for (final jsonFile in jsonFiles) {
    final name = jsonFile.uri.pathSegments.last.replaceAll('.ball.json', '');
    final goldenFile = File(
      jsonFile.path.replaceAll('.ball.json', '.expected_output.txt'),
    );
    // No golden ⇒ nothing to assert; not part of the round-trip corpus.
    if (!goldenFile.existsSync()) continue;

    final expected = normalizeOutput(goldenFile.readAsStringSync());
    Program program;
    try {
      program = decodeProgramJson(jsonDecode(jsonFile.readAsStringSync()));
    } catch (e) {
      // Keep an empty program; every leg will then fail loudly.
      program = Program();
    }
    cases.add(_Case(name, program, expected, jsonFile));
  }
  return cases;
}

/// Runs the whole corpus across all legs and returns the set of actual
/// `NNN_name:leg` failures plus per-leg pass/fail/skip tallies.
Future<({Set<String> failures, Map<String, List<int>> tally, int total})>
_runCorpus(List<_Case> cases, Directory scratch) async {
  final failures = <String>{};
  // tally[leg] = [pass, fail, skip].
  final tally = {
    for (final l in _legs) l: <int>[0, 0, 0],
  };

  for (final c in cases) {
    final results = await _evaluate(c, scratch);
    for (final leg in _legs) {
      final r = results[leg]!;
      switch (r.outcome) {
        case _Outcome.pass:
          tally[leg]![0]++;
        case _Outcome.fail:
          tally[leg]![1]++;
          failures.add('${c.name}:$leg');
        case _Outcome.skip:
          tally[leg]![2]++;
      }
    }
  }
  return (failures: failures, tally: tally, total: cases.length);
}

String _renderTally(Map<String, List<int>> tally, int total) {
  final b = StringBuffer();
  b.writeln('Conformance round-trip results over $total programs:');
  for (final leg in _legs) {
    final t = tally[leg]!;
    b.writeln('  ${leg.padRight(16)} pass=${t[0]}  fail=${t[1]}  skip=${t[2]}');
  }
  return b.toString();
}

void main() async {
  final conformanceDir = _findConformanceDir();
  final baselineFile = File('${conformanceDir.path}/roundtrip_baseline.txt');

  final cases = _discover(conformanceDir);
  if (cases.isEmpty) {
    // Nothing to do; surface clearly rather than passing vacuously.
    test('conformance corpus present', () {
      fail(
        'no conformance programs with goldens found in ${conformanceDir.path}',
      );
    });
    return;
  }

  // Baseline (re)generation mode: set BALL_RT_UPDATE_BASELINE=1 to have the
  // run overwrite tests/conformance/roundtrip_baseline.txt with the real
  // failure set (and still assert green against it afterwards). Works under
  // `dart test` since it reads a process environment variable.
  final updateBaseline = Platform.environment['BALL_RT_UPDATE_BASELINE'] == '1';

  // One monolithic test: the corpus run spawns thousands of child processes,
  // so it gets its own unbounded timeout. Per-program assertions are folded
  // into the single failure-set comparison at the end (protobuf
  // failure_list discipline).
  test(
    'failure set matches baseline (${cases.length} programs × ${_legs.length} legs)',
    () async {
      final scratch = Directory.systemTemp.createTempSync('ball_rt_');
      try {
        final baseline = _readBaseline(baselineFile);
        final r = await _runCorpus(cases, scratch);
        final actualFailures = r.failures;

        // Always surface the per-leg tally.
        // ignore: avoid_print
        print(_renderTally(r.tally, r.total));

        if (updateBaseline) {
          final sorted = actualFailures.toList()..sort();
          baselineFile.writeAsStringSync(
            '# Auto-generated by conformance_roundtrip_test.dart '
            '(BALL_RT_UPDATE_BASELINE=1).\n'
            '# Each line is "NNN_name:leg" — a known-failing combo that the\n'
            '# current toolchain cannot yet reproduce. Mirrors the upstream\n'
            '# protobuf failure_list discipline. Regenerate after deliberate\n'
            '# compiler/encoder changes.\n'
            '${sorted.join('\n')}\n',
          );
          // ignore: avoid_print
          print(
            'Wrote ${sorted.length} baseline failures to ${baselineFile.path}',
          );
        }

        // New failures (regressions) and newly-passing combos (stale
        // baseline) both fail the suite.
        final regressions = actualFailures.difference(baseline).toList()
          ..sort();
        final nowPassing = baseline.difference(actualFailures).toList()..sort();

        final msg = StringBuffer();
        if (regressions.isNotEmpty) {
          msg.writeln(
            'REGRESSIONS — ${regressions.length} leg(s) now fail that were '
            'not in the baseline:',
          );
          for (final f in regressions) {
            msg.writeln('  + $f');
          }
        }
        if (nowPassing.isNotEmpty) {
          msg.writeln(
            'STALE BASELINE — ${nowPassing.length} leg(s) now PASS but are '
            'still listed as failing; remove them from '
            'tests/conformance/roundtrip_baseline.txt:',
          );
          for (final f in nowPassing) {
            msg.writeln('  - $f');
          }
        }
        expect(
          regressions.isEmpty && nowPassing.isEmpty,
          isTrue,
          reason: msg.toString(),
        );
      } finally {
        try {
          scratch.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
    timeout: const Timeout(Duration(hours: 2)),
  );
}
