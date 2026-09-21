/// Interpreted ≡ compiled, for the fourteen lowerings #654 added.
///
/// `base_call_dispatch_completeness_test.dart` proves every DECLARED base
/// function HAS a lowering and that the emitted source has the expected shape.
/// Shape is not meaning: `list_take` lowering to `.skip(n)` would pass every
/// assertion there and compute the wrong answer.
///
/// These names are unreachable from the Dart ENCODER, so the ordinary proof —
/// a `tests/conformance/src/NN_*.dart` fixture whose golden is real `dart run`
/// output — cannot exist for them: `generate_conformance.dart` encodes Dart
/// source, and no Dart source encodes to `std_collections.list_zip`. That is
/// precisely why they went unimplemented for so long. The equivalent proof for
/// a hand-authored Ball program is to run it BOTH ways and compare:
///
///     Ball program P
///        → BallEngine(P)                → interpreted stdout
///        → DartCompiler(P) → `dart run` → compiled stdout
///
/// and to pin both against an expected transcript, so "they agree" cannot mean
/// "they agree on the wrong answer".
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_engine/engine.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

// ── Ball IR builders ───────────────────────────────────────────────────────

Expression _int(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));

Expression _double(double d) =>
    Expression()..literal = (Literal()..doubleValue = d);

Expression _str(String s) =>
    Expression()..literal = (Literal()..stringValue = s);

Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);

Expression _list(List<Expression> elements) =>
    Expression()
      ..literal = (Literal()
        ..listValue = (ListLiteral()..elements.addAll(elements)));

FieldValuePair _f(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

Expression _msg(List<FieldValuePair> fields) =>
    Expression()
      ..messageCreation = (MessageCreation()
        ..typeName = ''
        ..fields.addAll(fields));

Expression _call(String module, String function, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = module
        ..function = function
        ..input = _msg(fields));

/// A Ball lambda is a `FunctionDefinition` with an empty name; its parameter is
/// the reference `input` (see `proto/ball/v1/ball.proto`).
///
/// The parameter LIST is cosmetic metadata, exactly as the encoder emits it
/// (`metadata['params']`), so the compiled Dart is `(input) => …` rather than
/// `() => …`; the engine binds `input` from the call, not from metadata.
Expression _lambda(Expression body) {
  final fn = FunctionDefinition()
    ..name = ''
    ..body = body;
  fn.mergeFromProto3Json({
    'metadata': {
      'params': [
        {'name': 'input'},
      ],
      'expression_body': true,
    },
  });
  return Expression()..lambda = fn;
}

/// A map literal, built the way the encoder builds one: `std.map_create` with
/// one repeated `entry` field per pair.
Expression _map(Map<String, Expression> pairs) =>
    Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = 'map_create'
        ..input = _msg([
          for (final e in pairs.entries)
            _f('entry', _msg([_f('key', _str(e.key)), _f('value', e.value)])),
        ]));

/// `{key: …, value: …}` — the pair shape `map_from_entries` reads and the one
/// `map_map` / `map_filter` hand their callback.
Expression _entry(String key, Expression value) =>
    _map({'key': _str(key), 'value': value});

Statement _print(Expression value) =>
    Statement()..expression = _call('std', 'print', [_f('message', value)]);

// ── The transcript under test ──────────────────────────────────────────────

/// One statement per case, and the exact line each must print.
///
/// The expected values are plain Dart semantics: `[1,2,3].take(2).toList()` is
/// `[1, 2]`, `{...{'a': 1}, ...{'b': 2, 'a': 9}}` is `{a: 9, b: 2}` (the
/// first-seen key keeps its position and the later value wins), `3.toDouble()`
/// prints `3.0`, and `3.7.toInt()` truncates toward zero.
final _cases = <({String label, Expression value, String expected})>[
  (
    label: 'list_take',
    value: _call('std_collections', 'list_take', [
      _f('list', _list([_int(1), _int(2), _int(3)])),
      _f('value', _int(2)),
    ]),
    expected: '[1, 2]',
  ),
  (
    label: 'list_drop',
    value: _call('std_collections', 'list_drop', [
      _f('list', _list([_int(1), _int(2), _int(3)])),
      _f('value', _int(1)),
    ]),
    expected: '[2, 3]',
  ),
  (
    label: 'list_single',
    value: _call('std_collections', 'list_single', [
      _f('list', _list([_int(7)])),
    ]),
    expected: '7',
  ),
  (
    label: 'list_zip (truncates to the shorter operand)',
    value: _call('std_collections', 'list_zip', [
      _f('list', _list([_int(1), _int(2)])),
      _f('value', _list([_int(3), _int(4), _int(5)])),
    ]),
    expected: '[[1, 3], [2, 4]]',
  ),
  (
    label: 'list_none (no match)',
    value: _call('std_collections', 'list_none', [
      _f('list', _list([_int(1), _int(2)])),
      _f(
        'callback',
        _lambda(
          _call('std', 'greater_than', [
            _f('left', _ref('input')),
            _f('right', _int(5)),
          ]),
        ),
      ),
    ]),
    expected: 'true',
  ),
  (
    label: 'list_none (a match)',
    value: _call('std_collections', 'list_none', [
      _f('list', _list([_int(1), _int(6)])),
      _f(
        'callback',
        _lambda(
          _call('std', 'greater_than', [
            _f('left', _ref('input')),
            _f('right', _int(5)),
          ]),
        ),
      ),
    ]),
    expected: 'false',
  ),
  (
    label: 'list_sort_by (descending, via a negated key)',
    value: _call('std_collections', 'list_sort_by', [
      _f('list', _list([_int(3), _int(1), _int(2)])),
      _f(
        'callback',
        _lambda(_call('std', 'negate', [_f('value', _ref('input'))])),
      ),
    ]),
    expected: '[3, 2, 1]',
  ),
  (
    label: 'map_merge (right wins, first-seen key keeps its position)',
    value: _call('std_collections', 'map_merge', [
      _f('map', _map({'a': _int(1)})),
      _f('value', _map({'b': _int(2), 'a': _int(9)})),
    ]),
    expected: '{a: 9, b: 2}',
  ),
  (
    label: 'map_from_entries',
    value: _call('std_collections', 'map_from_entries', [
      _f('list', _list([_entry('a', _int(1)), _entry('b', _int(2))])),
    ]),
    expected: '{a: 1, b: 2}',
  ),
  (
    label: 'map_map (callback receives the {key, value} pair)',
    value: _call('std_collections', 'map_map', [
      _f('map', _map({'a': _int(1), 'b': _int(2)})),
      _f(
        'callback',
        _lambda(
          _call('std', 'multiply', [
            _f(
              'left',
              _call('std_collections', 'map_get', [
                _f('map', _ref('input')),
                _f('key', _str('value')),
              ]),
            ),
            _f('right', _int(10)),
          ]),
        ),
      ),
    ]),
    expected: '{a: 10, b: 20}',
  ),
  (
    label: 'map_filter',
    value: _call('std_collections', 'map_filter', [
      _f('map', _map({'a': _int(1), 'b': _int(2)})),
      _f(
        'callback',
        _lambda(
          _call('std', 'greater_than', [
            _f(
              'left',
              _call('std_collections', 'map_get', [
                _f('map', _ref('input')),
                _f('key', _str('value')),
              ]),
            ),
            _f('right', _int(1)),
          ]),
        ),
      ),
    ]),
    expected: '{b: 2}',
  ),
  (
    label: 'set_create under its DECLARED module',
    value: _call('std_collections', 'set_create', [
      _f('elements', _list([_int(1), _int(2), _int(2)])),
    ]),
    expected: '{1, 2}',
  ),
  (
    label: 'int_to_double',
    value: _call('std', 'int_to_double', [_f('value', _int(3))]),
    expected: '3.0',
  ),
  (
    label: 'double_to_int (truncates toward zero)',
    value: _call('std', 'double_to_int', [_f('value', _double(3.7))]),
    expected: '3',
  ),
  (
    label: 'string_interpolation',
    value: _call('std', 'string_interpolation', [
      _f('parts', _list([_str('n='), _int(5)])),
    ]),
    expected: 'n=5',
  ),
];

/// Every base function the program above calls, by module. A Ball module is a
/// BASE module only when every function it declares is base, so these two lists
/// are also what puts `std` / `std_collections` into the compiler's
/// `_baseModules`.
const _stdFunctions = <String>[
  'print',
  'greater_than',
  'multiply',
  'negate',
  'map_create',
  'int_to_double',
  'double_to_int',
  'string_interpolation',
];

const _collectionsFunctions = <String>[
  'list_take',
  'list_drop',
  'list_single',
  'list_zip',
  'list_none',
  'list_sort_by',
  'map_merge',
  'map_from_entries',
  'map_map',
  'map_filter',
  'map_get',
  'set_create',
];

Program _program() {
  Module baseModule(String name, List<String> functions) => Module()
    ..name = name
    ..functions.addAll([
      for (final f in functions)
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);

  return Program()
    ..name = 'declared_base_call_equivalence'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      baseModule('std', _stdFunctions),
      baseModule('std_collections', _collectionsFunctions),
      Module()
        ..name = 'main'
        ..functions.add(
          FunctionDefinition()
            ..name = 'main'
            ..body = (Expression()
              ..block = (Block()
                ..statements.addAll([
                  for (final c in _cases) _print(c.value),
                ]))),
        ),
    ]);
}

List<String> _lines(String s) => const LineSplitter()
    .convert(s.replaceAll('\r\n', '\n'))
    .where((l) => l.isNotEmpty)
    .toList();

void main() {
  group(
    'the #654 lowerings mean what the reference engine means',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      final program = _program();
      final expected = [for (final c in _cases) c.expected];

      test('the transcript is not empty', () {
        // Positive floor: an empty case list would make both legs agree on
        // nothing at all.
        expect(_cases.length, greaterThanOrEqualTo(14));
      });

      test('the reference ENGINE prints the expected transcript', () async {
        final out = <String>[];
        await BallEngine(program, stdout: out.add).run();
        expect(out, equals(expected));
      });

      test('the COMPILED Dart prints the same transcript', () async {
        final source = DartCompiler(program).compile();
        final dir = Directory.systemTemp.createTempSync('ball_654_equiv');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        final file = File('${dir.path}/subject.dart')
          ..writeAsStringSync(source);

        final run = await Process.run(
          Platform.resolvedExecutable,
          ['run', file.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );

        expect(
          run.exitCode,
          0,
          reason:
              'the compiled program did not run\n'
              '--- stderr ---\n${run.stderr}\n'
              '--- source ---\n$source',
        );
        expect(
          _lines(run.stdout as String),
          equals(expected),
          reason: 'compiled output diverged\n--- source ---\n$source',
        );
      });
    },
  );
}
