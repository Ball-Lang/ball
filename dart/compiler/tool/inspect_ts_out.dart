/// Diagnostic tool — print the structural TS output for a Dart source
/// fixture. Run:
///
///   dart run dart/compiler/tool/inspect_ts_out.dart tests/fixtures/compiler/ts/class_basics.dart
library;

import 'dart:io';

import 'package:ball_compiler/ts_compiler.dart';
import 'package:ball_encoder/encoder.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: inspect_ts_out.dart <path-to-dart-source>');
    exit(64);
  }
  final src = File(args[0]).readAsStringSync();
  final prog = DartEncoder().encode(src, name: 'inspect');
  final out = await TsCompiler(prog).compileStructural();
  stdout.write(out);
}
