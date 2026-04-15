/// Cross-language test matrix: drives every Dart fixture through every
/// available Ball pipeline and asserts all outputs agree.
///
/// For each `tests/fixtures/dart/*.dart` program:
///
///                         dart run (baseline)  ──┐
///                                                 │
///   source ──► DartEncoder ──► Ball IR ──┬──► BallEngine (Dart)    ──┤
///                                         ├──► DartCompiler → dart run ──┤── all must
///                                         ├──► ball_cpp_runner        ──┤    agree
///                                         └──► ball_cpp_compile → cmake→run
///
/// Replaces the earlier approach of hand-writing `.ball.json` fixtures.
/// The Ball IR is auto-generated from Dart source, so every new fixture
/// exercises the encoder, both engines, and both compilers with zero
/// additional work.
///
/// The C++ pipelines are skipped (not failed) when the binaries aren't
/// on disk, so the harness works on contributors who haven't built the
/// C++ tree yet.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ─── Pipeline-specific knobs ─────────────────────────────────────
// Fixtures whose emitted C++ wouldn't run (e.g. uses a feature the C++
// compiler doesn't fully support yet). Each entry is {fixture: reason}.
const _skipCppCompile = <String, String>{
  '09_string': 'string.toUpperCase is a method call on std::string; '
      'compiler emits .toUpperCase() which C++ does not have',
  '13_list_ops': 'list[i] indexing and list.length not yet emitted by C++ compiler',
  '26_list_iterate': 'list[i] returns std::any which does not support arithmetic',
  '15_closure': 'Function return types (int Function(int)) need template '
      'conversion for C++17 — not yet supported',
  '25_nested_closure': 'Function types as parameters (int Function(int)) '
      'need template conversion for C++17 — not yet supported',
};

// Fixtures skipped for every C++ pipeline (including engine and runner).
const _skipCppAny = <String, String>{};

String _norm(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

// ─── Pipeline runners ────────────────────────────────────────────

String _runDartNative(File dartFile) {
  final r = Process.runSync(
    Platform.resolvedExecutable,
    ['run', dartFile.absolute.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (r.exitCode != 0) {
    throw StateError(
      'dart run failed (rc=${r.exitCode})\nstderr:\n${r.stderr}',
    );
  }
  return _norm(r.stdout as String);
}

String _runBallEngine(Program program) {
  final lines = <String>[];
  BallEngine(program, stdout: lines.add).run();
  return _norm(lines.join('\n'));
}

String _runRecompiledDart(Program program, Directory scratch, String name) {
  final dartSource = DartCompiler(program).compile();
  final out = File('${scratch.path}/$name.regen.dart');
  out.writeAsStringSync(dartSource);
  return _runDartNative(out);
}

/// Returns null if the ball_cpp_runner binary isn't present.
String? _runCppEngine(
  File ballJsonFile,
  File runnerBinary,
) {
  if (!runnerBinary.existsSync()) return null;
  final r = Process.runSync(
    runnerBinary.absolute.path,
    [ballJsonFile.absolute.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (r.exitCode != 0) {
    throw StateError(
      'ball_cpp_runner failed (rc=${r.exitCode})\nstderr:\n${r.stderr}',
    );
  }
  // The runner prints "Result: N" as a trailing line for scalar returns;
  // strip it because other pipelines don't emit it.
  final lines = (r.stdout as String).split(RegExp(r'\r?\n')).toList();
  while (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  if (lines.isNotEmpty && lines.last.startsWith('Result: ')) {
    lines.removeLast();
  }
  return _norm(lines.join('\n'));
}

/// Compile Ball → C++ → exe, run, return stdout.
/// Returns null if the ball_cpp_compile binary isn't present.
String? _runCppCompiled(
  File ballJsonFile,
  File compileBinary,
  Directory scratch,
  String name,
) {
  if (!compileBinary.existsSync()) return null;

  final cppOut = File('${scratch.path}/$name.cpp');
  final compileRes = Process.runSync(
    compileBinary.absolute.path,
    [ballJsonFile.absolute.path, cppOut.absolute.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (compileRes.exitCode != 0) {
    throw StateError(
      'ball_cpp_compile failed (rc=${compileRes.exitCode})\n'
      'stderr:\n${compileRes.stderr}',
    );
  }

  // Reuse the existing CMake-based build-a-scratch-project trick via a
  // fresh mini CMake project; we invoke cmake directly.
  final projDir = Directory('${scratch.path}/$name.proj');
  projDir.createSync(recursive: true);
  File('${projDir.path}/${name}.cpp').writeAsStringSync(
    cppOut.readAsStringSync(),
  );
  File('${projDir.path}/CMakeLists.txt').writeAsStringSync('''
cmake_minimum_required(VERSION 3.14)
project(ball_cross_$name CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable($name ${name}.cpp)
''');

  final buildDir = Directory('${projDir.path}/_b');
  buildDir.createSync();
  final gen = Process.runSync('cmake', [
    '-S', projDir.absolute.path,
    '-B', buildDir.absolute.path,
  ], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (gen.exitCode != 0) {
    throw StateError(
      'cmake configure failed (rc=${gen.exitCode})\n'
      'stderr:\n${gen.stderr}\n'
      '--- emitted cpp ---\n${cppOut.readAsStringSync()}',
    );
  }
  final build = Process.runSync('cmake', [
    '--build', buildDir.absolute.path,
    '--config', 'Debug',
  ], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (build.exitCode != 0) {
    throw StateError(
      'cmake build failed (rc=${build.exitCode})\n'
      'stdout:\n${build.stdout}\nstderr:\n${build.stderr}\n'
      '--- emitted cpp ---\n${cppOut.readAsStringSync()}',
    );
  }

  // Locate the binary. Multi-config generators put it under <build>/Debug,
  // single-config directly under <build>.
  File? exeFile;
  final exeName = Platform.isWindows ? '$name.exe' : name;
  for (final sub in ['Debug', '']) {
    final p = File('${buildDir.path}/$sub/$exeName');
    if (p.existsSync()) {
      exeFile = p;
      break;
    }
  }
  if (exeFile == null) {
    throw StateError(
      'compiled binary not found under ${buildDir.path} for $name',
    );
  }

  final run = Process.runSync(
    exeFile.absolute.path,
    const [],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (run.exitCode != 0) {
    throw StateError(
      'compiled binary exited rc=${run.exitCode}\n'
      'stderr:\n${run.stderr}',
    );
  }
  return _norm(run.stdout as String);
}

// ─── Test harness ────────────────────────────────────────────────

void main() {
  final fixturesDir = Directory('../../tests/fixtures/dart');
  if (!fixturesDir.existsSync()) {
    // Tests run from dart/compiler/ — skip gracefully if fixtures moved.
    return;
  }

  // C++ binary locations produced by the default CMake build.
  final cppRunner = File('../../cpp/build/engine/Debug/ball_cpp_runner.exe');
  final cppCompile = File('../../cpp/build/compiler/Debug/ball_cpp_compile.exe');
  // Also check the POSIX layout (no Debug subdir).
  final cppRunnerPosix = File('../../cpp/build/engine/ball_cpp_runner');
  final cppCompilePosix = File('../../cpp/build/compiler/ball_cpp_compile');

  File? firstExisting(Iterable<File> candidates) {
    for (final f in candidates) {
      if (f.existsSync()) return f;
    }
    return null;
  }

  final runnerBin = firstExisting([cppRunner, cppRunnerPosix]);
  final compileBin = firstExisting([cppCompile, cppCompilePosix]);

  final fixtures = fixturesDir
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
      test(name, () {
        // ── 1. Baseline: dart run on the original source.
        final baseline = _runDartNative(fixture);

        // ── 2. Encode to Ball IR.
        final source = fixture.readAsStringSync();
        final program = DartEncoder().encode(source);

        // Persist the generated ball.json so other tests/tools can see it.
        final jsonOut = File('${ballJsonOutDir.path}/$name.ball.json');
        jsonOut.writeAsStringSync(
          const JsonEncoder.withIndent('  ')
              .convert(program.toProto3Json()),
        );
        // Also persist the baseline as an expected_output.txt file next
        // to the generated .ball.json. Lets downstream C++ harnesses
        // (test_e2e) compare against a known-good file without needing
        // to re-invoke `dart run` themselves.
        File('${ballJsonOutDir.path}/$name.expected_output.txt')
            .writeAsStringSync('$baseline\n');

        // ── 3. Dart BallEngine.
        final dartEngineOut = _runBallEngine(program);
        expect(
          dartEngineOut,
          equals(baseline),
          reason: 'DartEngine diverged from `dart run`\n'
              '--- baseline ---\n$baseline\n'
              '--- engine ---\n$dartEngineOut',
        );

        // ── 4. DartCompiler → dart run.
        final recompiledDartOut = _runRecompiledDart(program, scratch, name);
        expect(
          recompiledDartOut,
          equals(baseline),
          reason: 'Recompiled Dart diverged from `dart run`',
        );

        // ── 5. C++ engine via ball_cpp_runner.
        if (runnerBin != null && !_skipCppAny.containsKey(name)) {
          final cppEngineOut = _runCppEngine(jsonOut, runnerBin);
          if (cppEngineOut != null) {
            expect(
              cppEngineOut,
              equals(baseline),
              reason: 'C++ engine diverged from `dart run`',
            );
          }
        }

        // ── 6. C++ compile → build → run.
        if (compileBin != null &&
            !_skipCppAny.containsKey(name) &&
            !_skipCppCompile.containsKey(name)) {
          final cppCompiledOut = _runCppCompiled(
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
