/// Encode a Dart source file and print the resulting Ball program's
/// JSON form (for debugging encoder output during TS compile issues).
///
///   dart run dart/compiler/tool/inspect_ball_json.dart <path>
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_encoder/encoder.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: inspect_ball_json.dart <path-to-dart-source>');
    exit(64);
  }
  final src = File(args[0]).readAsStringSync();
  final prog = DartEncoder().encode(src, name: 'inspect');
  final json = JsonEncoder.withIndent('  ').convert(prog.toProto3Json());
  stdout.writeln(json);
}
