/// Round-trip fidelity tests for the full Ball pipeline:
///
///   Dart source → DartEncoder → BallEngine → captured stdout
///                                    ↕
///                        `dart run` the original Dart source
///
/// Each test takes a small Dart program, runs it two ways, and asserts
/// both produce the same stdout. This is the strongest fidelity check
/// available: any divergence means the encoder dropped semantics that
/// the engine would have reproduced. Historically every pass through
/// round-trip testing catches something unit tests missed.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Small Dart programs paired with their expected stdout. Each program
/// should fit on screen and cover one language feature — easier to
/// triage than a single blob.
final _programs = <({String name, String source, String expected})>[
  (
    name: 'hello',
    source: "void main() { print('hello'); }",
    expected: 'hello',
  ),
  (
    name: 'arithmetic',
    source: "void main() { print((1 + 2 * 3).toString()); }",
    expected: '7',
  ),
  (
    name: 'variable_assignment',
    source: '''
void main() {
  var x = 10;
  x = x + 5;
  print(x.toString());
}
''',
    expected: '15',
  ),
  (
    name: 'if_else',
    source: '''
void main() {
  var x = 3;
  if (x > 0) {
    print('pos');
  } else {
    print('neg');
  }
}
''',
    expected: 'pos',
  ),
  (
    name: 'while_loop',
    source: '''
void main() {
  var i = 1;
  while (i <= 3) {
    print(i.toString());
    i = i + 1;
  }
}
''',
    expected: '1\n2\n3',
  ),
  (
    name: 'for_loop',
    source: '''
void main() {
  for (var i = 0; i < 3; i = i + 1) {
    print(i.toString());
  }
}
''',
    expected: '0\n1\n2',
  ),
  (
    name: 'function_call',
    source: '''
int doubleIt(int n) => n * 2;
void main() {
  print(doubleIt(21).toString());
}
''',
    expected: '42',
  ),
  (
    name: 'recursive_function',
    source: '''
int factorial(int n) {
  if (n <= 1) return 1;
  return n * factorial(n - 1);
}
void main() {
  print(factorial(5).toString());
}
''',
    expected: '120',
  ),
  (
    name: 'string_concat',
    source: "void main() { print('hello, ' + 'world'); }",
    expected: 'hello, world',
  ),
  (
    name: 'nested_if',
    source: '''
void main() {
  var x = 5;
  if (x > 0) {
    if (x > 3) {
      print('big');
    } else {
      print('small-pos');
    }
  }
}
''',
    expected: 'big',
  ),
  (
    name: 'comparison_ops',
    source: '''
void main() {
  var a = 5;
  var b = 3;
  print((a > b).toString());
  print((a < b).toString());
  print((a == b).toString());
  print((a != b).toString());
}
''',
    expected: 'true\nfalse\nfalse\ntrue',
  ),
  (
    name: 'string_interpolation',
    source: '''
void main() {
  var name = 'world';
  print('hello, \$name');
}
''',
    expected: 'hello, world',
  ),
  (
    name: 'break_and_continue',
    source: '''
void main() {
  var sum = 0;
  for (var i = 0; i < 10; i = i + 1) {
    if (i == 5) break;
    if (i % 2 == 0) continue;
    sum = sum + i;
  }
  print(sum.toString());
}
''',
    expected: '4', // 1 + 3
  ),
  (
    name: 'try_catch_format',
    source: '''
void main() {
  try {
    int.parse('not a number');
  } on FormatException catch (e) {
    print('caught-format');
  }
  print('after');
}
''',
    expected: 'caught-format\nafter',
  ),
  (
    name: 'list_length',
    source: '''
void main() {
  var xs = [1, 2, 3, 4];
  print(xs.length.toString());
}
''',
    expected: '4',
  ),
  (
    name: 'nested_function',
    source: '''
int add(int a, int b) => a + b;
int addOne(int x) => add(x, 1);
void main() {
  print(addOne(41).toString());
}
''',
    expected: '42',
  ),
  (
    name: 'multi_line_string',
    source: r'''
void main() {
  var s = 'line1\nline2';
  print(s);
}
''',
    expected: 'line1\nline2',
  ),
  (
    name: 'early_return',
    source: '''
int firstPositive(int a, int b) {
  if (a > 0) return a;
  if (b > 0) return b;
  return 0;
}
void main() {
  print(firstPositive(-1, 5).toString());
  print(firstPositive(-1, -2).toString());
}
''',
    expected: '5\n0',
  ),
];

String _norm(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

Future<String> _runViaEngine(String source) async {
  final program = DartEncoder().encode(source);
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add);
  await engine.run();
  return _norm(lines.join('\n'));
}

String _runViaDart(String source, Directory scratch, String name) {
  final file = File('${scratch.path}/$name.dart');
  file.writeAsStringSync(source);
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', file.absolute.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail(
      'dart run of $name failed (rc=${result.exitCode})\n'
      'stderr:\n${result.stderr}',
    );
  }
  return _norm(result.stdout as String);
}

void main() {
  group('round-trip: Dart source → encoder → engine', () {
    late final Directory scratch;
    setUpAll(() {
      scratch = Directory.systemTemp.createTempSync('ball_round_trip_');
    });
    tearDownAll(() {
      try {
        scratch.deleteSync(recursive: true);
      } catch (_) {}
    });

    for (final p in _programs) {
      test('${p.name}: engine matches expected', () async {
        final engineOutput = await _runViaEngine(p.source);
        expect(
          engineOutput,
          equals(_norm(p.expected)),
          reason: 'engine output mismatch for ${p.name}',
        );
      });

      test('${p.name}: engine matches `dart run`', () async {
        final engineOutput = await _runViaEngine(p.source);
        final dartOutput = _runViaDart(p.source, scratch, p.name);
        expect(
          engineOutput,
          equals(dartOutput),
          reason:
              'engine/dart divergence for ${p.name}\n'
              '--- engine ---\n$engineOutput\n'
              '--- dart run ---\n$dartOutput',
        );
      });
    }
  });
}
