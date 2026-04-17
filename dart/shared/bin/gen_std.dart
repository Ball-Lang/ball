/// Generates the universal std base module for ball.
///
/// This script is language-agnostic — it produces the `std` [Module] that
/// every target language compiler (Dart, Go, Python, …) must implement.
///
/// Usage:
///   dart run ball_base:gen_std [output_dir]
///
/// Outputs:
///   std.json — proto3 JSON (human-readable, used by compilers & tooling)
///   std.bin  — binary protobuf (compact, used for cross-language tooling)
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/std.dart';

void main(List<String> args) {
  final outputDir = args.isNotEmpty ? args[0] : '.';

  final module = buildStdModule();

  // Proto3 JSON
  final jsonOutput = module.toProto3Json();
  final jsonString = const JsonEncoder.withIndent('  ').convert(jsonOutput);
  File('$outputDir/std.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('$jsonString\n');

  // Binary protobuf
  File('$outputDir/std.bin').writeAsBytesSync(module.writeToBuffer());

  stderr.writeln(
    'Generated std base module: '
    '${module.types.length} types, '
    '${module.functions.length} functions',
  );
  stderr.writeln('  -> $outputDir/std.json');
  stderr.writeln('  -> $outputDir/std.bin');
}
