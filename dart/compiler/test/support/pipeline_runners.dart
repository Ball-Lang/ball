/// Shared Ball pipeline runners.
///
/// These helpers drive a Ball [Program] (or a `.dart` source file) through
/// the various Ball toolchains and capture their stdout:
///
///   - [runDartNative]    — `dart run <file>` (baseline for fixtures).
///   - [runBallEngine]    — the Dart tree-walking [BallEngine].
///   - [runRecompiledDart]— Ball → [DartCompiler] → `dart run`.
///   - [runTsCompiled]    — Ball → `@ball-lang/compiler` CLI → `node`.
///   - [runCppCompiled]   — Ball → `ball_cpp_compile` → cmake → run.
///
/// Both [cross_language_test.dart] and [conformance_roundtrip_test.dart]
/// import these so there is a single, behavior-identical implementation of
/// each pipeline leg. The bodies are byte-for-byte the same logic that used
/// to live inline in `cross_language_test.dart`.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Per-program execution timeout. Programs that exceed this are killed and
/// treated as failures (guards against infinite loops from compiler bugs).
const Duration programTimeout = Duration(seconds: 30);

/// Normalizes line endings and strips trailing whitespace so outputs from
/// different toolchains compare cleanly.
String normalizeOutput(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

/// Runs a process with a timeout. Kills the process and throws [TimeoutException]
/// if it exceeds [timeout]. Returns the captured stdout on success; throws
/// [StateError] on non-zero exit.
Future<String> runProcessGuarded(
  String executable,
  List<String> args, {
  Duration timeout = programTimeout,
  String? label,
}) async {
  final process = await Process.start(executable, args);
  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  process.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
  process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

  final exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw TimeoutException(
        '${label ?? executable} exceeded ${timeout.inSeconds}s (likely infinite loop)',
        timeout,
      );
    },
  );

  if (exitCode != 0) {
    throw StateError(
      '${label ?? executable} failed (rc=$exitCode)\nstderr:\n$stderrBuf',
    );
  }
  return normalizeOutput(stdoutBuf.toString());
}

/// Runs `dart run <dartFile>` and returns its normalized stdout.
///
/// Throws [StateError] if the process exits non-zero.
/// Throws [TimeoutException] if the program exceeds [programTimeout].
Future<String> runDartNative(File dartFile) => runProcessGuarded(
  Platform.resolvedExecutable,
  ['run', dartFile.absolute.path],
  label: 'dart run ${dartFile.uri.pathSegments.last}',
);

/// Executes [program] with the Dart [BallEngine] and returns its normalized
/// captured stdout.
Future<String> runBallEngine(Program program) async {
  final lines = <String>[];
  await BallEngine(program, stdout: lines.add).run();
  return normalizeOutput(lines.join('\n'));
}

/// Compiles [program] to Dart via [DartCompiler], writes it under [scratch]
/// as `<name>.regen.dart`, runs it with `dart run`, and returns the output.
///
/// Multi-module programs use [DartCompiler.compileAllModules] so each module
/// gets its own `.dart` file with correct cross-module imports.
Future<String> runRecompiledDart(
  Program program,
  Directory scratch,
  String name,
) async {
  final compiler = DartCompiler(program);
  final allModules = compiler.compileAllModules();
  if (allModules.length > 1) {
    for (final entry in allModules.entries) {
      File('${scratch.path}/${entry.key}.dart').writeAsStringSync(entry.value);
    }
    final entryFile = File('${scratch.path}/${program.entryModule}.dart');
    return runDartNative(entryFile);
  }
  final dartSource = compiler.compile();
  final out = File('${scratch.path}/$name.regen.dart');
  out.writeAsStringSync(dartSource);
  return runDartNative(out);
}

/// Compile Ball → TypeScript via `@ball-lang/compiler` (ts/compiler/),
/// then run via `node --experimental-strip-types`.
/// Returns null if `node` isn't on PATH or the TS compiler isn't built.
Future<String?> runTsCompiled(
  Program program,
  Directory scratch,
  String name,
) async {
  final nodeExe = Platform.isWindows ? 'node.exe' : 'node';

  // Locate the @ball-lang/compiler CLI relative to the repo root.
  var dir = Directory.current;
  String? compilerCli;
  while (true) {
    final candidate = File('${dir.path}/ts/compiler/bin/ball-ts-compile.mjs');
    if (candidate.existsSync()) {
      compilerCli = candidate.absolute.path;
      break;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  if (compilerCli == null) return null;

  // Write program JSON to a temp file, invoke the TS compiler CLI.
  final tmpIn = File('${scratch.path}/$name.ball.json');
  tmpIn.writeAsStringSync(jsonEncode(program.toProto3Json()));
  final out = File('${scratch.path}/$name.regen.ts');

  try {
    final compile = Process.runSync(
      nodeExe,
      [compilerCli, tmpIn.path, '--out', out.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (compile.exitCode != 0) {
      throw StateError(
        'ball-ts-compile failed (rc=${compile.exitCode})\n'
        'stderr:\n${compile.stderr}',
      );
    }

    return await runProcessGuarded(nodeExe, [
      '--experimental-strip-types',
      '--disable-warning=ExperimentalWarning',
      out.absolute.path,
    ], label: 'node $name.regen.ts');
  } on ProcessException {
    return null;
  }
}

/// Compile Ball → C++ → exe, run, return stdout.
/// Returns null if the ball_cpp_compile binary isn't present.
String? runCppCompiled(
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
  File(
    '${projDir.path}/$name.cpp',
  ).writeAsStringSync(cppOut.readAsStringSync());
  File('${projDir.path}/CMakeLists.txt').writeAsStringSync('''
cmake_minimum_required(VERSION 3.14)
project(ball_cross_$name CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable($name $name.cpp)
''');

  final buildDir = Directory('${projDir.path}/_b');
  buildDir.createSync();
  final gen = Process.runSync(
    'cmake',
    ['-S', projDir.absolute.path, '-B', buildDir.absolute.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (gen.exitCode != 0) {
    throw StateError(
      'cmake configure failed (rc=${gen.exitCode})\n'
      'stderr:\n${gen.stderr}\n'
      '--- emitted cpp ---\n${cppOut.readAsStringSync()}',
    );
  }
  final build = Process.runSync(
    'cmake',
    ['--build', buildDir.absolute.path, '--config', 'Debug'],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
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
  return normalizeOutput(run.stdout as String);
}
