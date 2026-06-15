/// Script to generate conformance test files from Dart source files.
///
/// For each NN_name.dart in tests/conformance/src/:
///   1. Runs the Dart source to capture expected output
///   2. Encodes it to Ball JSON via the DartEncoder
///   3. Writes NN_name.ball.json and NN_name.expected_output.txt
///
/// Spawning a Dart VM per source is the slow part, so sources are processed
/// with bounded concurrency, and each `dart run` is retried on transient
/// failure (VM startup under load occasionally returns non-zero) so CI
/// freshness checks are reliable.
///
/// Run from dart/encoder:
///   cd dart/encoder && dart run bin/generate_conformance.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ball_base/ball_base.dart' show encodeBallFileJson;
import 'package:ball_encoder/encoder.dart';

const _maxRunAttempts = 3;

Future<void> main() async {
  final srcDir = Directory('../../tests/conformance/src');
  final outDir = Directory('../../tests/conformance');

  if (!srcDir.existsSync()) {
    stderr.writeln('Source directory not found: ${srcDir.path}');
    exit(1);
  }

  final dartFiles =
      srcDir
          .listSync()
          .whereType<File>()
          .where(
            (f) => f.path.endsWith('.dart') && !f.path.contains('generate_'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  stdout.writeln('Found ${dartFiles.length} Dart source files to process.');

  var success = 0;
  var failed = 0;
  final failures = <String>[];

  // Pull from a shared work queue with bounded concurrency. Dart's event loop
  // is single-threaded, so the queue removal and counter mutations below are
  // atomic between awaits — only the `dart run`/encode I/O overlaps.
  final queue = List<File>.from(dartFiles);

  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final dartFile = queue.removeAt(0);
      final baseName = dartFile.uri.pathSegments.last.replaceAll('.dart', '');

      // Step 1: Run the Dart source to get expected output (with retry).
      ProcessResult? runResult;
      for (var attempt = 1; attempt <= _maxRunAttempts; attempt++) {
        runResult = await Process.run(
          'dart',
          ['run', dartFile.absolute.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (runResult.exitCode == 0) break;
      }

      if (runResult!.exitCode != 0) {
        stdout.writeln('  $baseName ... FAIL (runtime error)');
        stderr.writeln('    stderr: ${runResult.stderr}');
        failed++;
        failures.add(baseName);
        continue;
      }

      final expectedOutput = runResult.stdout as String;

      // Step 2: Encode to Ball JSON.
      try {
        final source = dartFile.readAsStringSync();
        final encoder = DartEncoder();
        final program = encoder.encode(source);
        final jsonStr = const JsonEncoder.withIndent(
          '  ',
        ).convert(encodeBallFileJson(program));

        // Step 3: Write output files. Trailing newline so the file is
        // POSIX-clean and byte-stable against the committed copies (which end
        // with '\n'); the conformance comparator trimRights output anyway.
        File('${outDir.path}/$baseName.ball.json').writeAsStringSync('$jsonStr\n');
        File(
          '${outDir.path}/$baseName.expected_output.txt',
        ).writeAsStringSync(expectedOutput);

        stdout.writeln('  $baseName ... OK');
        success++;
      } catch (e) {
        stdout.writeln('  $baseName ... FAIL (encode error)');
        stderr.writeln('    error: $e');
        failed++;
        failures.add(baseName);
      }
    }
  }

  final concurrency = math.max(1, math.min(6, Platform.numberOfProcessors - 1));
  await Future.wait(List.generate(concurrency, (_) => worker()));

  stdout.writeln('');
  stdout.writeln('Done: $success succeeded, $failed failed.');
  if (failed > 0) {
    failures.sort();
    stdout.writeln('Failed: ${failures.join(', ')}');
    exit(1);
  }
}
