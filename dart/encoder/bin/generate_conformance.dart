/// Script to generate conformance test files from Dart source files.
///
/// For each NN_name.dart in tests/conformance/src/:
///   1. Runs the Dart source to capture expected output
///   2. Encodes it to Ball JSON via the DartEncoder
///   3. Writes NN_name.ball.json and NN_name.expected_output.txt
///
/// Run from dart/encoder:
///   cd dart/encoder && dart run bin/generate_conformance.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_encoder/encoder.dart';

Future<void> main() async {
  final srcDir = Directory('../../tests/conformance/src');
  final outDir = Directory('../../tests/conformance');

  if (!srcDir.existsSync()) {
    stderr.writeln('Source directory not found: ${srcDir.path}');
    exit(1);
  }

  final dartFiles = srcDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.contains('generate_'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  stdout.writeln('Found ${dartFiles.length} Dart source files to process.');

  var success = 0;
  var failed = 0;

  for (final dartFile in dartFiles) {
    final baseName =
        dartFile.uri.pathSegments.last.replaceAll('.dart', '');
    stdout.write('  $baseName ... ');

    // Step 1: Run the Dart source to get expected output
    final runResult = await Process.run(
      'dart',
      ['run', dartFile.absolute.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (runResult.exitCode != 0) {
      stdout.writeln('FAIL (runtime error)');
      stderr.writeln('    stderr: ${runResult.stderr}');
      failed++;
      continue;
    }

    final expectedOutput = (runResult.stdout as String);

    // Step 2: Encode to Ball JSON
    try {
      final source = dartFile.readAsStringSync();
      final encoder = DartEncoder();
      final program = encoder.encode(source);
      final jsonStr =
          const JsonEncoder.withIndent('  ').convert(program.toProto3Json());

      // Step 3: Write output files
      final ballFile = File('${outDir.path}/$baseName.ball.json');
      final expectedFile = File('${outDir.path}/$baseName.expected_output.txt');

      ballFile.writeAsStringSync(jsonStr);
      expectedFile.writeAsStringSync(expectedOutput);

      stdout.writeln('OK');
      success++;
    } catch (e) {
      stdout.writeln('FAIL (encode error)');
      stderr.writeln('    error: $e');
      failed++;
    }
  }

  stdout.writeln('');
  stdout.writeln('Done: $success succeeded, $failed failed.');
  if (failed > 0) exit(1);
}
