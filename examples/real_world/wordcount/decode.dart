/// Compile ball/wordcount.ball.json back to Dart at compiled/wordcount.dart.
///
/// Run from examples/real_world/wordcount/:
///   dart run decode.dart
///
/// Mirror of encode.dart — read one Ball program, emit Dart source.
/// Kept small on purpose: the whole pipeline is a handful of function
/// calls that a new contributor can read in a minute.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';

void main() {
  final jsonStr = File('ball/wordcount.ball.json').readAsStringSync();
  final program = Program()
    ..mergeFromProto3Json(json.decode(jsonStr) as Map<String, dynamic>);

  final compiler = DartCompiler(program);
  final dartSource = compiler.compile();

  Directory('compiled').createSync(recursive: true);
  File('compiled/wordcount.dart').writeAsStringSync(dartSource);

  stdout.writeln(
    'Compiled Ball program back to Dart '
    '(${dartSource.length} bytes) → compiled/wordcount.dart',
  );
}
