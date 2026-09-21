/// A SINGLE-parameter callee must receive its input bag WHOLE unless that bag
/// is a single positional argument (issue #740).
///
/// The engine's calling convention is "one input, one output": a call site that
/// knows the callee's parameter names packs `{name: …}`, and one that does not
/// (a first-class `invoke`, or a compiler that lowered every function to "take
/// the whole message") packs `{arg0: …, arg1: …}`. Before this fix the
/// single-parameter binding path in `engine_invocation.dart` unwrapped `arg0`
/// from ANY bag that carried it, so:
///
///   * a callee whose sole parameter IS the whole message (the shape every
///     re-encoded compiler output has — `Ball__add(BallValue __in)` reading
///     `__in["a"] ?? __in["arg0"]`) was handed the bare `arg0` value and lost
///     `arg1` entirely; and
///   * a callee whose sole parameter is a genuine map/record that happens to
///     carry an `arg0` key was handed that key's value instead of the record.
///
/// Both are the same defect: `arg0` is only the sole argument when it is the
/// bag's ONLY argument. This was surfaced (not introduced) by PR #730's C#
/// `BallRuntime.ArgGet` work and recorded as prose in `.claude/rules/csharp.md`
/// until #740.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

Map<String, dynamic> _intLit(int v) => {
  'literal': {'intValue': '$v'},
};

Map<String, dynamic> _strLit(String v) => {
  'literal': {'stringValue': v},
};

Map<String, dynamic> _ref(String name) => {
  'reference': {'name': name},
};

Map<String, dynamic> _field(String name, Map<String, dynamic> value) => {
  'name': name,
  'value': value,
};

Map<String, dynamic> _msg(List<Map<String, dynamic>> fields) => {
  'messageCreation': {'typeName': '', 'fields': fields},
};

Map<String, dynamic> _fieldAccess(Map<String, dynamic> object, String field) =>
    {
      'fieldAccess': {'object': object, 'field': field},
    };

Map<String, dynamic> _stdCall(String fn, Map<String, dynamic> input) => {
  'call': {'module': 'std', 'function': fn, 'input': input},
};

Map<String, dynamic> _userCall(String fn, Map<String, dynamic> input) => {
  'call': {'function': fn, 'input': input},
};

Map<String, dynamic> _print(Map<String, dynamic> value) => _stdCall(
  'print',
  _msg([
    _field('message', _stdCall('to_string', _msg([_field('value', value)]))),
  ]),
);

/// A two-module program: the universal `std` declaration the engine requires,
/// plus `main` carrying the callee and a `main` that invokes it.
Program _program({
  required String calleeName,
  required List<Map<String, String>> params,
  required Map<String, dynamic> body,
  required Map<String, dynamic> input,
}) {
  final json = {
    'name': 'single_param_input_bag',
    'version': '1.0.0',
    'modules': [
      {
        'name': 'std',
        'functions': [
          {'name': 'print', 'isBase': true, 'inputType': 'dynamic'},
          {'name': 'to_string', 'isBase': true, 'inputType': 'dynamic'},
          {'name': 'add', 'isBase': true, 'inputType': 'dynamic'},
        ],
      },
      {
        'name': 'main',
        'functions': [
          {
            'name': calleeName,
            'inputType': 'dynamic',
            'outputType': 'dynamic',
            'metadata': {
              'kind': 'function',
              'params': params
                  .map((p) => {'name': p['name'], 'type': p['type']})
                  .toList(),
            },
            'body': body,
          },
          {
            'name': 'main',
            'body': {
              'block': {
                'statements': [
                  {'expression': _print(_userCall(calleeName, input))},
                ],
              },
            },
          },
        ],
      },
    ],
    'entryModule': 'main',
    'entryFunction': 'main',
  };
  return Program()..mergeFromProto3Json(json);
}

Future<List<String>> _run(Program program) async {
  final lines = <String>[];
  await BallEngine(program, stdout: lines.add).run();
  return lines;
}

void main() {
  group('engine: a single-parameter callee and its input bag (#740)', () {
    test('a bag carrying TWO positional arguments arrives whole', () async {
      // The re-encoded compiler shape: one parameter that IS the message.
      // Before #740 `__in` was bound to the bare `arg0` value (3) and the
      // field access below failed loud with `Field "arg0" not found`.
      final program = _program(
        calleeName: 'sum_of_bag',
        params: const [
          {'name': '__in', 'type': 'dynamic'},
        ],
        body: _stdCall(
          'add',
          _msg([
            _field('left', _fieldAccess(_ref('__in'), 'arg0')),
            _field('right', _fieldAccess(_ref('__in'), 'arg1')),
          ]),
        ),
        input: _msg([_field('arg0', _intLit(3)), _field('arg1', _intLit(4))]),
      );
      expect(await _run(program), ['7']);
    });

    test('a record argument that carries an arg0 key survives', () async {
      // The sole parameter is a genuine record whose own fields happen to
      // include `arg0`. Before #740 `rec` was bound to 1 and the `label`
      // access failed loud.
      final program = _program(
        calleeName: 'label_of',
        params: const [
          {'name': 'rec', 'type': 'dynamic'},
        ],
        body: _fieldAccess(_ref('rec'), 'label'),
        input: _msg([
          _field('arg0', _intLit(1)),
          _field('label', _strLit('pt')),
        ]),
      );
      expect(await _run(program), ['pt']);
    });

    test('a bag carrying ONE positional argument still unwraps', () async {
      // The established convention a first-class `invoke` relies on:
      // `{arg0: v}` IS the single argument, so the sole parameter binds to
      // `v`, not to the bag. Green before #740 and must stay green.
      final program = _program(
        calleeName: 'double_it',
        params: const [
          {'name': 'n', 'type': 'dynamic'},
        ],
        body: _stdCall(
          'add',
          _msg([_field('left', _ref('n')), _field('right', _ref('n'))]),
        ),
        input: _msg([_field('arg0', _intLit(21))]),
      );
      expect(await _run(program), ['42']);
    });

    test('a bag keyed by the parameter NAME still wins over arg0', () async {
      // By-name extraction is checked first and is unaffected: a bag carrying
      // both the parameter's own name and a positional key binds the name.
      final program = _program(
        calleeName: 'double_it',
        params: const [
          {'name': 'n', 'type': 'dynamic'},
        ],
        body: _stdCall(
          'add',
          _msg([_field('left', _ref('n')), _field('right', _ref('n'))]),
        ),
        input: _msg([_field('n', _intLit(5)), _field('arg0', _intLit(99))]),
      );
      expect(await _run(program), ['10']);
    });
  });
}
