#!/usr/bin/env dart
/// Cross-language conformance test runner for Ball programs.
///
/// Runs each .ball.json test file through the Dart engine and compares
/// output against the expected_output.txt file.
///
/// Must be run from the dart/engine directory:
///   cd dart/engine && dart run test/run_conformance.dart
///
/// Or with explicit dir:
///   dart run test/run_conformance.dart --dir ../../tests/conformance

import 'dart:convert';
import 'dart:io';

import 'package:ball_engine/engine.dart';
import 'package:ball_base/gen/ball/v1/ball.pb.dart';

Future<void> main(List<String> args) async {
  final dir = args.contains('--dir')
      ? args[args.indexOf('--dir') + 1]
      : '../../tests/conformance';

  final testDir = Directory(dir);
  if (!testDir.existsSync()) {
    stderr.writeln('Conformance test directory not found: $dir');
    exit(1);
  }

  final testFiles = testDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ball.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (testFiles.isEmpty) {
    stderr.writeln('No .ball.json files found in $dir');
    exit(1);
  }

  var passed = 0;
  var failed = 0;
  var skipped = 0;
  final failures = <String>[];

  for (final testFile in testFiles) {
    final name = testFile.uri.pathSegments.last.replaceAll('.ball.json', '');
    final expectedFile = File(
        testFile.path.replaceAll('.ball.json', '.expected_output.txt'));

    if (!expectedFile.existsSync()) {
      stdout.writeln('  SKIP $name (no expected output)');
      skipped++;
      continue;
    }

    try {
      final jsonStr = testFile.readAsStringSync();
      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final program = Program()
        ..mergeFromProto3Json(jsonMap, ignoreUnknownFields: true);

      final lines = <String>[];
      final engine = BallEngine(program, stdout: lines.add);
      await engine.run();
      final output = lines.join('\n').trimRight();
      final expected = expectedFile.readAsStringSync().trimRight();

      if (output == expected) {
        stdout.writeln('  PASS $name');
        passed++;
      } else {
        stdout.writeln('  FAIL $name');
        stdout.writeln('    Expected: ${expected.replaceAll('\n', '\\n')}');
        stdout.writeln('    Actual:   ${output.replaceAll('\n', '\\n')}');
        failures.add(name);
        failed++;
      }
    } catch (e) {
      stdout.writeln('  ERROR $name: $e');
      failures.add('$name (ERROR)');
      failed++;
    }
  }

  stdout.writeln('');
  stdout.writeln('Results: $passed passed, $failed failed, $skipped skipped '
      'out of ${testFiles.length} tests');

  if (failures.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Failures:');
    for (final f in failures) {
      stdout.writeln('  - $f');
    }
    exit(1);
  }
}
