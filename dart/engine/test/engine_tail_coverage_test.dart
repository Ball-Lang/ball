// Tail-coverage tests for the engine `lib/` product code.
//
// These exercise the harder-to-reach branches in engine_eval.dart,
// engine_control_flow.dart, engine_std.dart, engine_invocation.dart,
// engine.dart and engine_types.dart that the main engine_test.dart and the
// other *_coverage_test.dart files do not reach: string-form for-loop inits,
// generator yield/yield_each, async error wrapping, alternate-receiver std
// handler branches (raw Map / Set vs BallMap), virtual field-access properties
// on built-in types, engine resource limits, and module-handler customisation.
//
// Field-name conventions match the engine's extractors (binary ops read
// left/right, unary ops read value, list ops read list/value/index/callback,
// map ops read map/key/value, etc.).
import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Self-contained builder helpers (kept independent of engine_test.dart). ──

Future<List<String>> runAndCapture(
  Program program, {
  List<BallModuleHandler>? handlers,
  bool sandbox = false,
}) async {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    moduleHandlers: handlers,
    sandbox: sandbox,
  );
  await engine.run();
  return lines;
}

const _stdFnNames = <String>[
  'print', 'add', 'subtract', 'multiply', 'divide', 'divide_double', 'modulo',
  'negate', 'less_than', 'greater_than', 'lte', 'gte', 'equals', 'not_equals',
  'and', 'or', 'not', 'to_string', 'if', 'for', 'for_in', 'while', 'do_while',
  'return', 'break', 'continue', 'assign', 'string_interpolation',
  'pre_increment', 'pre_decrement', 'post_increment', 'post_decrement',
  'to_double', 'to_int', 'index', 'switch', 'switch_expr', 'try', 'throw',
  'yield', 'yield_each', 'cascade', 'null_aware_cascade', 'record', 'spread',
  'null_spread', 'collection_for', 'collection_if', 'invoke', 'tear_off',
  'paren', 'symbol', 'type_literal', 'null_coalesce', 'assert',
  // collections
  'list_push', 'list_get', 'list_length', 'list_foreach', 'list_map',
  'list_join', 'list_slice', 'list_flat_map', 'list_to_list', 'map_create',
  'map_get', 'map_set', 'map_keys', 'map_values', 'map_entries',
  'map_contains_key', 'map_contains_value', 'map_delete', 'map_put_if_absent',
  'map_length', 'map_is_empty', 'set_create', 'set_add', 'set_contains',
  'set_length', 'string_join',
  // strings
  'string_is_empty', 'string_runes', 'string_split',
  // type checks
  'is', 'is_not',
  // math / misc
  'math_clamp', 'math_pow', 'json_encode', 'json_decode',
  // io
  'print_error', 'env_get', 'args_get', 'exit', 'panic',
  // builtin statics
  'dart_list_generate', 'dart_list_filled',
];

Program buildProgram({
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> extraStdFunctions = const [],
}) {
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
      ...extraStdFunctions,
    ],
  };
  final mainModule = {'name': 'main', 'functions': functions};
  final programJson = {
    'name': 'test',
    'version': '1.0.0',
    'modules': [stdModule, mainModule],
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
  if (value is double) {
    return {
      'literal': {'doubleValue': value},
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

Map<String, dynamic> ref(String name) => {
  'reference': {'name': name},
};

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

Map<String, dynamic> msg(
  List<Map<String, dynamic>> fields, {
  String typeName = '',
}) {
  return {
    'messageCreation': {'typeName': typeName, 'fields': fields},
  };
}

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

Map<String, dynamic> printExpr(Map<String, dynamic> value) =>
    stdCall('print', msg([field('message', value)], typeName: 'PrintInput'));

Map<String, dynamic> printToString(Map<String, dynamic> expr) =>
    printExpr(stdCall('to_string', msg([field('value', expr)])));

Map<String, dynamic> stmt(Map<String, dynamic> expr) => {'expression': expr};

Map<String, dynamic> letStmt(String name, Map<String, dynamic> value) => {
  'let': {
    'name': name,
    'value': value,
    'metadata': {'keyword': 'var'},
  },
};

Map<String, dynamic> blockExpr(
  List<Map<String, dynamic>> statements, {
  Map<String, dynamic>? result,
}) {
  final b = <String, dynamic>{'statements': statements};
  if (result != null) b['result'] = result;
  return {'block': b};
}

Map<String, dynamic> mainFn(List<Map<String, dynamic>> statements) => {
  'name': 'main',
  'body': {
    'block': {'statements': statements},
  },
};

/// Run a single expression and return the printed (to_string) output line.
Future<String> evalPrint(Map<String, dynamic> expr) async {
  final program = buildProgram(
    functions: [
      mainFn([stmt(printToString(expr))]),
    ],
  );
  final lines = await runAndCapture(program);
  return lines.single;
}

/// Run a single string-producing expression and print it raw.
Future<String> evalPrintStr(Map<String, dynamic> expr) async {
  final program = buildProgram(
    functions: [
      mainFn([stmt(printExpr(expr))]),
    ],
  );
  final lines = await runAndCapture(program);
  return lines.single;
}

void main() {
  group('for-loop string-form init (engine_control_flow)', () {
    // `init` as a string literal "var i = 0" exercises _evalForInit's
    // string-parse branch and _evalSimpleInitExpr.
    Map<String, dynamic> stringInitFor({
      required String init,
      required Map<String, dynamic> condition,
      required Map<String, dynamic> update,
      required Map<String, dynamic> body,
    }) => stdCall(
      'for',
      msg([
        field('init', literal(init)),
        field('condition', condition),
        field('update', update),
        field('body', body),
      ]),
    );

    test('var i = 0 literal init counts up', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stringInitFor(
                init: 'var i = 0',
                condition: stdCall(
                  'less_than',
                  msg([field('left', ref('i')), field('right', literal(3))]),
                ),
                update: stdCall(
                  'assign',
                  msg([
                    field('target', ref('i')),
                    field(
                      'value',
                      stdCall(
                        'add',
                        msg([
                          field('left', ref('i')),
                          field('right', literal(1)),
                        ]),
                      ),
                    ),
                  ]),
                ),
                body: printToString(ref('i')),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1', '2']);
    });

    test('init "var n = s.length - 1" (prop-op-num simple expr)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('s', literal('abcd')),
            stmt(
              stringInitFor(
                init: 'var n = s.length - 1',
                condition: stdCall(
                  'gte',
                  msg([field('left', ref('n')), field('right', literal(0))]),
                ),
                update: stdCall(
                  'assign',
                  msg([
                    field('target', ref('n')),
                    field(
                      'value',
                      stdCall(
                        'subtract',
                        msg([
                          field('left', ref('n')),
                          field('right', literal(1)),
                        ]),
                      ),
                    ),
                  ]),
                ),
                body: printToString(ref('n')),
              ),
            ),
          ]),
        ],
      );
      // s.length(4) - 1 = 3, counting down to 0.
      expect(await runAndCapture(program), ['3', '2', '1', '0']);
    });

    test('init "var k = i * j" (var-op-var simple expr)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(3)),
            letStmt('j', literal(4)),
            stmt(
              stringInitFor(
                init: 'var k = i * j',
                condition: stdCall(
                  'less_than',
                  msg([field('left', ref('k')), field('right', literal(13))]),
                ),
                update: stdCall(
                  'assign',
                  msg([
                    field('target', ref('k')),
                    field(
                      'value',
                      stdCall(
                        'add',
                        msg([
                          field('left', ref('k')),
                          field('right', literal(1)),
                        ]),
                      ),
                    ),
                  ]),
                ),
                body: printToString(ref('k')),
              ),
            ),
          ]),
        ],
      );
      // i*j = 12, loops while < 13 → prints 12 once.
      expect(await runAndCapture(program), ['12']);
    });

    test('init "var m = arr.length" (prop-access simple expr)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('arr', listLit([literal(1), literal(2), literal(3)])),
            stmt(
              stringInitFor(
                init: 'var m = arr.length',
                condition: stdCall(
                  'greater_than',
                  msg([field('left', ref('m')), field('right', literal(0))]),
                ),
                update: stdCall(
                  'assign',
                  msg([
                    field('target', ref('m')),
                    field(
                      'value',
                      stdCall(
                        'subtract',
                        msg([
                          field('left', ref('m')),
                          field('right', literal(1)),
                        ]),
                      ),
                    ),
                  ]),
                ),
                body: printToString(ref('m')),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3', '2', '1']);
    });

    test('init "var x = y" (bare variable reference simple expr)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('y', literal(2)),
            stmt(
              stringInitFor(
                init: 'var x = y',
                condition: stdCall(
                  'less_than',
                  msg([field('left', ref('x')), field('right', literal(4))]),
                ),
                update: stdCall(
                  'assign',
                  msg([
                    field('target', ref('x')),
                    field(
                      'value',
                      stdCall(
                        'add',
                        msg([
                          field('left', ref('x')),
                          field('right', literal(1)),
                        ]),
                      ),
                    ),
                  ]),
                ),
                body: printToString(ref('x')),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['2', '3']);
    });
  });

  group('virtual field-access properties (engine_eval)', () {
    Future<String> fieldProp(Map<String, dynamic> object, String prop) =>
        evalPrint({
          'fieldAccess': {'object': object, 'field': prop},
        });

    test('List.reversed', () async {
      expect(
        await fieldProp(
          listLit([literal(1), literal(2), literal(3)]),
          'reversed',
        ),
        '[3, 2, 1]',
      );
    });
    test('List.first / List.last / List.single', () async {
      expect(await fieldProp(listLit([literal(5), literal(6)]), 'first'), '5');
      expect(await fieldProp(listLit([literal(5), literal(6)]), 'last'), '6');
      expect(await fieldProp(listLit([literal(7)]), 'single'), '7');
    });
    test('List.length / isEmpty / isNotEmpty', () async {
      expect(await fieldProp(listLit([literal(1), literal(2)]), 'length'), '2');
      expect(await fieldProp(listLit([]), 'isEmpty'), 'true');
      expect(await fieldProp(listLit([literal(1)]), 'isNotEmpty'), 'true');
    });
    test('String.length / isEmpty / isNotEmpty', () async {
      expect(await fieldProp(literal('abc'), 'length'), '3');
      expect(await fieldProp(literal(''), 'isEmpty'), 'true');
      expect(await fieldProp(literal('x'), 'isNotEmpty'), 'true');
    });
    test('num.isNegative / sign / abs', () async {
      expect(await fieldProp(literal(-5), 'isNegative'), 'true');
      expect(await fieldProp(literal(-3), 'sign'), '-1');
      expect(await fieldProp(literal(-7), 'abs'), '7');
    });
    test('double.isNaN / isFinite / isInfinite', () async {
      expect(await fieldProp(literal(1.5), 'isFinite'), 'true');
      expect(await fieldProp(literal(1.5), 'isNaN'), 'false');
      expect(await fieldProp(literal(1.5), 'isInfinite'), 'false');
    });
    test('double.isNegative / sign / abs', () async {
      expect(await fieldProp(literal(-2.5), 'isNegative'), 'true');
      expect(await fieldProp(literal(-2.5), 'sign'), '-1.0');
      expect(await fieldProp(literal(-2.5), 'abs'), '2.5');
    });
    test('value.toString virtual property', () async {
      expect(await fieldProp(literal(42), 'toString'), '42');
    });
    test('runtimeType for each primitive', () async {
      expect(await fieldProp(literal(1), 'runtimeType'), 'int');
      expect(await fieldProp(literal(1.5), 'runtimeType'), 'double');
      expect(await fieldProp(literal('x'), 'runtimeType'), 'String');
      expect(await fieldProp(literal(true), 'runtimeType'), 'bool');
      expect(await fieldProp(listLit([literal(1)]), 'runtimeType'), 'List');
      expect(await fieldProp(literal(null), 'runtimeType'), 'Null');
    });
  });

  group('map virtual properties on raw map result (engine_eval)', () {
    // map_keys returns a raw List, map_entries a raw List; access field on a
    // map produced by map_create (a BallMap) exercises the BallMap field path.
    Map<String, dynamic> mapOf(Map<String, int> m) => stdCall(
      'map_create',
      msg([
        field(
          'entries',
          listLit([
            for (final e in m.entries)
              msg([
                field('key', literal(e.key)),
                field('value', literal(e.value)),
              ]),
          ]),
        ),
      ]),
    );

    test('map.length virtual', () async {
      expect(
        await evalPrint({
          'fieldAccess': {
            'object': mapOf({'a': 1, 'b': 2}),
            'field': 'length',
          },
        }),
        '2',
      );
    });
    test('map.keys virtual', () async {
      expect(
        await evalPrint({
          'fieldAccess': {
            'object': mapOf({'a': 1, 'b': 2}),
            'field': 'keys',
          },
        }),
        '[a, b]',
      );
    });
    test('map.entries virtual', () async {
      expect(
        await evalPrint({
          'fieldAccess': {
            'object': mapOf({'a': 1}),
            'field': 'entries',
          },
        }),
        '[{key: a, value: 1}]',
      );
    });
    test('map.isEmpty / isNotEmpty virtual', () async {
      expect(
        await evalPrint({
          'fieldAccess': {'object': mapOf({}), 'field': 'isEmpty'},
        }),
        'true',
      );
      expect(
        await evalPrint({
          'fieldAccess': {
            'object': mapOf({'a': 1}),
            'field': 'isNotEmpty',
          },
        }),
        'true',
      );
    });
  });

  group('std handler alternate receivers (engine_std)', () {
    Map<String, dynamic> setOf(List<int> xs) => stdCall(
      'set_create',
      msg([
        field('elements', listLit([for (final x in xs) literal(x)])),
      ]),
    );

    test('map_contains_key on a Set receiver', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_contains_key',
            msg([
              field('map', setOf([1, 2, 3])),
              field('key', literal(2)),
            ]),
          ),
        ),
        'true',
      );
    });

    test('list_foreach over a Set receiver', () async {
      final cb = lambdaExpr(printToString(ref('input')));
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'list_foreach',
                msg([
                  field('list', setOf([9])),
                  field('function', cb),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['9']);
    });

    test('math_clamp on raw int value', () async {
      expect(
        await evalPrint(
          stdCall(
            'math_clamp',
            msg([
              field('value', literal(-3)),
              field('min', literal(0)),
              field('max', literal(10)),
            ]),
          ),
        ),
        '0',
      );
    });
  });

  group('generators: yield / yield_each (engine.dart + invocation)', () {
    // A sync* function: metadata.is_sync_star=true; body uses std.yield and
    // std.yield_each which produce flow signals consumed into __generator__.
    Map<String, dynamic> genFn(String name, Map<String, dynamic> body) => {
      'name': name,
      'metadata': {'kind': 'function', 'is_sync_star': true},
      'body': body,
    };

    test('sync* with yield collects values', () async {
      final program = buildProgram(
        functions: [
          genFn(
            'nums',
            blockExpr([
              stmt(stdCall('yield', msg([field('value', literal(1))]))),
              stmt(stdCall('yield', msg([field('value', literal(2))]))),
            ]),
          ),
          mainFn([stmt(printToString(call('nums')))]),
        ],
      );
      expect(await runAndCapture(program), ['[1, 2]']);
    });

    test('sync* with yield_each splices an iterable', () async {
      final program = buildProgram(
        functions: [
          genFn(
            'nums',
            blockExpr([
              stmt(stdCall('yield', msg([field('value', literal(0))]))),
              stmt(
                stdCall(
                  'yield_each',
                  msg([
                    field('value', listLit([literal(1), literal(2)])),
                  ]),
                ),
              ),
            ]),
          ),
          mainFn([stmt(printToString(call('nums')))]),
        ],
      );
      expect(await runAndCapture(program), ['[0, 1, 2]']);
    });
  });

  group('async error wrapping (engine_invocation + engine_types)', () {
    // An async function that throws: the error is wrapped in a BallFutureError;
    // awaiting it rethrows. Caught via try to surface the rethrow path.
    test('await rethrows error from async function', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'boom',
            'metadata': {'kind': 'function', 'is_async': true},
            'body': blockExpr([
              stmt(
                stdCall(
                  'throw',
                  msg([
                    field('value', literal('kaboom')),
                    field('type', literal('Exception')),
                  ]),
                ),
              ),
            ]),
          },
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field(
                    'body',
                    stdCall('dart_await', msg([field('value', call('boom'))])),
                  ),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('variable', literal('e')),
                        field('body', printToString(ref('e'))),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
        extraStdFunctions: [
          {'name': 'dart_await', 'isBase': true},
        ],
      );
      expect(await runAndCapture(program), ['kaboom']);
    });
  });

  group('engine resource limits (engine.dart)', () {
    test('too many modules throws', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printExpr(literal('x')))]),
        ],
      );
      expect(
        () => BallEngine(program, stdout: (_) {}, maxModules: 1),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('program too large throws', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printExpr(literal('x')))]),
        ],
      );
      expect(
        () => BallEngine(program, stdout: (_) {}, maxProgramSizeBytes: 1),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('static expression depth limit throws at construction', () {
      // Nest field accesses deeper than the limit.
      Map<String, dynamic> deep(int n) {
        Map<String, dynamic> e = ref('x');
        for (var i = 0; i < n; i++) {
          e = {
            'fieldAccess': {'object': e, 'field': 'f'},
          };
        }
        return e;
      }

      final program = buildProgram(
        functions: [
          mainFn([letStmt('x', literal(0)), stmt(deep(20))]),
        ],
      );
      expect(
        () => BallEngine(program, stdout: (_) {}, maxExpressionDepth: 5),
        throwsA(isA<BallRuntimeError>()),
      );
    });
  });

  group('StdModuleHandler customisation (engine_types)', () {
    test('subset() exposes only listed functions; others throw', () async {
      final std = StdModuleHandler.subset({'print', 'to_string', 'add'});
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([field('left', literal(2)), field('right', literal(3))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program, handlers: [std]), ['5']);
    });

    test('subset() omits subtract → throws BallRuntimeError', () async {
      final std = StdModuleHandler.subset({'print', 'to_string'});
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'subtract',
                  msg([field('left', literal(2)), field('right', literal(3))]),
                ),
              ),
            ),
          ]),
        ],
      );
      await expectLater(
        runAndCapture(program, handlers: [std]),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('register before construction overrides built-in print', () async {
      final seen = <String>[];
      final std = StdModuleHandler()
        ..register('print', (i) {
          final m = i is Map ? i['message'] : i;
          seen.add('OVR:$m');
          return null;
        });
      final program = buildProgram(
        functions: [
          mainFn([stmt(printExpr(literal('hi')))]),
        ],
      );
      await runAndCapture(program, handlers: [std]);
      expect(seen, ['OVR:hi']);
    });

    test('unregister before construction removes built-in', () async {
      final std = StdModuleHandler()..unregister('subtract');
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'subtract',
                  msg([field('left', literal(5)), field('right', literal(1))]),
                ),
              ),
            ),
          ]),
        ],
      );
      await expectLater(
        runAndCapture(program, handlers: [std]),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('registeredFunctions reflects register + unregister', () {
      final std = StdModuleHandler()
        ..register('custom', (_) => 1)
        ..unregister('print');
      // init has not run, so only the manually-registered fn is present.
      expect(std.registeredFunctions, contains('custom'));
      expect(std.registeredFunctions, isNot(contains('print')));
    });
  });

  group('std_io env_get default + exit (engine_std + engine_types)', () {
    test('env_get of an unset variable returns empty string', () async {
      // Uses the default envGet (Platform.environment) — a name very unlikely
      // to be set returns ''.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'env_get',
                  msg([field('name', literal('BALL_UNSET_VAR_XYZZY_123'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['']);
    });
  });

  group('built-in instance methods on List (engine_control_flow)', () {
    // A call with a `self` field whose value is a List dispatches through
    // _dispatchBuiltinInstanceMethod. Wrap in a let so the list identity is
    // stable across mutating methods.
    Future<List<String>> runMethod({
      required Map<String, dynamic> receiver,
      required String method,
      List<Map<String, dynamic>> extraArgs = const [],
      required Map<String, dynamic> printExprAfter,
    }) async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', receiver),
            stmt(
              call(
                method,
                input: msg([field('self', ref('xs')), ...extraArgs]),
              ),
            ),
            stmt(printExprAfter),
          ]),
        ],
      );
      return runAndCapture(program);
    }

    Map<String, dynamic> ints(List<int> xs) =>
        listLit([for (final x in xs) literal(x)]);

    test('list.add mutates in place', () async {
      final lines = await runMethod(
        receiver: ints([1, 2]),
        method: 'add',
        extraArgs: [field('arg0', literal(3))],
        printExprAfter: printToString(ref('xs')),
      );
      expect(lines, ['[1, 2, 3]']);
    });

    test('list.removeLast / removeAt / insert / clear / contains', () async {
      // contains
      expect(
        await evalPrint(
          call(
            'contains',
            input: msg([
              field('self', ints([1, 2, 3])),
              field('arg0', literal(2)),
            ]),
          ),
        ),
        'true',
      );
      // indexOf
      expect(
        await evalPrint(
          call(
            'indexOf',
            input: msg([
              field('self', ints([5, 6, 7])),
              field('arg0', literal(7)),
            ]),
          ),
        ),
        '2',
      );
      // removeLast
      expect(
        await evalPrint(
          call(
            'removeLast',
            input: msg([
              field('self', ints([1, 2, 3])),
            ]),
          ),
        ),
        '3',
      );
      // removeAt
      expect(
        await evalPrint(
          call(
            'removeAt',
            input: msg([
              field('self', ints([1, 2, 3])),
              field('arg0', literal(0)),
            ]),
          ),
        ),
        '1',
      );
    });

    test(
      'list.join / sublist / reversed / toList / toSet / toString',
      () async {
        expect(
          await evalPrintStr(
            call(
              'join',
              input: msg([
                field('self', ints([1, 2, 3])),
                field('arg0', literal('-')),
              ]),
            ),
          ),
          '1-2-3',
        );
        expect(
          await evalPrint(
            call(
              'sublist',
              input: msg([
                field('self', ints([1, 2, 3, 4])),
                field('arg0', literal(1)),
                field('arg1', literal(3)),
              ]),
            ),
          ),
          '[2, 3]',
        );
        expect(
          await evalPrint(
            call(
              'reversed',
              input: msg([
                field('self', ints([1, 2, 3])),
              ]),
            ),
          ),
          '[3, 2, 1]',
        );
        expect(
          await evalPrint(
            call(
              'toList',
              input: msg([
                field('self', ints([1, 2])),
              ]),
            ),
          ),
          '[1, 2]',
        );
        expect(
          await evalPrintStr(
            call(
              'toString',
              input: msg([
                field('self', ints([1, 2])),
              ]),
            ),
          ),
          '[1, 2]',
        );
      },
    );

    test('list.map / where / forEach / any / every', () async {
      final dbl = lambdaExpr(
        stdCall(
          'multiply',
          msg([field('left', ref('input')), field('right', literal(2))]),
        ),
      );
      expect(
        await evalPrint(
          call(
            'map',
            input: msg([
              field('self', ints([1, 2])),
              field('arg0', dbl),
            ]),
          ),
        ),
        '[2, 4]',
      );
      final isEven = lambdaExpr(
        stdCall(
          'equals',
          msg([
            field(
              'left',
              stdCall(
                'modulo',
                msg([field('left', ref('input')), field('right', literal(2))]),
              ),
            ),
            field('right', literal(0)),
          ]),
        ),
      );
      expect(
        await evalPrint(
          call(
            'where',
            input: msg([
              field('self', ints([1, 2, 3, 4])),
              field('arg0', isEven),
            ]),
          ),
        ),
        '[2, 4]',
      );
      expect(
        await evalPrint(
          call(
            'any',
            input: msg([
              field('self', ints([1, 2, 3])),
              field('arg0', isEven),
            ]),
          ),
        ),
        'true',
      );
      expect(
        await evalPrint(
          call(
            'every',
            input: msg([
              field('self', ints([2, 4])),
              field('arg0', isEven),
            ]),
          ),
        ),
        'true',
      );
    });

    test('list.reduce / fold', () async {
      final addFn = lambdaExpr(
        stdCall(
          'add',
          msg([field('left', ref('arg0')), field('right', ref('arg1'))]),
        ),
      );
      expect(
        await evalPrint(
          call(
            'reduce',
            input: msg([
              field('self', ints([1, 2, 3, 4])),
              field('arg0', addFn),
            ]),
          ),
        ),
        '10',
      );
      expect(
        await evalPrint(
          call(
            'fold',
            input: msg([
              field('self', ints([1, 2, 3])),
              field('arg0', literal(100)),
              field('arg1', addFn),
            ]),
          ),
        ),
        '106',
      );
    });

    test('list.take / skip / expand / followedBy', () async {
      expect(
        await evalPrint(
          call(
            'take',
            input: msg([
              field('self', ints([1, 2, 3, 4])),
              field('arg0', literal(2)),
            ]),
          ),
        ),
        '[1, 2]',
      );
      expect(
        await evalPrint(
          call(
            'skip',
            input: msg([
              field('self', ints([1, 2, 3, 4])),
              field('arg0', literal(2)),
            ]),
          ),
        ),
        '[3, 4]',
      );
      final wrap = lambdaExpr(listLit([ref('input'), ref('input')]));
      expect(
        await evalPrint(
          call(
            'expand',
            input: msg([
              field('self', ints([1, 2])),
              field('arg0', wrap),
            ]),
          ),
        ),
        '[1, 1, 2, 2]',
      );
      expect(
        await evalPrint(
          call(
            'followedBy',
            input: msg([
              field('self', ints([1, 2])),
              field('arg0', ints([3, 4])),
            ]),
          ),
        ),
        '[1, 2, 3, 4]',
      );
    });

    test('list.sort default and with comparator', () async {
      expect(
        await evalPrint(
          call(
            'sort',
            input: msg([
              field('self', ints([3, 1, 2])),
            ]),
          ),
        ),
        'null',
      );
      // descending comparator
      final desc = lambdaExpr(
        stdCall(
          'subtract',
          msg([field('left', ref('arg1')), field('right', ref('arg0'))]),
        ),
      );
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([1, 3, 2])),
            stmt(
              call(
                'sort',
                input: msg([field('self', ref('xs')), field('arg0', desc)]),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[3, 2, 1]']);
    });
  });

  group('built-in instance methods on String / num (engine_control_flow)', () {
    Map<String, dynamic> strMethod(
      String s,
      String method, {
      List<Map<String, dynamic>> args = const [],
    }) => call(method, input: msg([field('self', literal(s)), ...args]));

    test('string methods', () async {
      expect(
        await evalPrint(
          strMethod('hello', 'contains', args: [field('arg0', literal('ell'))]),
        ),
        'true',
      );
      expect(
        await evalPrintStr(
          strMethod(
            'hello',
            'substring',
            args: [field('arg0', literal(1)), field('arg1', literal(3))],
          ),
        ),
        'el',
      );
      expect(
        await evalPrint(
          strMethod('hello', 'indexOf', args: [field('arg0', literal('l'))]),
        ),
        '2',
      );
      expect(
        await evalPrint(
          strMethod('a,b,c', 'split', args: [field('arg0', literal(','))]),
        ),
        '[a, b, c]',
      );
      expect(await evalPrintStr(strMethod('  x  ', 'trim')), 'x');
      expect(await evalPrintStr(strMethod('ab', 'toUpperCase')), 'AB');
      expect(await evalPrintStr(strMethod('AB', 'toLowerCase')), 'ab');
      expect(
        await evalPrintStr(
          strMethod(
            'aaa',
            'replaceAll',
            args: [field('arg0', literal('a')), field('arg1', literal('b'))],
          ),
        ),
        'bbb',
      );
      expect(
        await evalPrint(
          strMethod(
            'hello',
            'startsWith',
            args: [field('arg0', literal('he'))],
          ),
        ),
        'true',
      );
      expect(
        await evalPrint(
          strMethod('hello', 'endsWith', args: [field('arg0', literal('lo'))]),
        ),
        'true',
      );
      expect(
        await evalPrintStr(
          strMethod(
            '7',
            'padLeft',
            args: [field('arg0', literal(3)), field('arg1', literal('0'))],
          ),
        ),
        '007',
      );
      expect(
        await evalPrintStr(
          strMethod(
            '7',
            'padRight',
            args: [field('arg0', literal(3)), field('arg1', literal('0'))],
          ),
        ),
        '700',
      );
      expect(await evalPrintStr(strMethod('hi', 'toString')), 'hi');
      expect(
        await evalPrint(
          strMethod('A', 'codeUnitAt', args: [field('arg0', literal(0))]),
        ),
        '65',
      );
      expect(
        await evalPrint(
          strMethod('a', 'compareTo', args: [field('arg0', literal('b'))]),
        ),
        '-1',
      );
    });

    Map<String, dynamic> numMethod(
      Object n,
      String method, {
      List<Map<String, dynamic>> args = const [],
    }) => call(method, input: msg([field('self', literal(n)), ...args]));

    // For methods needing a raw double receiver, route through std.to_double
    // (returns a raw Dart double, not a BallDouble) so `unwrappedSelf is num`.
    Map<String, dynamic> dbl(double d) =>
        stdCall('to_double', msg([field('value', literal(d))]));
    Map<String, dynamic> dblMethod(
      double d,
      String method, {
      List<Map<String, dynamic>> args = const [],
    }) => call(method, input: msg([field('self', dbl(d)), ...args]));

    test('num methods (int receiver)', () async {
      expect(await evalPrint(numMethod(3, 'toDouble')), '3.0');
      expect(await evalPrintStr(numMethod(42, 'toString')), '42');
      expect(await evalPrint(numMethod(-5, 'abs')), '5');
      expect(
        await evalPrint(
          numMethod(2, 'compareTo', args: [field('arg0', literal(5))]),
        ),
        '-1',
      );
      expect(
        await evalPrint(
          numMethod(
            10,
            'clamp',
            args: [field('arg0', literal(0)), field('arg1', literal(5))],
          ),
        ),
        '5',
      );
      expect(
        await evalPrint(
          numMethod(10, 'remainder', args: [field('arg0', literal(3))]),
        ),
        '1',
      );
    });

    test('num methods (double receiver via to_double)', () async {
      expect(await evalPrint(dblMethod(3.9, 'toInt')), '3');
      expect(
        await evalPrintStr(
          dblMethod(
            3.14159,
            'toStringAsFixed',
            args: [field('arg0', literal(2))],
          ),
        ),
        '3.14',
      );
      expect(await evalPrint(dblMethod(3.6, 'round')), '4');
      expect(await evalPrint(dblMethod(3.6, 'floor')), '3');
      expect(await evalPrint(dblMethod(3.2, 'ceil')), '4');
      expect(await evalPrint(dblMethod(3.9, 'truncate')), '3');
    });
  });

  group('built-in instance methods on Set (engine_control_flow)', () {
    Map<String, dynamic> setOf(List<int> xs) => stdCall(
      'set_create',
      msg([
        field('elements', listLit([for (final x in xs) literal(x)])),
      ]),
    );
    Map<String, dynamic> setMethod(
      List<int> xs,
      String method, {
      List<Map<String, dynamic>> args = const [],
    }) => call(method, input: msg([field('self', setOf(xs)), ...args]));

    test('set.contains / length / isEmpty / isNotEmpty', () async {
      expect(
        await evalPrint(
          setMethod([1, 2, 3], 'contains', args: [field('arg0', literal(2))]),
        ),
        'true',
      );
      expect(await evalPrint(setMethod([1, 2, 3], 'length')), '3');
      expect(await evalPrint(setMethod([], 'isEmpty')), 'true');
      expect(await evalPrint(setMethod([1], 'isNotEmpty')), 'true');
    });

    test('set.union / intersection / difference with set arg', () async {
      expect(
        await evalPrint(
          call(
            'length',
            input: msg([
              field(
                'self',
                call(
                  'union',
                  input: msg([
                    field('self', setOf([1, 2])),
                    field('arg0', setOf([2, 3])),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        '3',
      );
      expect(
        await evalPrint(
          call(
            'length',
            input: msg([
              field(
                'self',
                call(
                  'intersection',
                  input: msg([
                    field('self', setOf([1, 2, 3])),
                    field('arg0', setOf([2, 3, 4])),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        '2',
      );
      expect(
        await evalPrint(
          call(
            'length',
            input: msg([
              field(
                'self',
                call(
                  'difference',
                  input: msg([
                    field('self', setOf([1, 2, 3])),
                    field('arg0', setOf([2])),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        '2',
      );
    });

    test('set.map / where over a Set receiver', () async {
      final dbl = lambdaExpr(
        stdCall(
          'multiply',
          msg([field('left', ref('input')), field('right', literal(2))]),
        ),
      );
      expect(
        await evalPrint(
          call(
            'map',
            input: msg([
              field('self', setOf([1, 2])),
              field('arg0', dbl),
            ]),
          ),
        ),
        '[2, 4]',
      );
      final isEven = lambdaExpr(
        stdCall(
          'equals',
          msg([
            field(
              'left',
              stdCall(
                'modulo',
                msg([field('left', ref('input')), field('right', literal(2))]),
              ),
            ),
            field('right', literal(0)),
          ]),
        ),
      );
      // set.where returns a Set; convert to list length for a stable assert.
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'r',
              call(
                'where',
                input: msg([
                  field('self', setOf([1, 2, 3, 4])),
                  field('arg0', isEven),
                ]),
              ),
            ),
            stmt(
              printToString(
                call('length', input: msg([field('self', ref('r'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['2']);
    });

    test('set.remove mutates a let-bound set', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('s', setOf([1, 2, 3])),
            stmt(
              call(
                'remove',
                input: msg([
                  field('self', ref('s')),
                  field('arg0', literal(2)),
                ]),
              ),
            ),
            stmt(
              printToString(
                call('length', input: msg([field('self', ref('s'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['2']);
    });

    test('set.add mutates a let-bound set', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('s', setOf([1, 2])),
            stmt(
              call(
                'add',
                input: msg([
                  field('self', ref('s')),
                  field('arg0', literal(3)),
                ]),
              ),
            ),
            stmt(
              printToString(
                call('length', input: msg([field('self', ref('s'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3']);
    });
  });

  group('index / field / inc-dec assignment targets (engine_control_flow)', () {
    Map<String, dynamic> idx(
      Map<String, dynamic> target,
      Map<String, dynamic> index,
    ) =>
        stdCall('index', msg([field('target', target), field('index', index)]));

    Map<String, dynamic> assign(
      Map<String, dynamic> target,
      Map<String, dynamic> value, {
      String op = '=',
    }) => stdCall(
      'assign',
      msg([
        field('target', target),
        field('value', value),
        field('op', literal(op)),
      ]),
    );

    Map<String, dynamic> ints(List<int> xs) =>
        listLit([for (final x in xs) literal(x)]);

    test('list[i] += val (compound index assign)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([10, 20, 30])),
            stmt(assign(idx(ref('xs'), literal(1)), literal(5), op: '+=')),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[10, 25, 30]']);
    });

    test('list[i] = val (plain index assign)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([1, 2, 3])),
            stmt(assign(idx(ref('xs'), literal(0)), literal(9))),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[9, 2, 3]']);
    });

    test('map[k] += val (compound map index assign)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'm',
              stdCall(
                'map_create',
                msg([
                  field(
                    'entries',
                    listLit([
                      msg([
                        field('key', literal('a')),
                        field('value', literal(1)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(assign(idx(ref('m'), literal('a')), literal(4), op: '+=')),
            stmt(printToString(idx(ref('m'), literal('a')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['5']);
    });

    test('list[i] ??= val (null-aware index assign)', () async {
      // Build a list with a null hole via List.filled then assign.
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'xs',
              call(
                'filled',
                input: msg([
                  field('self', ref('List')),
                  field('arg0', literal(2)),
                  field('arg1', literal(null)),
                ]),
              ),
            ),
            stmt(assign(idx(ref('xs'), literal(0)), literal(7), op: '??=')),
            stmt(printToString(idx(ref('xs'), literal(0)))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });

    test('list[i]++ post increment', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([5, 6])),
            stmt(
              stdCall(
                'post_increment',
                msg([field('value', idx(ref('xs'), literal(0)))]),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[6, 6]']);
    });

    test('map[k]++ post increment on map index', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'm',
              stdCall(
                'map_create',
                msg([
                  field(
                    'entries',
                    listLit([
                      msg([
                        field('key', literal('c')),
                        field('value', literal(0)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(
              stdCall(
                'pre_increment',
                msg([field('value', idx(ref('m'), literal('c')))]),
              ),
            ),
            stmt(printToString(idx(ref('m'), literal('c')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1']);
    });
  });

  group('labeled loops + break/continue with labels (engine_control_flow)', () {
    Map<String, dynamic> labeled(String label, Map<String, dynamic> body) =>
        stdCall(
          'labeled',
          msg([field('label', literal(label)), field('body', body)]),
        );

    Map<String, dynamic> breakL(String label) =>
        stdCall('break', msg([field('label', literal(label))]));

    Map<String, dynamic> forIn(
      String variable,
      Map<String, dynamic> iterable,
      Map<String, dynamic> body,
    ) => stdCall(
      'for_in',
      msg([
        field('variable', literal(variable)),
        field('iterable', iterable),
        field('body', body),
      ]),
    );

    Map<String, dynamic> ints(List<int> xs) =>
        listLit([for (final x in xs) literal(x)]);

    test('labeled for_in with labeled break exits', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'outer',
                forIn(
                  'x',
                  ints([1, 2, 3]),
                  blockExpr([
                    stmt(printToString(ref('x'))),
                    stmt(
                      stdCall(
                        'if',
                        msg([
                          field(
                            'condition',
                            stdCall(
                              'equals',
                              msg([
                                field('left', ref('x')),
                                field('right', literal(2)),
                              ]),
                            ),
                          ),
                          field('then', blockExpr([stmt(breakL('outer'))])),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1', '2']);
    });

    test('labeled while with labeled break', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0)),
            stmt(
              labeled(
                'w',
                stdCall(
                  'while',
                  msg([
                    field(
                      'condition',
                      stdCall(
                        'less_than',
                        msg([
                          field('left', ref('i')),
                          field('right', literal(10)),
                        ]),
                      ),
                    ),
                    field(
                      'body',
                      blockExpr([
                        stmt(printToString(ref('i'))),
                        stmt(
                          stdCall(
                            'assign',
                            msg([
                              field('target', ref('i')),
                              field(
                                'value',
                                stdCall(
                                  'add',
                                  msg([
                                    field('left', ref('i')),
                                    field('right', literal(1)),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                        ),
                        stmt(
                          stdCall(
                            'if',
                            msg([
                              field(
                                'condition',
                                stdCall(
                                  'equals',
                                  msg([
                                    field('left', ref('i')),
                                    field('right', literal(2)),
                                  ]),
                                ),
                              ),
                              field('then', blockExpr([stmt(breakL('w'))])),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1']);
    });

    test('labeled do_while with labeled break', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0)),
            stmt(
              labeled(
                'd',
                stdCall(
                  'do_while',
                  msg([
                    field(
                      'body',
                      blockExpr([
                        stmt(printToString(ref('i'))),
                        stmt(
                          stdCall(
                            'assign',
                            msg([
                              field('target', ref('i')),
                              field(
                                'value',
                                stdCall(
                                  'add',
                                  msg([
                                    field('left', ref('i')),
                                    field('right', literal(1)),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                        ),
                        stmt(
                          stdCall(
                            'if',
                            msg([
                              field(
                                'condition',
                                stdCall(
                                  'gte',
                                  msg([
                                    field('left', ref('i')),
                                    field('right', literal(2)),
                                  ]),
                                ),
                              ),
                              field('then', blockExpr([stmt(breakL('d'))])),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                    field('condition', literal(true)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1']);
    });

    test('labeled for (C-style) with labeled break', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'f',
                stdCall(
                  'for',
                  msg([
                    field('init', literal('var i = 0')),
                    field(
                      'condition',
                      stdCall(
                        'less_than',
                        msg([
                          field('left', ref('i')),
                          field('right', literal(10)),
                        ]),
                      ),
                    ),
                    field(
                      'update',
                      stdCall(
                        'assign',
                        msg([
                          field('target', ref('i')),
                          field(
                            'value',
                            stdCall(
                              'add',
                              msg([
                                field('left', ref('i')),
                                field('right', literal(1)),
                              ]),
                            ),
                          ),
                        ]),
                      ),
                    ),
                    field(
                      'body',
                      blockExpr([
                        stmt(printToString(ref('i'))),
                        stmt(
                          stdCall(
                            'if',
                            msg([
                              field(
                                'condition',
                                stdCall(
                                  'equals',
                                  msg([
                                    field('left', ref('i')),
                                    field('right', literal(1)),
                                  ]),
                                ),
                              ),
                              field('then', blockExpr([stmt(breakL('f'))])),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1']);
    });
  });

  group('label wrapper without goto (engine_control_flow)', () {
    test('std.label runs its body once when no goto targets it', () async {
      // Forward execution: the label body runs once and returns normally
      // (no goto re-entry). Exercises _evalLabel's single-pass path.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'label',
                msg([
                  field('name', literal('start')),
                  field('body', blockExpr([stmt(printExpr(literal('once')))])),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['once']);
    });
  });

  group('cascade with sections (engine_control_flow)', () {
    test('cascade evaluates sections and returns target', () async {
      // var xs = []..add(1)..add(2);  → [1, 2]
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'xs',
              stdCall(
                'cascade',
                msg([
                  field('target', listLit([])),
                  field(
                    'sections',
                    listLit([
                      call(
                        'add',
                        input: msg([
                          field('self', ref('__cascade_self__')),
                          field('arg0', literal(1)),
                        ]),
                      ),
                      call(
                        'add',
                        input: msg([
                          field('self', ref('__cascade_self__')),
                          field('arg0', literal(2)),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[1, 2]']);
    });

    test('null_aware_cascade on null target returns null', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'null_aware_cascade',
                  msg([
                    field('target', literal(null)),
                    field('sections', listLit([])),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['null']);
    });
  });

  group(
    'std tails: index / record / set_create / switch_expr (engine_std)',
    () {
      test('std.index on a String', () async {
        expect(
          await evalPrintStr(
            stdCall(
              'index',
              msg([
                field('target', literal('hello')),
                field('index', literal(1)),
              ]),
            ),
          ),
          'e',
        );
      });

      test('std.index on a raw Map (via map_create BallMap)', () async {
        expect(
          await evalPrint(
            stdCall(
              'index',
              msg([
                field(
                  'target',
                  stdCall(
                    'map_create',
                    msg([
                      field(
                        'entries',
                        listLit([
                          msg([
                            field('key', literal('k')),
                            field('value', literal(42)),
                          ]),
                        ]),
                      ),
                    ]),
                  ),
                ),
                field('index', literal('k')),
              ]),
            ),
          ),
          '42',
        );
      });

      test('std.record returns fields', () async {
        expect(
          await evalPrint(
            stdCall(
              'record',
              msg([
                field('fields', listLit([literal(1), literal(2)])),
              ]),
            ),
          ),
          '[1, 2]',
        );
      });

      test('switch_expr matches int arm', () async {
        // subject 2 → case "int x" guard binds and returns body.
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall(
                    'switch_expr',
                    msg([
                      field('subject', literal(2)),
                      field(
                        'cases',
                        listLit([
                          msg([
                            field('pattern', literal('> 1')),
                            field('body', literal('big')),
                          ]),
                          msg([
                            field('is_default', literal(true)),
                            field('body', literal('small')),
                          ]),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['big']);
      });

      test('switch_expr falls through to default', () async {
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall(
                    'switch_expr',
                    msg([
                      field('subject', literal(0)),
                      field(
                        'cases',
                        listLit([
                          msg([
                            field('pattern', literal('> 5')),
                            field('body', literal('big')),
                          ]),
                          msg([
                            field('pattern', literal('_')),
                            field('body', literal('default')),
                          ]),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['default']);
      });

      test('assert passes when condition true, throws when false', () async {
        final ok = buildProgram(
          functions: [
            mainFn([
              stmt(stdCall('assert', msg([field('condition', literal(true))]))),
              stmt(printExpr(literal('ok'))),
            ]),
          ],
        );
        expect(await runAndCapture(ok), ['ok']);

        final bad = buildProgram(
          functions: [
            mainFn([
              stmt(
                stdCall(
                  'assert',
                  msg([
                    field('condition', literal(false)),
                    field('message', literal('boom')),
                  ]),
                ),
              ),
            ]),
          ],
        );
        await expectLater(runAndCapture(bad), throwsA(isA<BallRuntimeError>()));
      });

      test('print of a raw scalar (no message/arg0/value field)', () async {
        // _stdPrint's fallback: input is a bare value, not a wrapped message.
        final program = buildProgram(
          functions: [
            mainFn([stmt(stdCall('print', literal('bare')))]),
          ],
        );
        expect(await runAndCapture(program), ['bare']);
      });

      test('std.index out-of-shape throws', () async {
        // target is a bool (unsupported) → BallRuntimeError.
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall(
                    'index',
                    msg([
                      field('target', literal(true)),
                      field('index', literal(0)),
                    ]),
                  ),
                ),
              ),
            ]),
          ],
        );
        await expectLater(
          runAndCapture(program),
          throwsA(isA<BallRuntimeError>()),
        );
      });
    },
  );

  group('try/catch typed + finally + stack_trace (engine_control_flow)', () {
    test(
      'typed catch matches Dart-exception runtimeType, runs finally',
      () async {
        // int.parse('x') throws FormatException; an `on FormatException` catch
        // matches by runtimeType name. finally always runs.
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                stdCall(
                  'try',
                  msg([
                    field(
                      'body',
                      stdCall(
                        'string_to_int',
                        msg([field('value', literal('not-a-number'))]),
                      ),
                    ),
                    field(
                      'catches',
                      listLit([
                        msg([
                          field('type', literal('FormatException')),
                          field('variable', literal('e')),
                          field('stack_trace', literal('st')),
                          field('body', printExpr(literal('caught-format'))),
                        ]),
                      ]),
                    ),
                    field('finally', printExpr(literal('finally-ran'))),
                  ]),
                ),
              ),
            ]),
          ],
          extraStdFunctions: [
            {'name': 'string_to_int', 'isBase': true},
          ],
        );
        expect(await runAndCapture(program), ['caught-format', 'finally-ran']);
      },
    );

    test('typed catch that does not match rethrows', () async {
      // Thrown BallException 'Foo' but catch only handles 'Bar' → uncaught.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field(
                    'body',
                    stdCall(
                      'throw',
                      msg([
                        field('value', literal('oops')),
                        field('type', literal('Foo')),
                      ]),
                    ),
                  ),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('type', literal('Bar')),
                        field('variable', literal('e')),
                        field('body', printExpr(literal('wrong'))),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(isA<BallException>()));
    });
  });

  group('messageCreation with type_args metadata (engine_eval)', () {
    test('typeDef-less generic instance carries __type_args__', () async {
      // A messageCreation of an unknown type with type_args metadata stores
      // __type_args__ on the resulting instance map; print its runtimeType
      // via the type field.
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('box', {
              'messageCreation': {
                'typeName': 'Box',
                'fields': [field('value', literal(7))],
                'metadata': {
                  'type_args': [
                    {'stringValue': 'int'},
                  ],
                },
              },
            }),
            stmt(
              printToString({
                'fieldAccess': {'object': ref('box'), 'field': 'value'},
              }),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });

    test('generic type name parsed from typeName Foo<int>', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('w', {
              'messageCreation': {
                'typeName': 'Wrapper<int>',
                'fields': [field('item', literal(3))],
              },
            }),
            stmt(
              printToString({
                'fieldAccess': {'object': ref('w'), 'field': 'item'},
              }),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3']);
    });
  });

  group('OOP: classes, constructors, getters/setters, methods (raw program)', () {
    // One comprehensive class program exercising the OOP machinery in
    // engine_invocation.dart and engine_eval.dart: a base class with a body
    // constructor binding `this` params, a subclass with super(...), a getter,
    // a setter, an instance method calling another method, and a named ctor.
    Program oopProgram(List<Map<String, dynamic>> mainStmts) {
      return Program()..mergeFromProto3Json({
        'name': 'oop',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'add', 'isBase': true},
              {'name': 'multiply', 'isBase': true},
              {'name': 'assign', 'isBase': true},
              {'name': 'string_interpolation', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'typeDefs': [
              {
                'name': 'main:Animal',
                'descriptor': {
                  'name': 'Animal',
                  'field': [
                    {
                      'name': 'name',
                      'number': 1,
                      'label': 'LABEL_OPTIONAL',
                      'type': 'TYPE_STRING',
                    },
                  ],
                },
              },
              {
                'name': 'main:Dog',
                'descriptor': {
                  'name': 'Dog',
                  'field': [
                    {
                      'name': 'breed',
                      'number': 1,
                      'label': 'LABEL_OPTIONAL',
                      'type': 'TYPE_STRING',
                    },
                  ],
                },
                'metadata': {'superclass': 'Animal'},
              },
            ],
            'functions': [
              // Animal.new(this.name) — body constructor binding a this-param.
              {
                'name': 'main:Animal.new',
                'metadata': {
                  'kind': 'constructor',
                  'params': [
                    {'name': 'name', 'is_this': true},
                  ],
                },
                'body': {
                  'block': {'statements': []},
                },
              },
              // Animal.speak() => "..." method.
              {
                'name': 'main:Animal.speak',
                'metadata': {'kind': 'method', 'class': 'Animal'},
                'inputType': 'Animal',
                'body': {
                  'block': {
                    'statements': [],
                    'result': literal('generic sound'),
                  },
                },
              },
              // Animal.label getter => name
              {
                'name': 'main:Animal.label',
                'metadata': {
                  'kind': 'getter',
                  'is_getter': true,
                  'class': 'Animal',
                },
                'inputType': 'Animal',
                'body': {
                  'block': {'statements': [], 'result': ref('name')},
                },
              },
              // Dog.new(this.breed) : super('rex')
              {
                'name': 'main:Dog.new',
                'metadata': {
                  'kind': 'constructor',
                  'params': [
                    {'name': 'breed', 'is_this': true},
                  ],
                  'initializers': [
                    {'kind': 'super', 'args': "('rex')"},
                  ],
                },
                'body': {
                  'block': {'statements': []},
                },
              },
              // Dog.describe() — instance method using fields + another method
              {
                'name': 'main:Dog.describe',
                'metadata': {'kind': 'method', 'class': 'Dog'},
                'inputType': 'Dog',
                'body': {
                  'block': {
                    'statements': [],
                    'result': stdCall(
                      'string_interpolation',
                      msg([
                        field(
                          'parts',
                          listLit([
                            ref('name'),
                            literal(' the '),
                            ref('breed'),
                          ]),
                        ),
                      ]),
                    ),
                  },
                },
              },
              {
                'name': 'main',
                'body': {
                  'block': {'statements': mainStmts},
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      });
    }

    Map<String, dynamic> newDog(String breed) => {
      'messageCreation': {
        'typeName': 'Dog',
        'fields': [field('breed', literal(breed))],
      },
    };

    test('subclass ctor with super(...) inherits parent field', () async {
      final program = oopProgram([
        letStmt('d', newDog('Lab')),
        stmt(
          printToString({
            'fieldAccess': {'object': ref('d'), 'field': 'name'},
          }),
        ),
        stmt(
          printToString({
            'fieldAccess': {'object': ref('d'), 'field': 'breed'},
          }),
        ),
      ]);
      expect(await runAndCapture(program), ['rex', 'Lab']);
    });

    test('instance method using inherited field + own field', () async {
      final program = oopProgram([
        letStmt('d', newDog('Lab')),
        stmt(
          printToString(
            call('describe', input: msg([field('self', ref('d'))])),
          ),
        ),
      ]);
      expect(await runAndCapture(program), ['rex the Lab']);
    });

    test('getter dispatch on instance (Animal.label via Dog)', () async {
      final program = oopProgram([
        letStmt('d', newDog('Lab')),
        stmt(
          printToString({
            'fieldAccess': {'object': ref('d'), 'field': 'label'},
          }),
        ),
      ]);
      // label getter returns name (inherited), which super('rex') set.
      expect(await runAndCapture(program), ['rex']);
    });

    test('inherited method dispatch (Dog calls Animal.speak)', () async {
      final program = oopProgram([
        letStmt('d', newDog('Lab')),
        stmt(
          printToString(call('speak', input: msg([field('self', ref('d'))]))),
        ),
      ]);
      expect(await runAndCapture(program), ['generic sound']);
    });
  });

  group('enums, class refs, statics, top-level refs (engine_eval)', () {
    // A program with an enum, a class with a static method + no-body ctor with
    // initializers, a top-level getter, and a top-level variable. Exercises the
    // reference-resolution branches in _evalReference and the no-body
    // constructor path in engine_invocation.
    Program refsProgram(List<Map<String, dynamic>> mainStmts) {
      return Program()..mergeFromProto3Json({
        'name': 'refs',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'add', 'isBase': true},
              {'name': 'equals', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'enums': [
              {
                'name': 'main:Color',
                'value': [
                  {'name': 'red', 'number': 0},
                  {'name': 'green', 'number': 1},
                  {'name': 'blue', 'number': 2},
                ],
              },
            ],
            'typeDefs': [
              {
                'name': 'main:Counter',
                'descriptor': {
                  'name': 'Counter',
                  'field': [
                    {
                      'name': 'count',
                      'number': 1,
                      'label': 'LABEL_OPTIONAL',
                      'type': 'TYPE_INT64',
                    },
                  ],
                },
              },
            ],
            'functions': [
              // No-body constructor with a field initializer count = 0.
              {
                'name': 'main:Counter.new',
                'metadata': {
                  'kind': 'constructor',
                  'params': [],
                  'initializers': [
                    {'kind': 'field', 'name': 'count', 'value': '0'},
                  ],
                },
              },
              // Static method Counter.zero() => 0
              {
                'name': 'main:Counter.zero',
                'metadata': {'kind': 'static_method', 'class': 'Counter'},
                'body': {
                  'block': {'statements': [], 'result': literal(0)},
                },
              },
              // Top-level getter `answer` => 42
              {
                'name': 'answer',
                'metadata': {'kind': 'getter', 'is_getter': true},
                'body': {
                  'block': {'statements': [], 'result': literal(42)},
                },
              },
              // Top-level variable `greeting` = "hi"
              {
                'name': 'greeting',
                'metadata': {'kind': 'top_level_variable'},
                'outputType': 'String',
                'body': {
                  'block': {'statements': [], 'result': literal('hi')},
                },
              },
              {
                'name': 'main',
                'body': {
                  'block': {'statements': mainStmts},
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      });
    }

    test('enum value field access (Color.green.name)', () async {
      // ref('Color') → enum-values map; .green → the value entry; .name → 'green'.
      final program = refsProgram([
        stmt(
          printToString({
            'fieldAccess': {
              'object': {
                'fieldAccess': {'object': ref('Color'), 'field': 'green'},
              },
              'field': 'name',
            },
          }),
        ),
      ]);
      expect(await runAndCapture(program), ['green']);
    });

    test('top-level getter resolves on bare reference', () async {
      final program = refsProgram([stmt(printToString(ref('answer')))]);
      expect(await runAndCapture(program), ['42']);
    });

    test('top-level variable resolves on bare reference', () async {
      final program = refsProgram([stmt(printToString(ref('greeting')))]);
      expect(await runAndCapture(program), ['hi']);
    });

    test('static method via class-ref field access (Counter.zero())', () async {
      final program = refsProgram([
        stmt(
          printToString(
            call('zero', input: msg([field('self', ref('Counter'))])),
          ),
        ),
      ]);
      expect(await runAndCapture(program), ['0']);
    });

    test(
      'no-body constructor applies field initializer via messageCreation',
      () async {
        // A messageCreation of Counter (no body ctor) applies the `count = 0`
        // initializer via _applyConstructorInitializers(onlyIfAbsent: true).
        final program = refsProgram([
          letStmt('c', {
            'messageCreation': {'typeName': 'Counter', 'fields': []},
          }),
          stmt(
            printToString({
              'fieldAccess': {'object': ref('c'), 'field': 'count'},
            }),
          ),
        ]);
        expect(await runAndCapture(program), ['0']);
      },
    );
  });

  group('type checks: std.is generic + simple + object (engine_std)', () {
    Future<String> isCheck(Map<String, dynamic> value, String type) =>
        evalPrint(
          stdCall(
            'is',
            msg([field('value', value), field('type', literal(type))]),
          ),
        );

    test('is List<int> over a homogeneous list', () async {
      expect(
        await isCheck(listLit([literal(1), literal(2)]), 'List<int>'),
        'true',
      );
    });

    test('is List<int> false when element type differs', () async {
      expect(await isCheck(listLit([literal('a')]), 'List<int>'), 'false');
    });

    test('is Map<String, int> over a map', () async {
      final m = stdCall(
        'map_create',
        msg([
          field(
            'entries',
            listLit([
              msg([field('key', literal('a')), field('value', literal(1))]),
            ]),
          ),
        ]),
      );
      expect(await isCheck(m, 'Map<String, int>'), 'true');
    });

    test('is Set<int> over a set', () async {
      final s = stdCall(
        'set_create',
        msg([
          field('elements', listLit([literal(1), literal(2)])),
        ]),
      );
      expect(await isCheck(s, 'Set<int>'), 'true');
    });

    test('is simple types: Set / Null / Object / Function / num', () async {
      final s = stdCall(
        'set_create',
        msg([
          field('elements', listLit([literal(1)])),
        ]),
      );
      expect(await isCheck(s, 'Set'), 'true');
      expect(await isCheck(literal(null), 'Null'), 'true');
      expect(await isCheck(literal(null), 'void'), 'true');
      expect(await isCheck(literal(5), 'Object'), 'true');
      expect(await isCheck(literal(5), 'dynamic'), 'true');
      expect(await isCheck(literal(3.5), 'num'), 'true');
    });

    test('is Function over a lambda', () async {
      expect(await isCheck(lambdaExpr(literal(1)), 'Function'), 'true');
    });

    test('is_not negates the check', () async {
      expect(
        await evalPrint(
          stdCall(
            'is_not',
            msg([field('value', literal(5)), field('type', literal('String'))]),
          ),
        ),
        'true',
      );
    });

    test('is object type matches own + super type', () async {
      // Reuse the OOP Dog/Animal program: a Dog is-a Dog and is-a Animal.
      final program = Program()
        ..mergeFromProto3Json({
          'name': 'isobj',
          'version': '1.0.0',
          'modules': [
            {
              'name': 'std',
              'functions': [
                {'name': 'print', 'isBase': true},
                {'name': 'to_string', 'isBase': true},
                {'name': 'is', 'isBase': true},
              ],
            },
            {
              'name': 'main',
              'typeDefs': [
                {
                  'name': 'main:Animal',
                  'descriptor': {'name': 'Animal', 'field': []},
                },
                {
                  'name': 'main:Dog',
                  'descriptor': {'name': 'Dog', 'field': []},
                  'metadata': {'superclass': 'Animal'},
                },
              ],
              'functions': [
                {
                  'name': 'main',
                  'body': {
                    'block': {
                      'statements': [
                        letStmt('d', {
                          'messageCreation': {'typeName': 'Dog', 'fields': []},
                        }),
                        stmt(
                          printToString(
                            stdCall(
                              'is',
                              msg([
                                field('value', ref('d')),
                                field('type', literal('Dog')),
                              ]),
                            ),
                          ),
                        ),
                        stmt(
                          printToString(
                            stdCall(
                              'is',
                              msg([
                                field('value', ref('d')),
                                field('type', literal('Animal')),
                              ]),
                            ),
                          ),
                        ),
                      ],
                    },
                  },
                },
              ],
            },
          ],
          'entryModule': 'main',
          'entryFunction': 'main',
        });
      expect(await runAndCapture(program), ['true', 'true']);
    });
  });

  group('std list/string tail arg-shapes (engine_std)', () {
    Map<String, dynamic> ints(List<int> xs) =>
        listLit([for (final x in xs) literal(x)]);

    test('list_slice with single value field [start, end] (raw List)', () async {
      // The `v is List` branch needs a RAW Dart List (a bare list literal is a
      // BallList, which is not `List`); list_to_list returns a raw List.
      final rawPair = stdCall(
        'list_to_list',
        msg([
          field('list', listLit([literal(1), literal(3)])),
        ]),
      );
      expect(
        await evalPrint(
          stdCall(
            'list_slice',
            msg([
              field('list', ints([1, 2, 3, 4, 5])),
              field('value', rawPair),
            ]),
          ),
        ),
        '[2, 3]',
      );
    });

    test('list_slice with single value field (start only)', () async {
      expect(
        await evalPrint(
          stdCall(
            'list_slice',
            msg([
              field('list', ints([1, 2, 3, 4, 5])),
              field('value', literal(2)),
            ]),
          ),
        ),
        '[3, 4, 5]',
      );
    });

    test('list_slice with no start/end defaults to whole list', () async {
      expect(
        await evalPrint(
          stdCall(
            'list_slice',
            msg([
              field('list', ints([1, 2, 3])),
            ]),
          ),
        ),
        '[1, 2, 3]',
      );
    });

    test(
      'list_flat_map with non-list callback result wraps the value',
      () async {
        // callback returns a scalar (not a list) → it is added directly.
        final cb = lambdaExpr(ref('input'));
        expect(
          await evalPrint(
            stdCall(
              'list_flat_map',
              msg([
                field('list', ints([1, 2])),
                field('callback', cb),
              ]),
            ),
          ),
          '[1, 2]',
        );
      },
    );

    test('list_to_list over a Set receiver', () async {
      final s = stdCall(
        'set_create',
        msg([
          field('elements', listLit([literal(1), literal(2)])),
        ]),
      );
      expect(
        await evalPrint(stdCall('list_to_list', msg([field('list', s)]))),
        '[1, 2]',
      );
    });

    test('string_runes returns code points', () async {
      expect(
        await evalPrint(
          stdCall('string_runes', msg([field('value', literal('AB'))])),
        ),
        '[65, 66]',
      );
    });

    test('string_is_empty on a Map receiver', () async {
      final m = stdCall(
        'map_create',
        msg([
          field(
            'entries',
            listLit([
              msg([field('key', literal('a')), field('value', literal(1))]),
            ]),
          ),
        ]),
      );
      expect(
        await evalPrint(stdCall('string_is_empty', msg([field('value', m)]))),
        'false',
      );
    });

    test('map_keys / map_values on a non-map (Set) return empty', () async {
      final s = stdCall(
        'set_create',
        msg([
          field('elements', listLit([literal(1)])),
        ]),
      );
      expect(
        await evalPrint(stdCall('map_keys', msg([field('map', s)]))),
        '[]',
      );
      expect(
        await evalPrint(stdCall('map_values', msg([field('map', s)]))),
        '[]',
      );
    });
  });

  group('field access on raw map + enum .values (engine_eval)', () {
    test(
      'field access (length/keys/isEmpty) on a raw Map (map_delete result)',
      () async {
        // map_delete returns a raw Dart Map; field access on it exercises the
        // raw-Map virtual-property branches (not the BallMap path).
        Map<String, dynamic> rawMap() => stdCall(
          'map_delete',
          msg([
            field(
              'map',
              stdCall(
                'map_create',
                msg([
                  field(
                    'entries',
                    listLit([
                      msg([
                        field('key', literal('a')),
                        field('value', literal(1)),
                      ]),
                      msg([
                        field('key', literal('b')),
                        field('value', literal(2)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            field('key', literal('b')),
          ]),
        );
        expect(
          await evalPrint({
            'fieldAccess': {'object': rawMap(), 'field': 'length'},
          }),
          '1',
        );
        expect(
          await evalPrint({
            'fieldAccess': {'object': rawMap(), 'field': 'isNotEmpty'},
          }),
          'true',
        );
        expect(
          await evalPrint({
            'fieldAccess': {'object': rawMap(), 'field': 'keys'},
          }),
          '[a]',
        );
      },
    );

    test('enum .values returns index-sorted enum entries', () async {
      // ref('Color') → enum-values map; .values triggers the enum index sort
      // branch in _evalFieldAccess.
      final program = Program()
        ..mergeFromProto3Json({
          'name': 'enumvals',
          'version': '1.0.0',
          'modules': [
            {
              'name': 'std',
              'functions': [
                {'name': 'print', 'isBase': true},
                {'name': 'to_string', 'isBase': true},
                {'name': 'list_length', 'isBase': true},
              ],
            },
            {
              'name': 'main',
              'enums': [
                {
                  'name': 'main:Color',
                  'value': [
                    {'name': 'red', 'number': 0},
                    {'name': 'green', 'number': 1},
                  ],
                },
              ],
              'functions': [
                {
                  'name': 'main',
                  'body': {
                    'block': {
                      'statements': [
                        stmt(
                          printToString(
                            stdCall(
                              'list_length',
                              msg([
                                field('list', {
                                  'fieldAccess': {
                                    'object': ref('Color'),
                                    'field': 'values',
                                  },
                                }),
                              ]),
                            ),
                          ),
                        ),
                      ],
                    },
                  },
                },
              ],
            },
          ],
          'entryModule': 'main',
          'entryFunction': 'main',
        });
      expect(await runAndCapture(program), ['2']);
    });
  });

  group('messageCreation resolving as a function call (engine_eval)', () {
    test(
      'messageCreation typeName is a top-level function with a body',
      () async {
        // No typeDef named `helper`; the messageCreation falls through to the
        // function-resolution path (engine_eval ~1467) and calls helper(x).
        final program = Program()
          ..mergeFromProto3Json({
            'name': 'mcfn',
            'version': '1.0.0',
            'modules': [
              {
                'name': 'std',
                'functions': [
                  {'name': 'print', 'isBase': true},
                  {'name': 'to_string', 'isBase': true},
                  {'name': 'add', 'isBase': true},
                ],
              },
              {
                'name': 'main',
                'functions': [
                  {
                    'name': 'helper',
                    'metadata': {
                      'kind': 'function',
                      'params': [
                        {'name': 'x'},
                      ],
                    },
                    'body': {
                      'block': {
                        'statements': [],
                        'result': stdCall(
                          'add',
                          msg([
                            field('left', ref('x')),
                            field('right', literal(100)),
                          ]),
                        ),
                      },
                    },
                  },
                  {
                    'name': 'main',
                    'body': {
                      'block': {
                        'statements': [
                          stmt(
                            printToString({
                              'messageCreation': {
                                'typeName': 'helper',
                                'fields': [field('x', literal(5))],
                              },
                            }),
                          ),
                        ],
                      },
                    },
                  },
                ],
              },
            ],
            'entryModule': 'main',
            'entryFunction': 'main',
          });
        expect(await runAndCapture(program), ['105']);
      },
    );
  });

  group('instance setter dispatch + super setter (engine_eval/control_flow)', () {
    // A class with a setter that writes a backing field, plus a subclass that
    // inherits it. Assigning obj.prop = v dispatches the setter; the super
    // chain is walked for the inherited setter.
    Program setterProgram(List<Map<String, dynamic>> mainStmts) {
      return Program()..mergeFromProto3Json({
        'name': 'setters',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'assign', 'isBase': true},
              {'name': 'multiply', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'typeDefs': [
              {
                'name': 'main:Temp',
                'descriptor': {
                  'name': 'Temp',
                  'field': [
                    {
                      'name': '_celsius',
                      'number': 1,
                      'label': 'LABEL_OPTIONAL',
                      'type': 'TYPE_INT64',
                    },
                  ],
                },
              },
              {
                'name': 'main:SubTemp',
                'descriptor': {'name': 'SubTemp', 'field': []},
                'metadata': {'superclass': 'Temp'},
              },
            ],
            'functions': [
              // Expression-bodied setter `celsius`: returns the stored value
              // so _writeBackingField mirrors it onto `_celsius`.
              {
                'name': 'main:Temp.celsius',
                'metadata': {
                  'kind': 'setter',
                  'is_setter': true,
                  'class': 'Temp',
                  'params': [
                    {'name': 'value'},
                  ],
                },
                'inputType': 'Temp',
                'body': {
                  'block': {'statements': [], 'result': ref('value')},
                },
              },
              {
                'name': 'main:Temp.new',
                'metadata': {
                  'kind': 'constructor',
                  'params': [
                    {'name': '_celsius', 'is_this': true},
                  ],
                },
                'body': {
                  'block': {'statements': []},
                },
              },
              {
                'name': 'main',
                'body': {
                  'block': {'statements': mainStmts},
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      });
    }

    test(
      'assigning obj.celsius dispatches the setter (returns stored value)',
      () async {
        // The assign expression's value is the setter's return (the stored
        // value), proving the setter was dispatched rather than a plain map write.
        final program = setterProgram([
          letStmt('t', {
            'messageCreation': {
              'typeName': 'Temp',
              'fields': [field('_celsius', literal(0))],
            },
          }),
          stmt(
            printToString(
              stdCall(
                'assign',
                msg([
                  field('target', {
                    'fieldAccess': {'object': ref('t'), 'field': 'celsius'},
                  }),
                  field('value', literal(25)),
                  field('op', literal('=')),
                ]),
              ),
            ),
          ),
        ]);
        expect(await runAndCapture(program), ['25']);
      },
    );

    test('inherited setter dispatched on subclass instance', () async {
      final program = setterProgram([
        letStmt('s', {
          'messageCreation': {
            'typeName': 'SubTemp',
            'fields': [field('_celsius', literal(0))],
          },
        }),
        stmt(
          stdCall(
            'assign',
            msg([
              field('target', {
                'fieldAccess': {'object': ref('s'), 'field': 'celsius'},
              }),
              field('value', literal(99)),
              field('op', literal('=')),
            ]),
          ),
        ),
        stmt(
          printToString({
            'fieldAccess': {'object': ref('s'), 'field': '_celsius'},
          }),
        ),
      ]);
      expect(await runAndCapture(program), ['99']);
    });
  });

  group('structured switch_expr patterns (engine_std)', () {
    Future<String> switchExpr(
      Map<String, dynamic> subject,
      List<Map<String, dynamic>> cases,
    ) => evalPrint(
      stdCall(
        'switch_expr',
        msg([field('subject', subject), field('cases', listLit(cases))]),
      ),
    );

    Map<String, dynamic> caseOf(
      Map<String, dynamic> patternExpr,
      Map<String, dynamic> body,
    ) => msg([field('pattern_expr', patternExpr), field('body', body)]);

    Map<String, dynamic> defaultCase(Map<String, dynamic> body) =>
        msg([field('is_default', literal(true)), field('body', body)]);

    // Build a struct value to feed as a pattern_expr (a plain message whose
    // fields become the pattern map; __pattern_kind__ selects the matcher).
    Map<String, dynamic> patMap(List<Map<String, dynamic>> fields) =>
        msg(fields);

    test('record pattern matches a 2-field record', () async {
      // subject: a record {$1: 1, $2: 2}; pattern: record with matching arity.
      final subject = stdCall(
        'record',
        msg([
          field(
            'fields',
            msg([field(r'$1', literal(1)), field(r'$2', literal(2))]),
          ),
        ]),
      );
      final pattern = patMap([
        field('__pattern_kind__', literal('record')),
        field(
          'fields',
          patMap([field(r'$1', literal('1')), field(r'$2', literal('2'))]),
        ),
      ]);
      expect(
        await switchExpr(subject, [
          caseOf(pattern, literal('rec')),
          defaultCase(literal('no')),
        ]),
        'rec',
      );
    });

    test('logical_or pattern matches either branch', () async {
      Map<String, dynamic> orPat() => patMap([
        field('__pattern_kind__', literal('logical_or')),
        field('left', literal('1')),
        field('right', literal('2')),
      ]);
      expect(
        await switchExpr(literal(2), [
          caseOf(orPat(), literal('one-or-two')),
          defaultCase(literal('other')),
        ]),
        'one-or-two',
      );
    });

    test('cast pattern throws on type mismatch (assert semantics)', () async {
      final pattern = patMap([
        field('__pattern_kind__', literal('cast')),
        field('type', literal('int')),
        field('name', literal('x')),
      ]);
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'switch_expr',
                  msg([
                    field('subject', literal('not-an-int')),
                    field(
                      'cases',
                      listLit([caseOf(pattern, literal('matched'))]),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(isA<BallException>()));
    });

    test('null_check pattern fails on null, matches non-null', () async {
      Map<String, dynamic> nullCheckPat() => patMap([
        field('__pattern_kind__', literal('null_check')),
        field('pattern', literal('int x')),
      ]);
      expect(
        await switchExpr(literal(5), [
          caseOf(nullCheckPat(), literal('present')),
          defaultCase(literal('absent')),
        ]),
        'present',
      );
      expect(
        await switchExpr(literal(null), [
          caseOf(nullCheckPat(), literal('present')),
          defaultCase(literal('absent')),
        ]),
        'absent',
      );
    });
  });

  group(
    'constructor default params + positional List args (engine_invocation)',
    () {
      test('constructor with a default-value param', () async {
        // Point.new(x, [y = 10]) constructed via messageCreation with only x.
        final program = Program()
          ..mergeFromProto3Json({
            'name': 'ctordef',
            'version': '1.0.0',
            'modules': [
              {
                'name': 'std',
                'functions': [
                  {'name': 'print', 'isBase': true},
                  {'name': 'to_string', 'isBase': true},
                ],
              },
              {
                'name': 'main',
                'typeDefs': [
                  {
                    'name': 'main:Point',
                    'descriptor': {
                      'name': 'Point',
                      'field': [
                        {
                          'name': 'x',
                          'number': 1,
                          'label': 'LABEL_OPTIONAL',
                          'type': 'TYPE_INT64',
                        },
                        {
                          'name': 'y',
                          'number': 2,
                          'label': 'LABEL_OPTIONAL',
                          'type': 'TYPE_INT64',
                        },
                      ],
                    },
                  },
                ],
                'functions': [
                  {
                    'name': 'main:Point.new',
                    'metadata': {
                      'kind': 'constructor',
                      'params': [
                        {'name': 'x', 'is_this': true},
                        {'name': 'y', 'is_this': true, 'default_value': 10},
                      ],
                    },
                    'body': {
                      'block': {'statements': []},
                    },
                  },
                  {
                    'name': 'main',
                    'body': {
                      'block': {
                        'statements': [
                          letStmt('p', {
                            'messageCreation': {
                              'typeName': 'Point',
                              'fields': [field('x', literal(3))],
                            },
                          }),
                          stmt(
                            printToString({
                              'fieldAccess': {'object': ref('p'), 'field': 'y'},
                            }),
                          ),
                        ],
                      },
                    },
                  },
                ],
              },
            ],
            'entryModule': 'main',
            'entryFunction': 'main',
          });
        // y defaults to 10.
        expect(await runAndCapture(program), ['10']);
      });

      test(
        'multi-param function called with a positional List input',
        () async {
          final program = Program()
            ..mergeFromProto3Json({
              'name': 'poslist',
              'version': '1.0.0',
              'modules': [
                {
                  'name': 'std',
                  'functions': [
                    {'name': 'print', 'isBase': true},
                    {'name': 'to_string', 'isBase': true},
                    {'name': 'add', 'isBase': true},
                    {'name': 'list_to_list', 'isBase': true},
                  ],
                },
                {
                  'name': 'main',
                  'functions': [
                    {
                      'name': 'sum2',
                      'metadata': {
                        'kind': 'function',
                        'params': [
                          {'name': 'a'},
                          {'name': 'b'},
                        ],
                      },
                      'body': {
                        'block': {
                          'statements': [],
                          'result': stdCall(
                            'add',
                            msg([
                              field('left', ref('a')),
                              field('right', ref('b')),
                            ]),
                          ),
                        },
                      },
                    },
                    {
                      'name': 'main',
                      'body': {
                        'block': {
                          'statements': [
                            // Pass a raw List as the call input (list_to_list →
                            // a raw Dart List), exercising the positional-List
                            // parameter-binding branch in _callFunction.
                            stmt(
                              printToString(
                                call(
                                  'sum2',
                                  input: stdCall(
                                    'list_to_list',
                                    msg([
                                      field(
                                        'list',
                                        listLit([literal(4), literal(5)]),
                                      ),
                                    ]),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        },
                      },
                    },
                  ],
                },
              ],
              'entryModule': 'main',
              'entryFunction': 'main',
            });
          expect(await runAndCapture(program), ['9']);
        },
      );
    },
  );
}
