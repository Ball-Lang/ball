import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart' show decodeProgramJson;
import 'package:ball_engine/engine.dart';

Future<List<String>> runFixture(String name) async {
  final f = File('../../tests/conformance/$name.ball.json');
  final program = decodeProgramJson(jsonDecode(f.readAsStringSync()));
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add);
  await engine.run();
  return lines;
}

Future<void> main() async {
  final failures = [
    '140_caesar_cipher',
    '146_nested_try_catch_types',
    '150_state_machine',
    '151_recursive_descent_parser',
    '155_pipeline_compose',
    '162_generator_sync',
    '163_generator_async',
    '174_generator_yield_star',
    '175_generator_empty_return',
    '176_generator_early_return',
    '183_type_patterns',
    '184_nested_patterns',
    '185_std_convert',
    '199_malicious_input_patterns',
    '209_generator_filtered_state',
    '216_int_double_truncation',
    '239_switch_expr_relational',
    '255_string_surrogate_astral',
    '89_tower_of_hanoi',
  ];

  var pass = 0;
  var fail = 0;
  var exc = 0;
  for (final name in failures) {
    final exp = File('../../tests/conformance/$name.expected_output.txt');
    final expected = exp.readAsStringSync().replaceAll('\r\n', '\n').trim();
    try {
      final lines = await runFixture(name);
      final out = lines.join('\n').trim();
      if (out == expected) {
        stdout.writeln('$name: PASS');
        pass++;
      } else {
        stdout.writeln('$name: FAIL');
        fail++;
      }
    } catch (e) {
      stdout.writeln('$name: EXCEPTION $e');
      exc++;
    }
  }
  stdout.writeln('\nDart engine: $pass pass, $fail fail, $exc exception');
}
