/// Quick TS compiler runner for iterative debugging. Reads a ball.json
/// and prints the emitted TypeScript. Not wired into test infra.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/ts_compiler.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: compile_ts <path/to/file.ball.json>');
    exit(1);
  }
  final json = File(args.first).readAsStringSync();
  final program = Program()
    ..mergeFromProto3Json(jsonDecode(json), ignoreUnknownFields: true);
  stdout.writeln(tsRuntimePreamble);
  stdout.writeln(TsCompiler(program).compile());
}
