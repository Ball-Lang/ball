/// Generates the `ball_proto` base module (JSON + binary protobuf).
///
/// Usage:
///   dart run ball_base:gen_ball_proto [output_dir]
///
/// Outputs:
///   ball_proto.json — proto3 JSON (human-readable)
///   ball_proto.bin  — binary protobuf (compact)
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_proto.dart';

void main(List<String> args) {
  final outputDir = args.isNotEmpty ? args[0] : '.';

  final module = buildBallProtoModule();

  // Proto3 JSON
  final jsonOutput = module.toProto3Json();
  final jsonString = const JsonEncoder.withIndent('  ').convert(jsonOutput);
  File('$outputDir/ball_proto.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('$jsonString\n');

  // Binary protobuf
  File('$outputDir/ball_proto.bin').writeAsBytesSync(module.writeToBuffer());

  stderr.writeln(
    'Generated ball_proto module: '
    '${module.functions.length} functions',
  );
  stderr.writeln('  -> $outputDir/ball_proto.json');
  stderr.writeln('  -> $outputDir/ball_proto.bin');
}
