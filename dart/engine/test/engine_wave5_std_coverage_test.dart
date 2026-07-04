// Wave-5 coverage tests for engine_std.dart — the std base-function dispatch
// table and its helpers.
//
// A natural continuation of engine_std_coverage_test.dart and
// engine_tail_coverage_test.dart: every test builds a minimal Program and runs
// it through a real BallEngine, asserting on captured stdout (or on a thrown
// error for the fail-loud paths). It targets the harder-to-reach branches:
//   * the dispatch-table "fallbacks" for functions that _evalCall normally
//     intercepts lazily (and/or, increments, if, cascade, map_create,
//     switch_expr, labeled/label/goto) — reached here by calling them with an
//     EMPTY module so the lazy switch (keyed on the current module being std)
//     is skipped and the call routes through _resolveAndCallFunction → the
//     eager base dispatch;
//   * alternate-receiver branches (a BallMap value built via messageCreation is
//     NOT a Dart Map, so it exercises the `collection is BallMap` arms);
//   * type-coercion helpers (_toInt/_toNum/_toDouble/_toBool) via divide/
//     subtract/math ops fed mixed operand types;
//   * pattern-matching internals via a bare (eager) switch_expr carrying
//     structured __pattern_kind__ maps;
//   * error paths (m == null guards, empty-collection StateErrors, sandbox-free
//     exit/panic);
//   * native Dart Set/Iterable/List injected through a custom module handler.
//
// Field-name conventions match the engine's extractors: binary ops read
// left/right, unary ops read value, list ops read list/value/index/callback,
// map ops read map/key/value, set ops read set/left/right, etc.
import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Self-contained builder helpers (independent of engine_test.dart). ──

Future<List<String>> runAndCapture(
  Program program, {
  List<BallModuleHandler>? handlers,
  void Function(String)? stderr,
  bool sandbox = false,
}) async {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    stderr: stderr,
    moduleHandlers: handlers,
    sandbox: sandbox,
  );
  await engine.run();
  return lines;
}

// A broad declaration list so every function these tests reference — including
// the ones only reachable through the eager fallback dispatch — resolves to a
// declared std base function.
const _stdFnNames = <String>[
  'print', 'add', 'subtract', 'multiply', 'divide', 'divide_double', 'modulo',
  'negate', 'less_than', 'greater_than', 'lte', 'gte', 'equals', 'not_equals',
  'and', 'or', 'not', 'to_string', 'if', 'for', 'for_in', 'while', 'do_while',
  'return', 'break', 'continue', 'assign', 'string_interpolation',
  'pre_increment', 'pre_decrement', 'post_increment', 'post_decrement',
  'to_double', 'to_int', 'int_to_double', 'double_to_int', 'int_to_string',
  'double_to_string', 'string_to_int', 'string_to_double', 'compare_to',
  'to_string_as_fixed', 'index', 'switch', 'switch_expr', 'try', 'throw',
  'yield', 'yield_each', 'cascade', 'null_aware_cascade', 'null_aware_access',
  'null_aware_call', 'record', 'spread', 'null_spread', 'collection_for',
  'collection_if', 'invoke', 'tear_off', 'paren', 'symbol', 'type_literal',
  'null_coalesce', 'null_check', 'assert', 'is', 'is_not', 'as', 'labeled',
  'label', 'goto', 'length', 'concat',
  // collections
  'list_push', 'list_pop', 'list_get', 'list_set', 'list_length',
  'list_is_empty', 'list_first', 'list_last', 'list_single', 'list_contains',
  'list_index_of', 'list_map', 'list_filter', 'list_reduce', 'list_find',
  'list_any', 'list_all', 'list_none', 'list_sort', 'list_sort_by',
  'list_reverse', 'list_slice', 'list_flat_map', 'list_zip', 'list_take',
  'list_drop', 'list_concat', 'list_clear', 'list_to_list', 'list_foreach',
  'list_join', 'list_generate', 'dart_list_generate', 'list_filled',
  'dart_list_filled', 'typed_list',
  'map_create', 'map_get', 'map_set', 'map_delete', 'map_contains_key',
  'map_contains_value', 'map_put_if_absent', 'map_keys', 'map_values',
  'map_entries', 'map_from_entries', 'map_merge', 'map_map', 'map_filter',
  'map_is_empty', 'map_length',
  'set_create', 'set_add', 'set_remove', 'set_contains', 'set_union',
  'set_intersection', 'set_difference', 'set_length', 'set_is_empty',
  'set_to_list', 'string_join',
  // strings
  'string_length', 'string_is_empty', 'string_concat', 'string_contains',
  'string_substring', 'string_char_at', 'string_char_code_at',
  'string_code_unit_at', 'string_replace', 'string_replace_all', 'string_split',
  'string_runes', 'string_repeat', 'string_pad_left', 'string_pad_right',
  'regex_replace', 'regex_replace_all',
  // math / convert / io
  'math_abs', 'math_sqrt', 'math_pow', 'math_pi', 'math_e', 'math_min',
  'math_max', 'math_clamp', 'json_encode', 'json_decode', 'print_error',
  'exit', 'panic', 'env_get', 'args_get',
];

Program buildProgram({
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> extraModules = const [],
  List<Map<String, dynamic>> extraStdFunctions = const [],
  List<Map<String, dynamic>> mainTypeDefs = const [],
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
  final mainModule = {
    'name': 'main',
    if (mainTypeDefs.isNotEmpty) 'typeDefs': mainTypeDefs,
    'functions': functions,
  };
  final programJson = {
    'name': 'test',
    'version': '1.0.0',
    'modules': [stdModule, ...extraModules, mainModule],
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

/// Bare (module-empty) call — routes through _resolveAndCallFunction to the
/// eager base dispatch instead of _evalCall's lazy std switch.
Map<String, dynamic> bareCall(String function, Map<String, dynamic> input) =>
    call(function, input: input);

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

/// A messageCreation used as a plain data value: with an empty typeName it
/// evaluates to a BallMap (NOT a Dart Map), exercising `is BallMap` arms.
Map<String, dynamic> ballMapValue(List<Map<String, dynamic>> fields) =>
    msg(fields);

// A handler that hands back native Dart collections so the `is Set` /
// `is Iterable` / raw-List branches (which only occur on non-Dart self-hosts or
// via handler injection) can be reached.
class _NativeHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'ext';

  @override
  Object? call(String function, Object? input, BallCallable engine) {
    switch (function) {
      case 'native_set':
        return {1, 2, 3};
      case 'native_iterable':
        // A lazy Iterable that is neither a List nor a Set.
        return [10, 20, 30].map((e) => e);
      case 'native_list':
        return <Object?>['int'];
      case 'native_ballbool':
        return const BallBool(true);
      default:
        throw BallRuntimeError('unknown ext fn: "$function"');
    }
  }
}

Map<String, dynamic> _extModule() => {
  'name': 'ext',
  'functions': [
    {'name': 'native_set', 'isBase': true},
    {'name': 'native_iterable', 'isBase': true},
    {'name': 'native_list', 'isBase': true},
    {'name': 'native_ballbool', 'isBase': true},
  ],
};

void main() {
  group('logical/increment dispatch fallbacks (bare call)', () {
    test('bare `and` reaches _stdBinaryBool fallback', () async {
      expect(
        await evalToString(
          bareCall(
            'and',
            msg([field('left', literal(true)), field('right', literal(false))]),
          ),
        ),
        'false',
      );
    });

    test('bare `or` reaches _stdBinaryBool fallback', () async {
      expect(
        await evalToString(
          bareCall(
            'or',
            msg([field('left', literal(false)), field('right', literal(true))]),
          ),
        ),
        'true',
      );
    });

    test('bare pre/post increment & decrement fallbacks', () async {
      expect(
        await evalToString(
          bareCall('pre_increment', msg([field('value', literal(5))])),
        ),
        '6',
      );
      expect(
        await evalToString(
          bareCall('pre_decrement', msg([field('value', literal(5))])),
        ),
        '4',
      );
      expect(
        await evalToString(
          bareCall('post_increment', msg([field('value', literal(5))])),
        ),
        '6',
      );
      expect(
        await evalToString(
          bareCall('post_decrement', msg([field('value', literal(5))])),
        ),
        '4',
      );
    });
  });

  group('control-flow dispatch fallbacks (bare call)', () {
    test(
      'bare `if` fallback selects then/else on pre-evaluated input',
      () async {
        expect(
          await evalToString(
            bareCall(
              'if',
              msg([
                field('condition', literal(true)),
                field('then', literal('T')),
                field('else', literal('F')),
              ]),
            ),
          ),
          'T',
        );
        expect(
          await evalToString(
            bareCall(
              'if',
              msg([
                field('condition', literal(false)),
                field('then', literal('T')),
                field('else', literal('F')),
              ]),
            ),
          ),
          'F',
        );
      },
    );

    test('bare `if` with non-message input throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(call('if', input: literal(3)))]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('bare `cascade` fallback returns target / passthrough', () async {
      expect(
        await evalToString(
          bareCall('cascade', msg([field('target', literal('X'))])),
        ),
        'X',
      );
      // Non-message input → returned unchanged.
      expect(await evalToString(call('cascade', input: literal('Y'))), 'Y');
    });

    test('bare `null_aware_cascade` fallback', () async {
      expect(
        await evalToString(
          bareCall('null_aware_cascade', msg([field('target', literal('Z'))])),
        ),
        'Z',
      );
      expect(
        await evalToString(call('null_aware_cascade', input: literal('W'))),
        'W',
      );
    });

    test('bare `labeled` fallback returns null', () async {
      expect(
        await evalToString(
          bareCall('labeled', msg([field('body', literal(1))])),
        ),
        'null',
      );
    });

    test('bare `label` fallback returns the body', () async {
      expect(
        await evalToString(bareCall('label', msg([field('body', literal(7))]))),
        '7',
      );
      // Non-message input → null.
      expect(await evalToString(call('label', input: literal(3))), 'null');
    });

    test('bare `goto` with non-message input returns null', () async {
      expect(await evalToString(call('goto', input: literal('x'))), 'null');
    });

    test('bare `goto` with a label throws a flow signal', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(bareCall('goto', msg([field('label', literal('L'))]))),
          ]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(anything));
    });

    test('bare `yield` / `yield_each` fallbacks produce a flow signal', () async {
      // Outside a generator these dispatch entries yield a _FlowSignal, which the
      // block evaluator returns as the block value — no output, no crash.
      final y = buildProgram(
        functions: [
          mainFn([
            stmt(bareCall('yield', msg([field('value', literal(5))]))),
          ]),
        ],
      );
      final ye = buildProgram(
        functions: [
          mainFn([
            stmt(
              bareCall(
                'yield_each',
                msg([
                  field('value', listLit([literal(1), literal(2)])),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(y), isEmpty);
      expect(await runAndCapture(ye), isEmpty);
    });

    test('bare `null_aware_call` fallbacks return null', () async {
      expect(
        await evalToString(call('null_aware_call', input: literal(1))),
        'null',
      );
      expect(
        await evalToString(
          stdCall('null_aware_call', msg([field('target', literal(5))])),
        ),
        'null',
      );
    });
  });

  group('numeric conversion helpers', () {
    test('double_to_string wraps a bare double (math_pi)', () async {
      expect(
        await evalToString(
          stdCall(
            'double_to_string',
            msg([field('value', stdCall('math_pi', msg([])))]),
          ),
        ),
        '3.141592653589793',
      );
    });

    test(
      '_toInt over BallDouble / bare double / String / bool via divide',
      () async {
        // BallDouble operands (double literals).
        expect(
          await evalToString(
            stdCall(
              'divide',
              msg([field('left', literal(7.0)), field('right', literal(2.0))]),
            ),
          ),
          '3',
        );
        // Bare-double left (math_pi) ~/ BallDouble.
        expect(
          await evalToString(
            stdCall(
              'divide',
              msg([
                field('left', stdCall('math_pi', msg([]))),
                field('right', literal(1.0)),
              ]),
            ),
          ),
          '3',
        );
        // String operands.
        expect(
          await evalToString(
            stdCall(
              'divide',
              msg([field('left', literal('7')), field('right', literal('2'))]),
            ),
          ),
          '3',
        );
        // bool operands (true→1, true→1).
        expect(
          await evalToString(
            stdCall(
              'divide',
              msg([
                field('left', literal(true)),
                field('right', literal(true)),
              ]),
            ),
          ),
          '1',
        );
      },
    );

    test('_toDouble over String (math_sqrt) and throw on bool', () async {
      expect(
        await evalToString(
          stdCall('math_sqrt', msg([field('value', literal('16'))])),
        ),
        '4.0',
      );
      final bad = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('math_sqrt', msg([field('value', literal(true))])),
              ),
            ),
          ]),
        ],
      );
      await expectLater(runAndCapture(bad), throwsA(isA<BallRuntimeError>()));
    });

    test(
      '_toNum over String / bool / null via subtract, throw on list',
      () async {
        expect(
          await evalToString(
            stdCall(
              'subtract',
              msg([field('left', literal('10')), field('right', literal('3'))]),
            ),
          ),
          '7',
        );
        expect(
          await evalToString(
            stdCall(
              'subtract',
              msg([
                field('left', literal(true)),
                field('right', literal(false)),
              ]),
            ),
          ),
          '1',
        );
        expect(
          await evalToString(
            stdCall(
              'subtract',
              msg([field('left', literal(null)), field('right', literal(5))]),
            ),
          ),
          '-5',
        );
        final bad = buildProgram(
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall(
                    'subtract',
                    msg([
                      field('left', listLit([literal(1)])),
                      field('right', literal(2)),
                    ]),
                  ),
                ),
              ),
            ]),
          ],
        );
        await expectLater(runAndCapture(bad), throwsA(isA<BallRuntimeError>()));
      },
    );

    test('_toBool throws on non-bool via `not`', () async {
      final bad = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(stdCall('not', msg([field('value', literal(42))]))),
            ),
          ]),
        ],
      );
      await expectLater(runAndCapture(bad), throwsA(isA<BallRuntimeError>()));
    });

    test('_extractBinaryArgs throws when input is not a message', () async {
      final bad = buildProgram(
        functions: [
          mainFn([stmt(call('add', module: 'std', input: literal(5)))]),
        ],
      );
      await expectLater(runAndCapture(bad), throwsA(isA<BallRuntimeError>()));
    });

    test('std.length over String, List, and throw on int', () async {
      expect(
        await evalToString(
          stdCall('length', msg([field('value', literal('abc'))])),
        ),
        '3',
      );
      expect(
        await evalToString(
          stdCall(
            'length',
            msg([
              field('value', listLit([literal(1), literal(2)])),
            ]),
          ),
        ),
        '2',
      );
      final bad = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('length', msg([field('value', literal(42))])),
              ),
            ),
          ]),
        ],
      );
      await expectLater(runAndCapture(bad), throwsA(isA<BallRuntimeError>()));
    });
  });

  group('string_interpolation, tear_off, symbol fallbacks', () {
    test('string_interpolation stringifies a non-message input', () async {
      expect(
        await evalToString(
          call('string_interpolation', module: 'std', input: literal('hi')),
        ),
        'hi',
      );
    });

    test(
      'string_interpolation with an empty message stringifies the map',
      () async {
        final lines = await runAndCapture(
          buildProgram(
            functions: [
              mainFn([
                stmt(printExpr(stdCall('string_interpolation', msg([])))),
              ]),
            ],
          ),
        );
        expect(lines.single, '{}');
      },
    );

    test('tear_off returns the callback then it is invoked', () async {
      // tear_off({method: <lambda>}) → lambda; invoke it with 21.
      final torn = stdCall(
        'tear_off',
        msg([
          field(
            'method',
            lambdaExpr(
              stdCall(
                'multiply',
                msg([field('left', ref('input')), field('right', literal(2))]),
              ),
            ),
          ),
        ]),
      );
      final invoked = stdCall(
        'invoke',
        msg([field('callee', torn), field('arg0', literal(21))]),
      );
      expect(await evalToString(invoked), '42');
    });
  });

  group('list op branches & errors', () {
    test('list_reduce on empty list throws StateError', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'list_reduce',
                  msg([
                    field('list', listLit([])),
                    field('callback', lambdaExpr(literal(0))),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(isA<StateError>()));
    });

    test('list_find with no match throws StateError', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'list_find',
                  msg([
                    field('list', listLit([literal(1), literal(2)])),
                    field('callback', lambdaExpr(literal(false))),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(isA<StateError>()));
    });

    test('list_concat on a set stays a de-duplicated set', () async {
      final s = stdCall(
        'set_create',
        msg([
          field('elements', listLit([literal(1), literal(2)])),
        ]),
      );
      final concatenated = stdCall(
        'list_concat',
        msg([
          field('list', s),
          field('value', listLit([literal(2), literal(3)])),
        ]),
      );
      expect(await evalToString(concatenated), '{1, 2, 3}');
    });

    test('list_clear on a set stays an (emptied) set', () async {
      final s = stdCall(
        'set_create',
        msg([
          field('elements', listLit([literal(1), literal(2)])),
        ]),
      );
      expect(
        await evalToString(stdCall('list_clear', msg([field('list', s)]))),
        '{}',
      );
    });

    test('list_clear on a non-collection yields empty list', () async {
      expect(
        await evalToString(
          stdCall('list_clear', msg([field('list', literal(42))])),
        ),
        '[]',
      );
    });

    test('list_to_list on a non-collection yields empty list', () async {
      expect(
        await evalToString(
          stdCall('list_to_list', msg([field('list', literal(42))])),
        ),
        '[]',
      );
    });

    test('list_foreach over a BallMap iterates its entries', () async {
      // A messageCreation value is a BallMap (not a Dart Map) → `is BallMap` arm.
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'm',
              ballMapValue([field('a', literal(1)), field('b', literal(2))]),
            ),
            stmt(
              stdCall(
                'list_foreach',
                msg([
                  field('list', ref('m')),
                  field(
                    'function',
                    lambdaExpr(
                      printToString(
                        stdCall(
                          'index',
                          msg([
                            field('target', ref('input')),
                            field('index', literal('value')),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines, ['1', '2']);
    });
  });

  group('map op branches & errors', () {
    test('map_contains_key throws on a non Map/Set target', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'map_contains_key',
                  msg([field('map', literal(42)), field('key', literal('x'))]),
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

    test('map_contains_value over a BallMap value', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('m', ballMapValue([field('a', literal(7))])),
            stmt(
              printToString(
                stdCall(
                  'map_contains_value',
                  msg([field('map', ref('m')), field('value', literal(7))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });

    test(
      'map_map with a scalar-returning callback keeps original keys',
      () async {
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt('m', ballMapValue([field('a', literal(1))])),
              stmt(
                printToString(
                  stdCall(
                    'map_map',
                    msg([
                      field('map', ref('m')),
                      field('callback', lambdaExpr(literal(99))),
                    ]),
                  ),
                ),
              ),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['{a: 99}']);
      },
    );

    test(
      'map_is_empty / map_length on a non-map throw (defensive cast)',
      () async {
        final p1 = buildProgram(
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall('map_is_empty', msg([field('map', literal(42))])),
                ),
              ),
            ]),
          ],
        );
        final p2 = buildProgram(
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall('map_length', msg([field('map', literal(42))])),
                ),
              ),
            ]),
          ],
        );
        final p3 = buildProgram(
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall('map_entries', msg([field('map', literal(42))])),
                ),
              ),
            ]),
          ],
        );
        await expectLater(runAndCapture(p1), throwsA(anything));
        await expectLater(runAndCapture(p2), throwsA(anything));
        await expectLater(runAndCapture(p3), throwsA(anything));
      },
    );
  });

  group('set op branches', () {
    test('set_add of an already-present value returns the same set', () async {
      final s = stdCall(
        'set_create',
        msg([
          field('elements', listLit([literal(1), literal(2)])),
        ]),
      );
      expect(
        await evalToString(
          stdCall(
            'set_add',
            msg([field('set', s), field('value', literal(1))]),
          ),
        ),
        '{1, 2}',
      );
    });

    test(
      'set_create with non-message and no-elements yields empty set',
      () async {
        expect(
          await evalToString(
            call('set_create', module: 'std', input: literal(5)),
          ),
          '{}',
        );
        expect(await evalToString(stdCall('set_create', msg([]))), '{}');
      },
    );

    test(
      'set_length on a set-shaped map with a non-list payload is empty',
      () async {
        // Build a raw map {'__ball_set__': 42} via map_create — recognised as a
        // set by the marker key, but its payload is not a list (→ empty items).
        final setShaped = stdCall(
          'map_create',
          msg([
            field(
              'entries',
              listLit([
                msg([
                  field('key', literal('__ball_set__')),
                  field('value', literal(42)),
                ]),
              ]),
            ),
          ]),
        );
        expect(
          await evalToString(
            stdCall('set_length', msg([field('set', setShaped)])),
          ),
          '0',
        );
      },
    );

    test('set_length on a plain list (not a set) is empty', () async {
      expect(
        await evalToString(
          stdCall(
            'set_length',
            msg([
              field('set', listLit([literal(1), literal(2)])),
            ]),
          ),
        ),
        '0',
      );
    });
  });

  group('index / cascade / invoke / collection_misuse', () {
    test('std.index into a BallMap value', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('m', ballMapValue([field('k', literal(42))])),
            stmt(
              printToString(
                stdCall(
                  'index',
                  msg([
                    field('target', ref('m')),
                    field('index', literal('k')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['42']);
    });

    test('std.index on a non-message throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(call('index', module: 'std', input: literal(5)))]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('list_generate / list_filled fail loud on bad input', () async {
      final g1 = buildProgram(
        functions: [
          mainFn([
            stmt(call('list_generate', module: 'std', input: literal(3))),
          ]),
        ],
      );
      final g2 = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'list_generate',
                msg([
                  field('length', literal(3)),
                  field('generator', literal(5)),
                ]),
              ),
            ),
          ]),
        ],
      );
      final f1 = buildProgram(
        functions: [
          mainFn([stmt(call('list_filled', module: 'std', input: literal(3)))]),
        ],
      );
      await expectLater(runAndCapture(g1), throwsA(isA<BallRuntimeError>()));
      await expectLater(runAndCapture(g2), throwsA(isA<BallRuntimeError>()));
      await expectLater(runAndCapture(f1), throwsA(isA<BallRuntimeError>()));
    });

    test('std.invoke fail-loud and multi-arg path', () async {
      final i1 = buildProgram(
        functions: [
          mainFn([stmt(call('invoke', module: 'std', input: literal(5)))]),
        ],
      );
      final i2 = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('invoke', msg([field('callee', literal(5))]))),
          ]),
        ],
      );
      await expectLater(runAndCapture(i1), throwsA(isA<BallRuntimeError>()));
      await expectLater(runAndCapture(i2), throwsA(isA<BallRuntimeError>()));

      // Multi-arg invoke: passes the whole args map to the callee.
      final multi = stdCall(
        'invoke',
        msg([
          field(
            'callee',
            lambdaExpr(
              stdCall(
                'add',
                msg([
                  field(
                    'left',
                    stdCall(
                      'index',
                      msg([
                        field('target', ref('input')),
                        field('index', literal('a')),
                      ]),
                    ),
                  ),
                  field(
                    'right',
                    stdCall(
                      'index',
                      msg([
                        field('target', ref('input')),
                        field('index', literal('b')),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          field('a', literal(3)),
          field('b', literal(4)),
        ]),
      );
      expect(await evalToString(multi), '7');
    });

    test(
      'collection_if / collection_for as standalone calls fail loud',
      () async {
        final c1 = buildProgram(
          functions: [
            mainFn([
              stmt(
                stdCall(
                  'collection_if',
                  msg([field('condition', literal(true))]),
                ),
              ),
            ]),
          ],
        );
        final c2 = buildProgram(
          functions: [
            mainFn([
              stmt(
                stdCall('collection_for', msg([field('value', literal(1))])),
              ),
            ]),
          ],
        );
        await expectLater(runAndCapture(c1), throwsA(isA<BallRuntimeError>()));
        await expectLater(runAndCapture(c2), throwsA(isA<BallRuntimeError>()));
      },
    );
  });

  group('string helper m==null throws & string_split fallback', () {
    Future<void> expectThrows(String fn) async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(call(fn, module: 'std', input: literal('x')))]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    }

    test(
      'substring/char_at/char_code_at/replace/regex_replace/repeat/pad',
      () async {
        await expectThrows('string_substring');
        await expectThrows('string_char_at');
        await expectThrows('string_char_code_at');
        await expectThrows('string_replace');
        await expectThrows('regex_replace');
        await expectThrows('string_repeat');
        await expectThrows('string_pad_left');
      },
    );

    test(
      'string_is_empty on a non-collection scalar throws (String cast)',
      () async {
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall(
                    'string_is_empty',
                    msg([field('value', literal(42))]),
                  ),
                ),
              ),
            ]),
          ],
        );
        await expectLater(runAndCapture(program), throwsA(anything));
      },
    );

    test('string_split on a non-message returns empty list', () async {
      expect(
        await evalToString(
          call('string_split', module: 'std', input: literal('x')),
        ),
        '[]',
      );
    });

    test('math_clamp on a non-message throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(call('math_clamp', module: 'std', input: literal(5)))]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test(
      'json_encode of a callable value hits the toString fallback',
      () async {
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                printExpr(
                  stdCall(
                    'json_encode',
                    msg([field('value', lambdaExpr(literal(1)))]),
                  ),
                ),
              ),
            ]),
          ],
        );
        final lines = await runAndCapture(program);
        expect(lines.single.startsWith('"'), isTrue);
      },
    );
  });

  group('print alternate keys & eager map_create', () {
    test('print reads the `value` key when `message` is absent', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('print', msg([field('value', literal('hey'))]))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['hey']);
    });

    test(
      'bare map_create (eager) — entries, single entry, empty, non-message',
      () async {
        // entries list form.
        expect(
          await evalToString(
            bareCall(
              'map_create',
              msg([
                field(
                  'entries',
                  listLit([
                    msg([
                      field('key', literal('x')),
                      field('value', literal(1)),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
          '{x: 1}',
        );
        // single-entry form.
        expect(
          await evalToString(
            bareCall(
              'map_create',
              msg([
                field(
                  'entry',
                  msg([field('key', literal('y')), field('value', literal(2))]),
                ),
              ]),
            ),
          ),
          '{y: 2}',
        );
        // empty message → empty map.
        expect(await evalToString(bareCall('map_create', msg([]))), '{}');
        // non-message input → empty map.
        expect(await evalToString(call('map_create', input: literal(5))), '{}');
      },
    );
  });

  group('object stringification', () {
    test(
      'object typed *Error returns message, or short type when absent',
      () async {
        expect(
          await evalToString(
            ballMapValue([
              field('__type__', literal('main:MyError')),
              field('message', literal('boom')),
            ]),
          ),
          'boom',
        );
        expect(
          await evalToString(
            ballMapValue([field('__type__', literal('main:MyError'))]),
          ),
          'MyError',
        );
      },
    );

    test('toString recursion guard renders Type{...}', () async {
      expect(
        await evalToString(
          ballMapValue([
            field('__type__', literal('main:Widget')),
            field('__tostring_guard__', literal(true)),
          ]),
        ),
        'Widget{...}',
      );
    });

    test(
      'to_string on a subclass walks __super__ to an inherited toString',
      () async {
        // Dog's typeDef declares superclass Animal; Dog has no toString, so
        // _resolveMethod walks the superclass chain to Animal.toString.
        final program = buildProgram(
          mainTypeDefs: [
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
              'descriptor': {'name': 'Dog'},
              'metadata': {'superclass': 'Animal'},
            },
          ],
          functions: [
            {
              'name': 'main:Animal.toString',
              'metadata': {'kind': 'method', 'class': 'Animal'},
              'inputType': 'Animal',
              'body': {
                'block': {
                  'statements': [],
                  'result': literal('I am an animal'),
                },
              },
            },
            mainFn([
              letStmt(
                'd',
                ballMapValue([
                  field('__type__', literal('main:Dog')),
                  field('name', literal('rex')),
                ]),
              ),
              stmt(printToString(ref('d'))),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['I am an animal']);
      },
    );

    test('to_string resolves an inherited toString via a mixin', () async {
      // Robot has no superclass and no own toString, but mixes in Walker, whose
      // toString _resolveMethod finds by walking the mixin list.
      final program = buildProgram(
        mainTypeDefs: [
          {
            'name': 'main:Walker',
            'descriptor': {'name': 'Walker'},
          },
          {
            'name': 'main:Robot',
            'descriptor': {'name': 'Robot'},
            'metadata': {
              'mixins': ['Walker'],
            },
          },
        ],
        functions: [
          {
            'name': 'main:Walker.toString',
            'metadata': {'kind': 'method', 'class': 'Walker'},
            'inputType': 'Walker',
            'body': {
              'block': {'statements': [], 'result': literal('I walk')},
            },
          },
          mainFn([
            letStmt(
              'r',
              ballMapValue([field('__type__', literal('main:Robot'))]),
            ),
            stmt(printToString(ref('r'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['I walk']);
    });

    test(
      'object with an unqualified __type__ resolves toString (modPart)',
      () async {
        // No colon → _resolveMethod uses _currentModule; no method found → the
        // BallMap's own toString is used.
        final out = await evalToString(
          ballMapValue([
            field('__type__', literal('Widget')),
            field('a', literal(1)),
          ]),
        );
        expect(out.contains('Widget'), isTrue);
      },
    );
  });

  group('type checks (is)', () {
    test('is Null matches a null value', () async {
      expect(
        await evalToString(
          stdCall(
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

    test('generic type args as a String (non-bracketed) match', () async {
      final box = ballMapValue([
        field('__type__', literal('main:Box')),
        field('__type_args__', literal('int')),
      ]);
      expect(
        await evalToString(
          stdCall(
            'is',
            msg([field('value', box), field('type', literal('Box<int>'))]),
          ),
        ),
        'true',
      );
    });

    test('is against a super-chain type walks __super__', () async {
      final obj = ballMapValue([
        field('__type__', literal('main:Child')),
        field(
          '__super__',
          ballMapValue([
            field('__type__', literal('main:Mid')),
            field(
              '__super__',
              ballMapValue([field('__type__', literal('main:Base'))]),
            ),
          ]),
        ),
      ]);
      expect(
        await evalToString(
          stdCall(
            'is',
            msg([field('value', obj), field('type', literal('Base'))]),
          ),
        ),
        'true',
      );
    });

    test(
      'is with two differently-qualified names compares bare names',
      () async {
        final obj = ballMapValue([field('__type__', literal('main:Foo'))]);
        expect(
          await evalToString(
            stdCall(
              'is',
              msg([field('value', obj), field('type', literal('other:Foo'))]),
            ),
          ),
          'true',
        );
      },
    );
  });

  group('bare switch_expr (eager) + string patterns', () {
    Map<String, dynamic> switchExpr(
      Map<String, dynamic> subject,
      List<Map<String, dynamic>> cases,
    ) => bareCall(
      'switch_expr',
      msg([field('subject', subject), field('cases', listLit(cases))]),
    );

    Map<String, dynamic> caseOf(
      Map<String, dynamic> pattern,
      Map<String, dynamic> body, {
      Map<String, dynamic>? guard,
      bool isDefault = false,
    }) {
      final fields = <Map<String, dynamic>>[
        field('pattern', pattern),
        field('body', body),
      ];
      if (guard != null) fields.add(field('guard', guard));
      if (isDefault) fields.add(field('is_default', literal(true)));
      return msg(fields);
    }

    test('string type-bind pattern matches and returns the body', () async {
      expect(
        await evalToString(
          switchExpr(literal(5), [caseOf(literal('int x'), literal('is-int'))]),
        ),
        'is-int',
      );
    });

    test('relational string pattern `<= 100`', () async {
      expect(
        await evalToString(
          switchExpr(literal(50), [
            caseOf(literal('<= 100'), literal('small')),
          ]),
        ),
        'small',
      );
    });

    test('Null string pattern via _matchesTypePattern', () async {
      expect(
        await evalToString(
          switchExpr(literal(null), [
            caseOf(literal('Null'), literal('was-null')),
          ]),
        ),
        'was-null',
      );
    });

    test('guard that fails falls through to the default case', () async {
      expect(
        await evalToString(
          switchExpr(literal(5), [
            caseOf(
              literal('int x'),
              literal('guarded'),
              guard: lambdaExpr(literal(false)),
            ),
            caseOf(literal('_'), literal('fallback'), isDefault: true),
          ]),
        ),
        'fallback',
      );
    });

    test('a function body is called with the bindings', () async {
      expect(
        await evalToString(
          switchExpr(literal(7), [
            caseOf(literal('int x'), lambdaExpr(literal('fn-body'))),
          ]),
        ),
        'fn-body',
      );
    });

    test('non-exhaustive switch expression throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                switchExpr(literal(5), [
                  caseOf(literal('String s'), literal('str')),
                ]),
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

    test('non-message input and non-list cases return null', () async {
      expect(
        await evalToString(call('switch_expr', input: literal(5))),
        'null',
      );
      expect(
        await evalToString(
          bareCall(
            'switch_expr',
            msg([field('subject', literal(5)), field('cases', literal(5))]),
          ),
        ),
        'null',
      );
    });
  });

  group('bare switch_expr — structured patterns', () {
    Map<String, dynamic> switchExpr(
      Map<String, dynamic> subject,
      List<Map<String, dynamic>> cases,
    ) => bareCall(
      'switch_expr',
      msg([field('subject', subject), field('cases', listLit(cases))]),
    );

    Map<String, dynamic> caseOf(
      Map<String, dynamic> pattern,
      Map<String, dynamic> body, {
      bool isDefault = false,
    }) {
      final fields = <Map<String, dynamic>>[
        field('pattern', pattern),
        field('body', body),
      ];
      if (isDefault) fields.add(field('is_default', literal(true)));
      return msg(fields);
    }

    test('object pattern matches by bare type name + field wildcard', () async {
      final point = ballMapValue([
        field('__type__', literal('main:Point')),
        field('x', literal(1)),
        field('y', literal(2)),
      ]);
      final pattern = ballMapValue([
        field('__pattern_kind__', literal('object')),
        field('type', literal('Point')),
        field('fields', ballMapValue([field('x', literal('_'))])),
      ]);
      expect(
        await evalToString(
          switchExpr(point, [caseOf(pattern, literal('is-point'))]),
        ),
        'is-point',
      );
    });

    test(
      'object pattern with a type mismatch falls through to default',
      () async {
        final circle = ballMapValue([
          field('__type__', literal('main:Circle')),
        ]);
        final pattern = ballMapValue([
          field('__pattern_kind__', literal('object')),
          field('type', literal('Point')),
        ]);
        expect(
          await evalToString(
            switchExpr(circle, [
              caseOf(pattern, literal('point')),
              caseOf(literal('_'), literal('other'), isDefault: true),
            ]),
          ),
          'other',
        );
      },
    );

    test(
      'object pattern with a colon-qualified type matches by bare name',
      () async {
        // pattern type carries a module prefix while the value's __type__ carries
        // a different one → both are reduced to their bare names before comparing.
        final other = ballMapValue([field('__type__', literal('other:Point'))]);
        final pattern = ballMapValue([
          field('__pattern_kind__', literal('object')),
          field('type', literal('main:Point')),
        ]);
        expect(
          await evalToString(
            switchExpr(other, [caseOf(pattern, literal('qualified'))]),
          ),
          'qualified',
        );
      },
    );

    test('cast pattern binds on a matching type', () async {
      final pattern = ballMapValue([
        field('__pattern_kind__', literal('cast')),
        field('type', literal('int')),
        field('name', literal('n')),
      ]);
      expect(
        await evalToString(
          switchExpr(literal(5), [caseOf(pattern, literal('cast-ok'))]),
        ),
        'cast-ok',
      );
    });

    test('null_check pattern requires non-null + subpattern', () async {
      final pattern = ballMapValue([
        field('__pattern_kind__', literal('null_check')),
        field('pattern', literal('int x')),
      ]);
      expect(
        await evalToString(
          switchExpr(literal(5), [caseOf(pattern, literal('nn'))]),
        ),
        'nn',
      );
    });

    test('rest pattern delegates to its subpattern', () async {
      final pattern = ballMapValue([
        field('__pattern_kind__', literal('rest')),
        field('subpattern', literal('int x')),
      ]);
      expect(
        await evalToString(
          switchExpr(literal(5), [caseOf(pattern, literal('rest-ok'))]),
        ),
        'rest-ok',
      );
    });

    test('relational structured pattern `<=`', () async {
      final pattern = ballMapValue([
        field('__pattern_kind__', literal('relational')),
        field('operator', literal('<=')),
        field('operand', literal(100)),
      ]);
      expect(
        await evalToString(
          switchExpr(literal(50), [caseOf(pattern, literal('rel'))]),
        ),
        'rel',
      );
    });

    test(
      'map structured pattern against a non-map value falls through',
      () async {
        final pattern = ballMapValue([
          field('__pattern_kind__', literal('map')),
          field('entries', listLit([])),
        ]);
        expect(
          await evalToString(
            switchExpr(literal(5), [
              caseOf(pattern, literal('m')),
              caseOf(literal('_'), literal('no-map'), isDefault: true),
            ]),
          ),
          'no-map',
        );
      },
    );

    test('default-kind pattern matches by per-field value equality', () async {
      final subject = ballMapValue([field('x', literal(1))]);
      final pattern = ballMapValue([
        field('__ignore__', literal(0)),
        field('x', literal(1)),
      ]);
      expect(
        await evalToString(
          switchExpr(subject, [caseOf(pattern, literal('def-ok'))]),
        ),
        'def-ok',
      );
    });

    test('list pattern with a middle rest element (…rest…)', () async {
      final pattern = ballMapValue([
        field('__pattern_kind__', literal('list')),
        field(
          'elements',
          listLit([
            ballMapValue([
              field('__pattern_kind__', literal('const')),
              field('value', literal(1)),
            ]),
            ballMapValue([field('__pattern_kind__', literal('rest'))]),
            ballMapValue([
              field('__pattern_kind__', literal('const')),
              field('value', literal(3)),
            ]),
          ]),
        ),
        field('rest', literal('r')),
      ]);
      final value = listLit([literal(1), literal(2), literal(2), literal(3)]);
      expect(
        await evalToString(
          switchExpr(value, [caseOf(pattern, literal('list-ok'))]),
        ),
        'list-ok',
      );
    });
  });

  group('for_in _toIterable coverage', () {
    test('for_in over a BallMap iterates {key,value} entries', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'm',
              ballMapValue([field('a', literal(1)), field('b', literal(2))]),
            ),
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('e')),
                  field('iterable', ref('m')),
                  field(
                    'body',
                    printToString(
                      stdCall(
                        'index',
                        msg([
                          field('target', ref('e')),
                          field('index', literal('key')),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['a', 'b']);
    });

    test('for_in over a raw map (map_create) iterates entries', () async {
      final rawMap = stdCall(
        'map_create',
        msg([
          field(
            'entries',
            listLit([
              msg([field('key', literal('k1')), field('value', literal(9))]),
            ]),
          ),
        ]),
      );
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('e')),
                  field('iterable', rawMap),
                  field(
                    'body',
                    printToString(
                      stdCall(
                        'index',
                        msg([
                          field('target', ref('e')),
                          field('index', literal('value')),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['9']);
    });

    test('for_in over a non-iterable throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('e')),
                  field('iterable', literal(42)),
                  field('body', printToString(ref('e'))),
                ]),
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
  });

  group('exit / panic', () {
    test('std.exit halts the program', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printExpr(literal('before'))),
            stmt(stdCall('exit', msg([field('code', literal(0))]))),
            stmt(printExpr(literal('after'))),
          ]),
        ],
      );
      // exit throws _ExitSignal (implements Exception); run() propagates it and
      // the CLI is what catches it. Assert the pre-exit output was emitted.
      final lines = <String>[];
      final engine = BallEngine(program, stdout: lines.add);
      await expectLater(engine.run(), throwsA(anything));
      expect(lines, ['before']);
    });

    test('std.panic writes to stderr and halts', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printExpr(literal('before'))),
            stmt(stdCall('panic', msg([field('message', literal('kaboom'))]))),
            stmt(printExpr(literal('after'))),
          ]),
        ],
      );
      final lines = <String>[];
      final errs = <String>[];
      final engine = BallEngine(program, stdout: lines.add, stderr: errs.add);
      await expectLater(engine.run(), throwsA(anything));
      expect(lines, ['before']);
      expect(errs, contains('kaboom'));
    });
  });

  group('native collections via a module handler', () {
    Program nativeProgram(List<Map<String, dynamic>> statements) =>
        buildProgram(
          functions: [mainFn(statements)],
          extraModules: [_extModule()],
        );

    Future<List<String>> runNative(List<Map<String, dynamic>> statements) =>
        runAndCapture(
          nativeProgram(statements),
          handlers: [StdModuleHandler(), _NativeHandler()],
        );

    test('set_to_list over a native Dart Set', () async {
      final out = await runNative([
        letStmt('s', call('native_set', module: 'ext', input: msg([]))),
        stmt(
          printToString(stdCall('set_to_list', msg([field('set', ref('s'))]))),
        ),
      ]);
      expect(out, ['[1, 2, 3]']);
    });

    test('List.of over a native Iterable materialises a list', () async {
      final listOf = call(
        'of',
        input: msg([field('self', ref('List')), field('arg0', ref('it'))]),
      );
      final out = await runNative([
        letStmt('it', call('native_iterable', module: 'ext', input: msg([]))),
        stmt(printToString(listOf)),
      ]);
      expect(out, ['[10, 20, 30]']);
    });

    test('List.of over a non-iterable yields an empty list', () async {
      final listOf = call(
        'of',
        input: msg([field('self', ref('List')), field('arg0', literal(42))]),
      );
      final out = await runNative([stmt(printToString(listOf))]);
      expect(out, ['[]']);
    });

    test('string_is_empty over a native Iterable', () async {
      final out = await runNative([
        letStmt('it', call('native_iterable', module: 'ext', input: msg([]))),
        stmt(
          printToString(
            stdCall('string_is_empty', msg([field('value', ref('it'))])),
          ),
        ),
      ]);
      expect(out, ['false']);
    });

    test('_toInt coerces a wrapped BallBool operand', () async {
      // A handler that returns a BallBool exercises the BallBool arm of _toInt
      // (divide → _stdBinaryInt → _toInt), which literals never produce.
      final out = await runNative([
        letStmt('b', call('native_ballbool', module: 'ext', input: msg([]))),
        stmt(
          printToString(
            stdCall(
              'divide',
              msg([field('left', ref('b')), field('right', literal(1))]),
            ),
          ),
        ),
      ]);
      expect(out, ['1']);
    });

    test('generic type args as a raw List match', () async {
      final box = ballMapValue([
        field('__type__', literal('main:Box')),
        field(
          '__type_args__',
          call('native_list', module: 'ext', input: msg([])),
        ),
      ]);
      final out = await runNative([
        letStmt('b', box),
        stmt(
          printToString(
            stdCall(
              'is',
              msg([
                field('value', ref('b')),
                field('type', literal('Box<int>')),
              ]),
            ),
          ),
        ),
      ]);
      expect(out, ['true']);
    });
  });
}
