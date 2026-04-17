/// Batch compile FFmpeg ball files (JSON or binary protobuf) to Dart.
///
/// Usage:
///   dart run ffmpeg_dart_test.dart [ballDir] [dartOutDir] [maxFiles]
///
/// Reads .ball.json or .ball.pb files from [ballDir], compiles each to Dart via
/// [DartCompiler], and writes the result to [dartOutDir].  Prints a
/// success/failure summary at the end.
import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:protobuf/protobuf.dart';

void main(List<String> args) {
  final ballDir = args.isNotEmpty
      ? args[0]
      : r'd:\packages\ball\ffmpeg_test_output\ball_bin';
  final dartOutDir = args.length > 1
      ? args[1]
      : r'd:\packages\ball\ffmpeg_test_output\dart_compiled';
  final maxFiles = args.length > 2 ? int.tryParse(args[2]) ?? 0 : 0;

  final dir = Directory(ballDir);
  if (!dir.existsSync()) {
    stderr.writeln('Ball directory not found: $ballDir');
    exit(1);
  }

  Directory(dartOutDir).createSync(recursive: true);

  var ballFiles =
      dir
          .listSync()
          .whereType<File>()
          .where(
            (f) => f.path.endsWith('.ball.json') || f.path.endsWith('.ball.pb'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  if (maxFiles > 0) ballFiles = ballFiles.take(maxFiles).toList();

  final total = ballFiles.length;
  var ok = 0;
  var fail = 0;
  var formatFail = 0;
  final failures = <String, String>{};
  final formatFailures = <String, String>{};

  stdout.writeln('=== FFmpeg Ball → Dart Compilation ===');
  stdout.writeln('Input:  $ballDir ($total files)');
  stdout.writeln('Output: $dartOutDir');
  stdout.writeln();

  for (var i = 0; i < ballFiles.length; i++) {
    final file = ballFiles[i];
    final isBinary = file.path.endsWith('.ball.pb');
    final name = file.uri.pathSegments.last
        .replaceAll('.ball.json', '')
        .replaceAll('.ball.pb', '');

    try {
      final Program program;
      if (isBinary) {
        final bytes = file.readAsBytesSync();
        final reader = CodedBufferReader(bytes, recursionLimit: 10000);
        program = Program()..mergeFromCodedBufferReader(reader);
      } else {
        final jsonStr = file.readAsStringSync();
        final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        program = Program()..mergeFromProto3Json(jsonMap);
      }

      final compiler = DartCompiler(program);

      // Try full compile (with main entry), fall back to module compile,
      // then raw module compile.
      String dartSource;
      bool isFormatIssue = false;
      String? formatIssueMsg;
      try {
        dartSource = compiler.compile();
      } catch (compileError) {
        // Entry point not found or format error — try compileModule.
        try {
          dartSource = compiler.compileModule(program.entryModule);
        } catch (moduleError) {
          // Format error — try raw output.
          try {
            dartSource = compiler.compileModuleRaw(program.entryModule);
            isFormatIssue = true;
            formatIssueMsg = moduleError.toString().split('\n').first;
          } catch (rawErr) {
            rethrow;
          }
        }
      }

      if (isFormatIssue) {
        formatFail++;
        formatFailures[name] = formatIssueMsg!;
      }

      final outFile = File('$dartOutDir/$name.dart');
      outFile.writeAsStringSync(dartSource);
      ok++;

      if ((i + 1) % 25 == 0 || i == ballFiles.length - 1) {
        stdout.writeln('  [${i + 1}/$total] $ok ok, $fail fail');
      }
    } catch (e) {
      fail++;
      final msg = e.toString().split('\n').first;
      failures[name] = msg;
      if ((i + 1) % 25 == 0 || i == ballFiles.length - 1) {
        stdout.writeln('  [${i + 1}/$total] $ok ok, $fail fail');
      }
    }
  }

  stdout.writeln();
  stdout.writeln('=== DART COMPILATION SUMMARY ===');
  stdout.writeln('Total files:   $total');
  stdout.writeln('Success:       $ok');
  stdout.writeln('Format issues: $formatFail (raw source emitted)');
  stdout.writeln('Failures:      $fail');
  if (total > 0) {
    stdout.writeln('Success rate:  ${(ok / total * 100).toStringAsFixed(1)}%');
  }

  if (failures.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('--- Failures ---');
    for (final entry in failures.entries) {
      stdout.writeln('  ${entry.key}: ${entry.value}');
    }
  }

  if (formatFailures.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('--- Format issues (raw output emitted) ---');
    for (final entry in formatFailures.entries.take(10)) {
      stdout.writeln('  ${entry.key}: ${entry.value}');
    }
    if (formatFailures.length > 10) {
      stdout.writeln('  ... and ${formatFailures.length - 10} more');
    }
  }

  // Write machine-readable results
  final results = {
    'total': total,
    'ok': ok,
    'format_issues': formatFail,
    'failures': fail,
    'success_rate': total > 0 ? (ok / total * 100) : 0,
    'failure_details': failures,
    'format_failure_details': formatFailures,
  };
  File(
    '$dartOutDir/../dart_results.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
}
