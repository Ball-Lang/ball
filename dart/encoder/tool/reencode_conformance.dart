/// Re-encode conformance programs through the Dart compiler + encoder round-trip.
///
/// For each named program:
///   1. Load the Ball IR from tests/conformance/NNN_name.ball.json
///   2. Run through Dart engine → capture output
///   3. Verify engine output matches expected_output.txt
///   4. Compile Ball IR to Dart via DartCompiler
///   5. Re-encode Dart source via DartEncoder
///   6. Run re-encoded Ball IR through engine → verify output matches
///   7. Compile re-encoded Ball IR to Dart, run → verify output matches
///   8. Write back the fixed Ball IR
///
/// Usage:
///   cd dart/encoder && dart run tool/reencode_conformance.dart 78_map_operations ...
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show decodeProgramJson, encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/reencode_conformance.dart <name1> [name2] ...',
    );
    exit(1);
  }

  final repoRoot = _findRepoRoot();
  final conformanceDir = '$repoRoot/tests/conformance';

  var passed = 0;
  var skipped = 0;

  for (final name in args) {
    stdout.writeln('');
    stdout.writeln('=' * 60);
    stdout.writeln('Re-encoding: $name');
    stdout.writeln('=' * 60);

    final ballJsonPath = '$conformanceDir/$name.ball.json';
    final expectedPath = '$conformanceDir/$name.expected_output.txt';

    if (!File(ballJsonPath).existsSync()) {
      stderr.writeln('  SKIP: $ballJsonPath not found');
      skipped++;
      continue;
    }
    if (!File(expectedPath).existsSync()) {
      stderr.writeln('  SKIP: $expectedPath not found');
      skipped++;
      continue;
    }

    final expected = File(expectedPath).readAsStringSync().trimRight();

    try {
      // 1. Load original Ball IR.
      stdout.write('  Loading Ball IR... ');
      final jsonData = json.decode(File(ballJsonPath).readAsStringSync());
      final originalProgram = decodeProgramJson(jsonData);
      stdout.writeln('OK');

      // 2. Run original through engine → verify matches expected.
      stdout.write('  Running original through engine... ');
      final originalOutput = await _runEngine(originalProgram);
      final normalizedOriginal = originalOutput.trimRight().replaceAll(
        '\r\n',
        '\n',
      );
      final normalizedExpected = expected.replaceAll('\r\n', '\n');
      if (normalizedOriginal != normalizedExpected) {
        stderr.writeln('FAIL');
        stderr.writeln('    Original engine output does not match expected!');
        final expectedLines = normalizedExpected.split('\n');
        final gotLines = normalizedOriginal.split('\n');
        stderr.writeln(
          '    Expected ${expectedLines.length} lines, got ${gotLines.length} lines',
        );
        for (var i = 0; i < expectedLines.length || i < gotLines.length; i++) {
          final e = i < expectedLines.length ? expectedLines[i] : '<missing>';
          final g = i < gotLines.length ? gotLines[i] : '<missing>';
          final mark = e == g ? '  ' : '!!';
          stderr.writeln('    $mark [$i] expected: "$e" | got: "$g"');
        }
        skipped++;
        continue;
      }
      stdout.writeln('OK');

      // 3. Compile to Dart.
      stdout.write('  Compiling to Dart... ');
      final compiler = DartCompiler(originalProgram);
      final dartSource = compiler.compile();
      stdout.writeln('OK (${dartSource.length} bytes)');

      // 4. Re-encode Dart source.
      stdout.write('  Re-encoding Dart → Ball... ');
      final encoder = DartEncoder();
      final reencoded = encoder.encode(dartSource, name: name);
      stdout.writeln(
        'OK (${reencoded.modules.length} modules, '
        '${reencoded.modules.fold<int>(0, (n, m) => n + m.functions.length)} functions)',
      );
      if (encoder.warnings.isNotEmpty) {
        stdout.writeln('    Encoder warnings: ${encoder.warnings.length}');
        for (final w in encoder.warnings.take(5)) {
          stdout.writeln('      - $w');
        }
      }

      // 5. Run re-encoded through engine → verify.
      stdout.write('  Running re-encoded through engine... ');
      final reencodedOutput = await _runEngine(reencoded);
      final normalizedReencoded = reencodedOutput.trimRight().replaceAll(
        '\r\n',
        '\n',
      );
      if (normalizedReencoded != normalizedExpected) {
        stderr.writeln('FAIL');
        stderr.writeln('    Re-encoded engine output does not match expected!');
        final expectedLines = normalizedExpected.split('\n');
        final gotLines = normalizedReencoded.split('\n');
        stderr.writeln(
          '    Expected ${expectedLines.length} lines, got ${gotLines.length} lines',
        );
        for (var i = 0; i < expectedLines.length || i < gotLines.length; i++) {
          final e = i < expectedLines.length ? expectedLines[i] : '<missing>';
          final g = i < gotLines.length ? gotLines[i] : '<missing>';
          final mark = e == g ? '  ' : '!!';
          stderr.writeln('    $mark [$i] expected: "$e" | got: "$g"');
        }
        skipped++;
        continue;
      }
      stdout.writeln('OK');

      // 6. Compile re-encoded Ball IR to Dart + run → verify.
      //    This step is best-effort: the engine path (step 5) is the authority.
      //    Some programs have patterns (chained assignments, etc.) that compile
      //    to type-unsafe Dart but work fine in the engine's dynamic dispatch.
      stdout.write('  Compiling re-encoded Ball → Dart + run... ');
      final recompiler = DartCompiler(reencoded);
      final recompiledDart = recompiler.compile();
      final tmpFile = File(
        '${Directory.systemTemp.path}/ball_reencode_${name}_${pid}.dart',
      );
      tmpFile.writeAsStringSync(recompiledDart);
      try {
        final result = Process.runSync(
          Platform.resolvedExecutable,
          ['run', tmpFile.absolute.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        final dartOutput = (result.stdout as String).trimRight();
        if (result.exitCode != 0) {
          stderr.writeln(
            'WARN (exit ${result.exitCode}) — engine path OK, compile path has type errors',
          );
        } else if (dartOutput != normalizedExpected) {
          stderr.writeln(
            'WARN — compiled output differs from expected (engine path OK)',
          );
        } else {
          stdout.writeln('OK');
        }
      } finally {
        if (tmpFile.existsSync()) tmpFile.deleteSync();
      }

      // 7. Write back the fixed Ball IR.
      stdout.write('  Writing fixed Ball IR → $ballJsonPath... ');
      final fixedJson = const JsonEncoder.withIndent(
        '  ',
      ).convert(encodeBallFileJson(reencoded));
      File(ballJsonPath).writeAsStringSync('$fixedJson\n');
      stdout.writeln('OK');

      passed++;
      stdout.writeln('  ✓ $name re-encoded successfully');
    } catch (e, st) {
      stderr.writeln('  ERROR: $e');
      stderr.writeln('  $st');
      skipped++;
    }
  }

  stdout.writeln('');
  stdout.writeln('Results: $passed passed, $skipped skipped of ${args.length}');
  if (skipped > 0) exit(1);
}

/// Run a Ball program through the Dart engine and capture stdout.
Future<String> _runEngine(Program program) async {
  final lines = <String>[];
  final errLines = <String>[];
  final engine = BallEngine(
    program,
    stdout: (s) => lines.add(s),
    stderr: (s) => errLines.add(s),
  );
  try {
    await engine.run();
  } catch (e) {
    errLines.add('Engine error: $e');
  }
  if (errLines.isNotEmpty) {
    stderr.writeln('    Engine stderr: ${errLines.join('\n')}');
  }
  return lines.join('\n');
}

/// Walk up from CWD to find the repo root (has proto/ball/v1/ball.proto).
String _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  // Fallback: try common relative paths.
  if (File('../../proto/ball/v1/ball.proto').existsSync()) return '../..';
  throw StateError('Cannot find repo root from ${Directory.current.path}');
}
