/// Minimal Ball program runner: loads a `.ball.json` (Any-enveloped or bare
/// proto3-JSON Program), runs it on the Dart engine, and writes captured stdout.
///
///   cd dart/engine && dart run tool/run_program.dart <path/to/program.ball.json>
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: run_program.dart <program.ball.json>');
    exit(64);
  }
  final json =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final program = Program()
    ..mergeFromProto3Json(json, ignoreUnknownFields: true);
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add);
  await engine.run();
  stdout.write(lines.join('\n'));
}
