/// Cross-language test matrix: drives every Dart fixture through every
/// available Ball pipeline and asserts all outputs agree.
///
/// For each `tests/fixtures/dart/*.dart` program:
///
///                         dart run (baseline)  ──┐
///                                                 │
///   source ──► DartEncoder ──► Ball IR ──┬──► BallEngine (Dart)    ──┤
///                                         ├──► DartCompiler → dart run ──┤── all must
///                                         └──► ball_cpp_compile → cmake→run  ──┤    agree
///
/// Replaces the earlier approach of hand-writing `.ball.json` fixtures.
/// The Ball IR is auto-generated from Dart source, so every new fixture
/// exercises the encoder, both engines, and both compilers with zero
/// additional work.
///
/// The C++ pipelines are skipped (not failed) when the binaries aren't
/// on disk, so the harness works on contributors who haven't built the
/// C++ tree yet.
/// Tag this whole suite `slow` — each fixture spawns 2+ `dart run`
/// processes and the C++ pipelines shell out to cmake. Contributors
/// run `dart test -x slow` pre-commit and reserve the full matrix for
/// CI or explicit `dart test -t slow`.
@TestOn('vm')
@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart' show encodeBallFileJson;
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

// Pipeline runners are shared with conformance_roundtrip_test.dart so there
// is exactly one behavior-identical implementation of each leg.
import 'support/pipeline_runners.dart';

// ─── Pipeline-specific knobs ─────────────────────────────────────
// Fixtures whose emitted C++ wouldn't run (e.g. uses a feature the C++
// compiler doesn't fully support yet). Each entry is {fixture: reason}.
const _skipCppCompile = <String, String>{};

// Fixtures skipped for every C++ pipeline (including engine and runner).
const _skipCppAny = <String, String>{};

// Fixtures skipped for the TypeScript pipeline.
const _skipTs = <String, String>{};

// ─── Test harness ────────────────────────────────────────────────

void main() {
  final fixturesDir = Directory('../../tests/fixtures/dart');
  if (!fixturesDir.existsSync()) {
    // Tests run from dart/compiler/ — skip gracefully if fixtures moved.
    return;
  }

  // C++ compiler binary location produced by the default CMake build.
  final cppCompile = File(
    '../../cpp/build/compiler/Debug/ball_cpp_compile.exe',
  );
  final cppCompilePosix = File('../../cpp/build/compiler/ball_cpp_compile');

  File? firstExisting(Iterable<File> candidates) {
    for (final f in candidates) {
      if (f.existsSync()) return f;
    }
    return null;
  }

  final compileBin = firstExisting([cppCompile, cppCompilePosix]);

  final fixtures =
      fixturesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  group('cross-language: dart fixture → every Ball pipeline', () {
    late final Directory scratch;
    late final Directory ballJsonOutDir;
    setUpAll(() {
      scratch = Directory.systemTemp.createTempSync('ball_cross_');
      // Auto-generated ball.json files land under tests/fixtures/dart/
      // with a `.ball.json` suffix. Byproduct of the harness: other
      // tools (ctest, debuggers, IDE preview) can consume them without
      // having to rerun the encoder.
      ballJsonOutDir = Directory('${fixturesDir.path}/_generated');
      if (!ballJsonOutDir.existsSync()) ballJsonOutDir.createSync();
    });
    tearDownAll(() {
      try {
        scratch.deleteSync(recursive: true);
      } catch (_) {}
    });

    for (final fixture in fixtures) {
      final name = fixture.uri.pathSegments.last.replaceAll('.dart', '');
      test(name, () async {
        // ── 1. Baseline: dart run on the original source.
        final baseline = await runDartNative(fixture);

        // ── 2. Encode to Ball IR.
        final source = fixture.readAsStringSync();
        final program = DartEncoder().encode(source);

        // Persist the generated ball.json (self-describing Any envelope) so
        // other tests/tools can see it.
        final jsonOut = File('${ballJsonOutDir.path}/$name.ball.json');
        jsonOut.writeAsStringSync(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(encodeBallFileJson(program)),
        );
        // Also persist the baseline as an expected_output.txt file next
        // to the generated .ball.json. Lets downstream C++ harnesses
        // (test_e2e) compare against a known-good file without needing
        // to re-invoke `dart run` themselves.
        File(
          '${ballJsonOutDir.path}/$name.expected_output.txt',
        ).writeAsStringSync('$baseline\n');

        // ── 3. Dart BallEngine.
        final dartEngineOut = await runBallEngine(program);
        expect(
          dartEngineOut,
          equals(baseline),
          reason:
              'DartEngine diverged from `dart run`\n'
              '--- baseline ---\n$baseline\n'
              '--- engine ---\n$dartEngineOut',
        );

        // ── 4. DartCompiler → dart run.
        final recompiledDartOut = await runRecompiledDart(
          program,
          scratch,
          name,
        );
        expect(
          recompiledDartOut,
          equals(baseline),
          reason: 'Recompiled Dart diverged from `dart run`',
        );

        // ── 4b. TsCompiler → node --experimental-strip-types.
        if (!_skipTs.containsKey(name)) {
          final tsOut = await runTsCompiled(program, scratch, name);
          if (tsOut != null) {
            expect(
              tsOut,
              equals(baseline),
              reason: 'Recompiled TypeScript diverged from `dart run`',
            );
          }
        }

        // ── 5. C++ compile → build → run.
        if (compileBin != null &&
            !_skipCppAny.containsKey(name) &&
            !_skipCppCompile.containsKey(name)) {
          final cppCompiledOut = runCppCompiled(
            jsonOut,
            compileBin,
            scratch,
            name,
          );
          if (cppCompiledOut != null) {
            expect(
              cppCompiledOut,
              equals(baseline),
              reason: 'C++ compiled binary diverged from `dart run`',
            );
          }
        }
      });
    }
  });
}
