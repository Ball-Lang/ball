/// Encode src/wordcount.dart into a Ball program at ball/wordcount.ball.json.
///
/// Run from examples/real_world/wordcount/:
///   dart run encode.dart
///
/// This is a minimal wrapper around DartEncoder, shown inline so the
/// demo is self-documenting: you can read this file and understand
/// exactly what "encode a Dart program to Ball" means.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_encoder/encoder.dart';

void main() {
  final src = File('src/wordcount.dart').readAsStringSync();

  final encoder = DartEncoder();
  final program = encoder.encode(src, name: 'wordcount');

  if (encoder.warnings.isNotEmpty) {
    for (final w in encoder.warnings) {
      stderr.writeln('warning: $w');
    }
  }

  Directory('ball').createSync(recursive: true);
  final jsonOut = const JsonEncoder.withIndent(
    '  ',
  ).convert(program.toProto3Json());
  File('ball/wordcount.ball.json').writeAsStringSync(jsonOut);

  stdout.writeln('Encoded ${src.length} bytes of Dart into a Ball program');
  stdout.writeln('  modules:    ${program.modules.length}');
  stdout.writeln('  functions:  '
      '${program.modules.fold<int>(0, (s, m) => s + m.functions.length)}');
  stdout.writeln('  output:     ball/wordcount.ball.json '
      '(${jsonOut.length} bytes JSON)');
}
