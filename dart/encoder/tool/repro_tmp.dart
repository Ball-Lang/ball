// Scratch: encode conformance fixture sources and diff engine output against
// native `dart run`. Deleted before commit.
import 'dart:io';

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';

Future<void> main() async {
  final fixtures = [
    '../../tests/conformance/src/320_num_methods_on_double_local.dart',
    '../../tests/conformance/src/321_whole_double_parse_print.dart',
    '../../tests/conformance/src/322_symbol_literal.dart',
  ];
  var failures = 0;
  for (final path in fixtures) {
    final src = File(path).readAsStringSync();
    final native = Process.runSync('dart', ['run', path]);
    if (native.exitCode != 0) {
      print('NATIVE FAIL $path\n${native.stderr}');
      failures++;
      continue;
    }
    final expected = (native.stdout as String).replaceAll('\r\n', '\n');
    final lines = <String>[];
    try {
      final program = DartEncoder().encode(src);
      final engine = BallEngine(program, stdout: lines.add);
      await engine.run();
    } catch (e) {
      print('ENGINE ERROR $path: $e');
      failures++;
      continue;
    }
    final actual = lines.map((l) => '$l\n').join();
    if (actual == expected) {
      print('PASS $path');
    } else {
      failures++;
      print('MISMATCH $path\n--- native ---\n$expected--- engine ---\n$actual');
    }
  }
  if (failures > 0) exitCode = 1;
}
