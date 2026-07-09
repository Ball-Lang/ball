// Wave-6 tail-coverage tests for the engine `lib/` product code.
//
// A continuation of the wave-5 files (issue #61 / #261): targets branches
// left uncovered after the Phase-2c per-arm triage, re-measured against a
// fresh `dart run tools/coverage_dart.dart` baseline rather than stale line
// numbers (per #261's own ground rule). Every test builds a minimal Program
// and runs it through a real BallEngine, asserting on captured stdout — no
// mocking of engine internals.
//
//   * engine_std.dart      — `list_foreach`/`map_from_entries` false-arm
//                            coverage for the `else if (collection is Set)` /
//                            `else if (e is Map)` CONDITION lines (the arms
//                            themselves are already `coverage:ignore`d as
//                            unreachable per #261; the condition tests
//                            evaluating false for a plain non-collection value
//                            are real, distinct branches — mirrors the
//                            existing `list_to_list`'s sibling exclusion,
//                            which keeps the reachable condition covered and
//                            only ignores the unreachable body); the `is`/
//                            `type_check` base function's `Null` type arm.
//   * engine_eval.dart     — the wrapper-type (`BallInt`) receiver-unwrap
//                            arms of the `.isNegative`/`.sign`/`.abs`
//                            fieldAccess getters — reached the way a real
//                            embedder would produce such values: via a
//                            custom `BallModuleHandler` (`nat`) that returns
//                            wrapped/native values, mirroring
//                            engine_wave5_control_flow_coverage_test.dart's
//                            `_NatHandler` pattern.
//
// Field-name conventions match the engine's extractors: binary ops read
// left/right, unary ops read value, list ops read list/value/index/callback,
// map ops read map/key/value.
import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Self-contained builder helpers (independent of engine_test.dart). ──

/// A custom module whose functions return Ball value *wrappers* that the
/// Dart reference engine never mints from source literals (native `int`s
/// always stay native `int`) but that the interpreter's field-access dispatch
/// must still handle correctly — they arise on self-hosts / custom embedders
/// that hand the engine a `BallInt`.
class _NatHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'nat';

  @override
  FutureOr<Object?> call(String function, Object? input, BallCallable engine) {
    switch (function) {
      case 'bint':
        return const BallInt(-5);
      default:
        throw BallRuntimeError('Unknown nat function: "$function"');
    }
  }
}

Map<String, dynamic> _natModule() => {
  'name': 'nat',
  'functions': [
    for (final n in const ['bint']) {'name': n, 'isBase': true},
  ],
};

Future<List<String>> runAndCapture(Program program) async {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    moduleHandlers: [StdModuleHandler(), _NatHandler()],
  );
  await engine.run();
  return lines;
}

const _stdFnNames = <String>[
  'print', 'to_string', 'add', 'subtract', 'multiply', 'divide', 'modulo',
  'negate', 'less_than', 'greater_than', 'lte', 'gte', 'equals', 'not_equals',
  'and', 'or', 'not', 'if', 'for', 'for_in', 'while', 'assign', 'index',
  // collections
  'list_create', 'list_add', 'list_foreach', 'list_length',
  'map_create', 'map_from_entries', 'map_keys', 'map_get',
  // type ops
  'is', 'is_not',
];

Program buildProgram({required List<Map<String, dynamic>> functions}) {
  final stdModule = {
    'name': 'std',
    'typeDefs': [
      {
        'name': 'PrintInput',
        'descriptor': {
          'name': 'PrintInput',
          'field': [
            {
              'name': 'message',
              'number': 1,
              'label': 'LABEL_OPTIONAL',
              'type': 'TYPE_STRING',
            },
          ],
        },
      },
    ],
    'functions': [
      for (final n in _stdFnNames) {'name': n, 'isBase': true},
    ],
  };
  final mainModule = {'name': 'main', 'functions': functions};
  final programJson = {
    'name': 'test',
    'version': '1.0.0',
    'modules': [stdModule, _natModule(), mainModule],
    'entryModule': 'main',
    'entryFunction': 'main',
  };
  return Program()..mergeFromProto3Json(programJson);
}

Map<String, dynamic> literal(Object? value) {
  if (value == null) return {'literal': {}};
  if (value is int) {
    return {
      'literal': {'intValue': '$value'},
    };
  }
  if (value is String) {
    return {
      'literal': {'stringValue': value},
    };
  }
  if (value is bool) {
    return {
      'literal': {'boolValue': value},
    };
  }
  throw ArgumentError('Unsupported literal type: ${value.runtimeType}');
}

Map<String, dynamic> call(
  String function, {
  String module = '',
  Map<String, dynamic>? input,
}) {
  final c = <String, dynamic>{'function': function};
  if (module.isNotEmpty) c['module'] = module;
  if (input != null) c['input'] = input;
  return {'call': c};
}

Map<String, dynamic> stdCall(String function, Map<String, dynamic> input) =>
    call(function, module: 'std', input: input);

/// Bare (module-empty) call — routes through _resolveAndCallFunction to the
/// eager base dispatch instead of _evalCall's lazy std switch.
Map<String, dynamic> bareCall(String function, Map<String, dynamic> input) =>
    call(function, input: input);

Map<String, dynamic> natCall(String function) => call(function, module: 'nat');

Map<String, dynamic> msg(
  List<Map<String, dynamic>> fields, {
  String typeName = '',
}) => {
  'messageCreation': {'typeName': typeName, 'fields': fields},
};

Map<String, dynamic> field(String name, Map<String, dynamic> value) => {
  'name': name,
  'value': value,
};

Map<String, dynamic> listLit(List<Map<String, dynamic>> elements) => {
  'literal': {
    'listValue': {'elements': elements},
  },
};

Map<String, dynamic> lambdaExpr(
  Map<String, dynamic> body, {
  String inputType = 'dynamic',
}) => {
  'lambda': {'name': '', 'inputType': inputType, 'body': body},
};

Map<String, dynamic> fieldAcc(Map<String, dynamic> object, String name) => {
  'fieldAccess': {'object': object, 'field': name},
};

Map<String, dynamic> printExpr(Map<String, dynamic> value) =>
    stdCall('print', msg([field('message', value)], typeName: 'PrintInput'));

Map<String, dynamic> printToString(Map<String, dynamic> expr) =>
    printExpr(stdCall('to_string', msg([field('value', expr)])));

Map<String, dynamic> stmt(Map<String, dynamic> expr) => {'expression': expr};

Map<String, dynamic> mainFn(List<Map<String, dynamic>> statements) => {
  'name': 'main',
  'body': {
    'block': {'statements': statements},
  },
};

/// Run a single expression, printing its stringified value; return that line.
Future<String> evalToString(Map<String, dynamic> expr) async {
  final program = buildProgram(
    functions: [
      mainFn([stmt(printToString(expr))]),
    ],
  );
  final lines = await runAndCapture(program);
  return lines.single;
}

void main() {
  group('list_foreach — non-collection `list` value', () {
    test(
      'a bare int `list` is neither List/Map/BallMap/Set: no-op, no crash',
      () async {
        // Exercises the `else if (collection is Set)` CONDITION in
        // list_foreach evaluating false for a genuinely non-collection value
        // (the arm's BODY stays unreachable/ignored per #261 — any real Set
        // is already absorbed by the `listVal != null` branch above it).
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                bareCall(
                  'list_foreach',
                  msg([
                    field('list', literal(5)),
                    field(
                      'function',
                      lambdaExpr(printExpr(literal('unreached'))),
                    ),
                  ]),
                ),
              ),
              stmt(printExpr(literal('done'))),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['done']);
      },
    );
  });

  group('map_from_entries — non-map element', () {
    test('a bare int list element is skipped without crashing', () async {
      // Exercises the `else if (e is Map)` CONDITION evaluating false for a
      // genuinely non-Map entry (the body stays #261-ignored: any real Map is
      // already absorbed by `_stdAsMap` above it).
      final result = await evalToString(
        bareCall(
          'map_keys',
          msg([
            field(
              'map',
              bareCall(
                'map_from_entries',
                msg([
                  field(
                    'list',
                    listLit([
                      literal(5),
                      msg([
                        field('key', literal('a')),
                        field('value', literal(1)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      );
      expect(result, '[a]');
    });
  });

  group('is / type_check — Null type arm', () {
    test('`null is Null` is true', () async {
      expect(
        await evalToString(
          bareCall(
            'is',
            msg([
              field('value', literal(null)),
              field('type', literal('Null')),
            ]),
          ),
        ),
        'true',
      );
    });

    test('`5 is Null` is false', () async {
      expect(
        await evalToString(
          bareCall(
            'is',
            msg([field('value', literal(5)), field('type', literal('Null'))]),
          ),
        ),
        'false',
      );
    });
  });

  group('fieldAccess on a BallInt wrapper (custom-module-injected)', () {
    test('.isNegative', () async {
      expect(
        await evalToString(fieldAcc(natCall('bint'), 'isNegative')),
        'true',
      );
    });

    test('.sign', () async {
      expect(await evalToString(fieldAcc(natCall('bint'), 'sign')), '-1');
    });

    test('.abs', () async {
      expect(await evalToString(fieldAcc(natCall('bint'), 'abs')), '5');
    });
  });
}
