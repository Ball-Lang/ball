/// Self-hosting Phase 1: round-trip the Ball Dart engine through its own
/// encoder + compiler.
///
/// Encode `dart/engine/lib/engine.dart` via [DartEncoder], compile the
/// resulting Ball [Program] back to Dart via [DartCompiler], and write the
/// output to `tests/self_host/engine_roundtrip.dart`.
///
/// Then run `dart analyze` on the generated file and report any issues. Each
/// issue is a candidate Stop-Fix-Test-Resume target for the encoder or
/// compiler (per the self-host plan).
///
///   dart run dart/encoder/tool/roundtrip_engine.dart
///       [--skip-analyze]          (do not run dart analyze)
///       [--save-program <path>]   (also write the intermediate .ball.json)
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';

Future<void> main(List<String> args) async {
  final skipAnalyze = args.contains('--skip-analyze');
  final saveProgramIdx = args.indexOf('--save-program');
  final saveProgram = saveProgramIdx >= 0 && saveProgramIdx + 1 < args.length
      ? args[saveProgramIdx + 1]
      : null;

  final repoRoot = _findRepoRoot();
  final engineSrcPath = '$repoRoot/dart/engine/lib/engine.dart';
  final outDir = Directory('$repoRoot/dart/self_host/lib');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final outPath = '${outDir.path}/engine_roundtrip.dart';

  stdout.writeln('Ball Self-Host Round-Trip: engine.dart');
  stdout.writeln('=' * 55);

  // 1. Encode.
  stdout.write('  Reading engine.dart... ');
  final source = File(engineSrcPath).readAsStringSync();
  stdout.writeln('${source.length} bytes');

  stdout.write('  Encoding via DartEncoder... ');
  final encodeStart = DateTime.now();
  final Program program;
  final encoder = DartEncoder();
  try {
    program = encoder.encode(source, name: 'engine');
  } catch (e, st) {
    stdout.writeln('FAIL');
    stderr.writeln('ENCODER ERROR: $e');
    stderr.writeln(st);
    exit(2);
  }
  final encodeMs = DateTime.now().difference(encodeStart).inMilliseconds;
  stdout.writeln('OK (${encodeMs}ms, ${program.modules.length} modules, '
      '${program.modules.fold<int>(0, (n, m) => n + m.functions.length)} functions)');
  if (encoder.warnings.isNotEmpty) {
    stdout.writeln('  Encoder warnings: ${encoder.warnings.length}');
    for (final w in encoder.warnings.take(10)) {
      stdout.writeln('    - $w');
    }
    if (encoder.warnings.length > 10) {
      stdout.writeln('    ... and ${encoder.warnings.length - 10} more');
    }
  }

  if (saveProgram != null) {
    if (saveProgram.endsWith('.pb')) {
      // Binary protobuf — preferred for large programs whose expression
      // trees exceed protobuf's default JSON nesting limit of 100. The
      // C++ compiler's binary path sets SetRecursionLimit(10000), which
      // engine.dart needs.
      File(saveProgram).writeAsBytesSync(program.writeToBuffer());
    } else {
      final json = jsonEncode(program.toProto3Json());
      File(saveProgram).writeAsStringSync(json);
    }
    stdout.writeln('  Wrote intermediate Ball program → $saveProgram');
  }

  // 2. Compile. engine.dart is a library (no main), so use compileModule()
  // on the entry module written by the encoder ("main" by convention).
  stdout.write('  Compiling "main" module back to Dart... ');
  final compileStart = DateTime.now();
  final String compiled;
  try {
    final compiler = DartCompiler(program);
    compiled = compiler.compileModule('main');
  } catch (e, st) {
    stdout.writeln('FAIL');
    stderr.writeln('COMPILER ERROR: $e');
    stderr.writeln(st);
    exit(3);
  }
  final compileMs = DateTime.now().difference(compileStart).inMilliseconds;
  stdout.writeln('OK (${compileMs}ms, ${compiled.length} bytes)');

  File(outPath).writeAsStringSync(compiled);
  stdout.writeln('  Wrote → ${outPath.replaceAll('\\', '/')}');

  // 3. Analyze.
  if (skipAnalyze) {
    stdout.writeln('  Skipping dart analyze (--skip-analyze)');
    return;
  }

  stdout.writeln();
  stdout.writeln('Running dart analyze on generated file...');
  stdout.writeln('-' * 55);
  final analyzeResult = await Process.run(
    Platform.isWindows ? 'dart.bat' : 'dart',
    ['analyze', outPath, '--no-fatal-warnings'],
    runInShell: true,
  );
  stdout.write(analyzeResult.stdout);
  if (analyzeResult.stderr.toString().isNotEmpty) {
    stderr.write(analyzeResult.stderr);
  }

  if (analyzeResult.exitCode == 0) {
    stdout.writeln();
    stdout.writeln('✓ engine.dart round-trip clean — Phase 1 passes.');
  } else {
    stdout.writeln();
    stdout.writeln(
      '! dart analyze reported issues (exit ${analyzeResult.exitCode}).',
    );
    stdout.writeln(
      '  Each is a Stop-Fix-Test-Resume candidate for the encoder or compiler.',
    );
    exit(analyzeResult.exitCode);
  }
}

String _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path.replaceAll('\\', '/');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'Could not locate repo root (no proto/ball/v1/ball.proto found '
        'walking up from ${Directory.current.path})',
      );
    }
    dir = parent;
  }
}
