// Coverage-focused tests for engine_std.dart — the std base-function handlers.
//
// Each test builds a minimal program that calls a std base function via
// `stdCall(...)` and asserts the captured stdout, exercising handlers that the
// main engine_test.dart suite does not reach. Field-name conventions match the
// engine's extractors: binary ops read left/right, unary ops read value,
// list ops read list/value/index/callback, map ops read map/key/value, etc.
import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Local copies of the builder helpers (kept independent of engine_test.dart
//    so this file is self-contained). ───────────────────────────────────────

Future<List<String>> runAndCapture(
  Program program, {
  List<BallModuleHandler>? handlers,
}) async {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    moduleHandlers: handlers,
  );
  await engine.run();
  return lines;
}

/// All std base functions referenced by these tests, declared as base fns.
const _stdFnNames = <String>[
  'print', 'add', 'subtract', 'multiply', 'divide', 'divide_double', 'modulo',
  'negate', 'less_than', 'greater_than', 'lte', 'gte', 'equals', 'not_equals',
  'and', 'or', 'not', 'to_string', 'if', 'for', 'while', 'return', 'assign',
  'string_interpolation', 'bitwise_and', 'bitwise_or', 'bitwise_xor',
  'bitwise_not', 'left_shift', 'right_shift', 'unsigned_right_shift',
  'pre_increment', 'pre_decrement', 'post_increment', 'post_decrement',
  'int_to_string', 'double_to_string', 'string_to_int', 'string_to_double',
  'to_double', 'to_int', 'int_to_double', 'double_to_int', 'compare_to',
  'to_string_as_fixed', 'null_coalesce', 'is_not', 'tear_off', 'typed_list',
  'index', 'paren',
  // list ops
  'list_push', 'list_pop', 'list_insert', 'list_remove_at', 'list_get',
  'list_set', 'list_length', 'list_is_empty', 'list_first', 'list_last',
  'list_single', 'list_contains', 'list_index_of', 'list_map', 'list_filter',
  'list_reduce', 'list_find', 'list_any', 'list_all', 'list_none', 'list_sort',
  'list_sort_by', 'list_reverse', 'list_slice', 'list_flat_map', 'list_zip',
  'list_take', 'list_drop', 'list_concat', 'list_clear', 'list_to_list',
  'list_foreach', 'list_join',
  // map ops
  'map_create', 'map_get', 'map_set', 'map_delete', 'map_contains_key',
  'map_contains_value', 'map_put_if_absent', 'map_keys', 'map_values',
  'map_entries', 'map_from_entries', 'map_merge', 'map_map', 'map_filter',
  'map_is_empty', 'map_length',
  // set ops
  'set_create', 'set_add', 'set_remove', 'set_contains', 'set_union',
  'set_intersection', 'set_difference', 'set_length', 'set_is_empty',
  'set_to_list',
  'string_join',
  // string ops
  'string_length', 'string_is_empty', 'string_concat', 'string_contains',
  'string_starts_with', 'string_ends_with', 'string_index_of',
  'string_last_index_of', 'string_substring', 'string_char_at',
  'string_char_code_at', 'string_code_unit_at', 'string_from_char_code',
  'string_to_upper', 'string_to_lower', 'string_trim', 'string_trim_start',
  'string_trim_end', 'string_replace', 'string_replace_all', 'string_split',
  'string_repeat', 'string_pad_left', 'string_pad_right',
  // regex
  'regex_match', 'regex_find', 'regex_find_all', 'regex_replace',
  'regex_replace_all',
  // math
  'math_abs', 'math_floor', 'math_ceil', 'math_round', 'math_trunc',
  'math_sqrt', 'math_pow', 'math_log', 'math_log2', 'math_log10', 'math_exp',
  'math_sin', 'math_cos', 'math_tan', 'math_asin', 'math_acos', 'math_atan',
  'math_atan2', 'math_min', 'math_max', 'math_clamp', 'math_pi', 'math_e',
  'math_infinity', 'math_nan', 'math_is_nan', 'math_is_finite',
  'math_is_infinite', 'math_sign', 'math_gcd', 'math_lcm',
  // convert / encoding
  'json_encode', 'json_decode', 'utf8_encode', 'utf8_decode', 'base64_encode',
  'base64_decode',
  // datetime
  'now', 'now_micros', 'format_timestamp', 'parse_timestamp', 'duration_add',
  'duration_subtract', 'year', 'month', 'day', 'hour', 'minute', 'second',
  'timestamp_ms',
  // io
  'print_error', 'random_int', 'random_double', 'sleep_ms', 'env_get',
  'args_get',
  // concurrency / misc
  'thread_spawn', 'thread_join', 'mutex_create', 'mutex_lock', 'mutex_unlock',
  'scoped_lock', 'atomic_load', 'atomic_store', 'atomic_compare_exchange',
  'symbol', 'type_literal', 'switch_expr',
  // builtin-class statics, index, cascade, record, string buffer
  'dart_list_generate', 'dart_list_filled', 'index', 'cascade',
  'null_aware_cascade', 'record', 'string_buffer_create', 'string_buffer_write',
  'string_buffer_to_string',
  // comprehensions & spread
  'collection_for', 'collection_if', 'spread', 'null_spread',
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
    'modules': [stdModule, mainModule],
    'entryModule': 'main',
    'entryFunction': 'main',
  };
  return Program()..mergeFromProto3Json(programJson);
}

Map<String, dynamic> literal(Object value) {
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

/// Run a single expression that already produces a string and print it raw.
Future<String> evalPrintStr(Map<String, dynamic> expr) async {
  final program = buildProgram(
    functions: [
      mainFn([stmt(printExpr(expr))]),
    ],
  );
  final lines = await runAndCapture(program);
  return lines.single;
}

Map<String, dynamic> binMsg(Object left, Object right) =>
    msg([field('left', literal(left)), field('right', literal(right))]);

Map<String, dynamic> unMsg(Object value) =>
    msg([field('value', literal(value))]);

void main() {
  group('arithmetic & numeric', () {
    test(
      'subtract',
      () async =>
          expect(await evalPrint(stdCall('subtract', binMsg(10, 3))), '7'),
    );
    test(
      'multiply',
      () async =>
          expect(await evalPrint(stdCall('multiply', binMsg(5, 6))), '30'),
    );
    test('multiply string repeat (left String)', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'multiply',
            msg([field('left', literal('ab')), field('right', literal(3))]),
          ),
        ),
        'ababab',
      );
    });
    test(
      'divide (integer)',
      () async =>
          expect(await evalPrint(stdCall('divide', binMsg(10, 3))), '3'),
    );
    test(
      'divide_double',
      () async => expect(
        await evalPrint(stdCall('divide_double', binMsg(10, 4))),
        '2.5',
      ),
    );
    test(
      'modulo',
      () async =>
          expect(await evalPrint(stdCall('modulo', binMsg(10, 3))), '1'),
    );
    test(
      'negate',
      () async => expect(await evalPrint(stdCall('negate', unMsg(5))), '-5'),
    );
    test(
      'compare_to',
      () async =>
          expect(await evalPrint(stdCall('compare_to', binMsg(2, 5))), '-1'),
    );
    test('null_coalesce non-null', () async {
      expect(
        await evalPrint(
          stdCall(
            'null_coalesce',
            msg([field('left', literal(7)), field('right', literal(9))]),
          ),
        ),
        '7',
      );
    });
    test('null_coalesce null left', () async {
      expect(
        await evalPrint(
          stdCall(
            'null_coalesce',
            msg([
              field('left', {'literal': {}}),
              field('right', literal(9)),
            ]),
          ),
        ),
        '9',
      );
    });
    test('to_string_as_fixed', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'to_string_as_fixed',
            msg([
              field('value', literal(3.14159)),
              field('digits', literal(2)),
            ]),
          ),
        ),
        '3.14',
      );
    });
  });

  group('comparison & logic', () {
    test(
      'lte true',
      () async => expect(await evalPrint(stdCall('lte', binMsg(2, 2))), 'true'),
    );
    test(
      'gte false',
      () async =>
          expect(await evalPrint(stdCall('gte', binMsg(2, 3))), 'false'),
    );
    test(
      'not_equals',
      () async =>
          expect(await evalPrint(stdCall('not_equals', binMsg(1, 2))), 'true'),
    );
    test(
      'not',
      () async => expect(await evalPrint(stdCall('not', unMsg(false))), 'true'),
    );
    test('is_not (int is not String)', () async {
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
  });

  group('bitwise', () {
    test(
      'bitwise_and',
      () async =>
          expect(await evalPrint(stdCall('bitwise_and', binMsg(6, 3))), '2'),
    );
    test(
      'bitwise_or',
      () async =>
          expect(await evalPrint(stdCall('bitwise_or', binMsg(6, 3))), '7'),
    );
    test(
      'bitwise_xor',
      () async =>
          expect(await evalPrint(stdCall('bitwise_xor', binMsg(6, 3))), '5'),
    );
    test(
      'left_shift',
      () async =>
          expect(await evalPrint(stdCall('left_shift', binMsg(1, 3))), '8'),
    );
    test(
      'right_shift',
      () async =>
          expect(await evalPrint(stdCall('right_shift', binMsg(8, 2))), '2'),
    );
    test(
      'unsigned_right_shift',
      () async => expect(
        await evalPrint(stdCall('unsigned_right_shift', binMsg(8, 1))),
        '4',
      ),
    );
  });

  group('conversions', () {
    test(
      'int_to_string',
      () async =>
          expect(await evalPrintStr(stdCall('int_to_string', unMsg(42))), '42'),
    );
    // NOTE: `double_to_string` is intentionally NOT exercised with a double
    // literal here: a double literal evaluates to a BallDouble, and the
    // handler does a bare `(v as double)` cast that throws on BallDouble.
    // The encoder never emits `double_to_string` (it routes `.toString()`
    // through the universal `to_string` op), so this is a latent dead-path
    // bug, reported separately — not fixed in this test-only change.
    test(
      'string_to_int',
      () async => expect(
        await evalPrint(stdCall('string_to_int', unMsg('123'))),
        '123',
      ),
    );
    test(
      'string_to_double',
      () async => expect(
        await evalPrint(stdCall('string_to_double', unMsg('1.5'))),
        '1.5',
      ),
    );
    test(
      'to_double',
      () async =>
          expect(await evalPrint(stdCall('to_double', unMsg(3))), '3.0'),
    );
    test(
      'to_int',
      () async => expect(await evalPrint(stdCall('to_int', unMsg(3.9))), '3'),
    );
    test(
      'int_to_double',
      () async =>
          expect(await evalPrint(stdCall('int_to_double', unMsg(4))), '4.0'),
    );
    test(
      'double_to_int',
      () async =>
          expect(await evalPrint(stdCall('double_to_int', unMsg(7.8))), '7'),
    );
  });

  group('list ops', () {
    Map<String, dynamic> ints(List<int> xs) =>
        listLit([for (final x in xs) literal(x)]);
    Map<String, dynamic> lst(String f, Map<String, dynamic> input) =>
        stdCall(f, input);

    test('list_push appends', () async {
      expect(
        await evalPrint(
          lst(
            'list_push',
            msg([
              field('list', ints([1, 2])),
              field('value', literal(3)),
            ]),
          ),
        ),
        '[1, 2, 3]',
      );
    });
    test('list_pop returns last', () async {
      expect(
        await evalPrint(
          lst(
            'list_pop',
            msg([
              field('list', ints([1, 2, 3])),
            ]),
          ),
        ),
        '3',
      );
    });
    test('list_insert', () async {
      expect(
        await evalPrint(
          lst(
            'list_insert',
            msg([
              field('list', ints([1, 3])),
              field('index', literal(1)),
              field('value', literal(2)),
            ]),
          ),
        ),
        '[1, 2, 3]',
      );
    });
    test('list_remove_at', () async {
      expect(
        await evalPrint(
          lst(
            'list_remove_at',
            msg([
              field('list', ints([1, 2, 3])),
              field('index', literal(1)),
            ]),
          ),
        ),
        '2',
      );
    });
    test('list_get', () async {
      expect(
        await evalPrint(
          lst(
            'list_get',
            msg([
              field('list', ints([10, 20, 30])),
              field('index', literal(2)),
            ]),
          ),
        ),
        '30',
      );
    });
    test('list_set', () async {
      expect(
        await evalPrint(
          lst(
            'list_set',
            msg([
              field('list', ints([1, 2, 3])),
              field('index', literal(0)),
              field('value', literal(9)),
            ]),
          ),
        ),
        '[9, 2, 3]',
      );
    });
    test('list_length', () async {
      expect(
        await evalPrint(
          lst(
            'list_length',
            msg([
              field('list', ints([1, 2, 3, 4])),
            ]),
          ),
        ),
        '4',
      );
    });
    test('list_is_empty', () async {
      expect(
        await evalPrint(
          lst('list_is_empty', msg([field('list', listLit([]))])),
        ),
        'true',
      );
    });
    test('list_first / list_last / list_single', () async {
      expect(
        await evalPrint(
          lst(
            'list_first',
            msg([
              field('list', ints([5, 6])),
            ]),
          ),
        ),
        '5',
      );
      expect(
        await evalPrint(
          lst(
            'list_last',
            msg([
              field('list', ints([5, 6])),
            ]),
          ),
        ),
        '6',
      );
      expect(
        await evalPrint(
          lst(
            'list_single',
            msg([
              field('list', ints([7])),
            ]),
          ),
        ),
        '7',
      );
    });
    test('list_contains', () async {
      expect(
        await evalPrint(
          lst(
            'list_contains',
            msg([
              field('list', ints([1, 2, 3])),
              field('value', literal(2)),
            ]),
          ),
        ),
        'true',
      );
    });
    test('list_contains string receiver', () async {
      expect(
        await evalPrint(
          lst(
            'list_contains',
            msg([
              field('list', literal('hello')),
              field('value', literal('ell')),
            ]),
          ),
        ),
        'true',
      );
    });
    test('list_index_of', () async {
      expect(
        await evalPrint(
          lst(
            'list_index_of',
            msg([
              field('list', ints([1, 2, 3])),
              field('value', literal(3)),
            ]),
          ),
        ),
        '2',
      );
    });
    test('list_index_of string receiver', () async {
      expect(
        await evalPrint(
          lst(
            'list_index_of',
            msg([field('list', literal('abc')), field('value', literal('b'))]),
          ),
        ),
        '1',
      );
    });
    test('list_map doubles', () async {
      final cb = lambdaExpr(
        stdCall(
          'multiply',
          msg([field('left', ref('input')), field('right', literal(2))]),
        ),
      );
      expect(
        await evalPrint(
          lst(
            'list_map',
            msg([
              field('list', ints([1, 2, 3])),
              field('callback', cb),
            ]),
          ),
        ),
        '[2, 4, 6]',
      );
    });
    test('list_filter evens', () async {
      final cb = lambdaExpr(
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
          lst(
            'list_filter',
            msg([
              field('list', ints([1, 2, 3, 4])),
              field('callback', cb),
            ]),
          ),
        ),
        '[2, 4]',
      );
    });
    test('list_reduce sum', () async {
      final cb = _namedLambda(
        ['a', 'b'],
        stdCall(
          'add',
          msg([field('left', ref('a')), field('right', ref('b'))]),
        ),
      );
      expect(
        await evalPrint(
          lst(
            'list_reduce',
            msg([
              field('list', ints([1, 2, 3, 4])),
              field('callback', cb),
            ]),
          ),
        ),
        '10',
      );
    });
    test('list_find first even', () async {
      final cb = lambdaExpr(
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
          lst(
            'list_find',
            msg([
              field('list', ints([1, 3, 4, 6])),
              field('callback', cb),
            ]),
          ),
        ),
        '4',
      );
    });
    test('list_any / list_all / list_none', () async {
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
          lst(
            'list_any',
            msg([
              field('list', ints([1, 2, 3])),
              field('callback', isEven),
            ]),
          ),
        ),
        'true',
      );
      expect(
        await evalPrint(
          lst(
            'list_all',
            msg([
              field('list', ints([2, 4])),
              field('callback', isEven),
            ]),
          ),
        ),
        'true',
      );
      expect(
        await evalPrint(
          lst(
            'list_none',
            msg([
              field('list', ints([1, 3])),
              field('callback', isEven),
            ]),
          ),
        ),
        'true',
      );
    });
    test('list_sort natural', () async {
      expect(
        await evalPrint(
          lst(
            'list_sort',
            msg([
              field('list', ints([3, 1, 2])),
            ]),
          ),
        ),
        '[1, 2, 3]',
      );
    });
    test('list_sort with comparator (descending)', () async {
      final cmp = _namedLambda(
        ['a', 'b'],
        stdCall(
          'subtract',
          msg([field('left', ref('b')), field('right', ref('a'))]),
        ),
      );
      expect(
        await evalPrint(
          lst(
            'list_sort',
            msg([
              field('list', ints([1, 3, 2])),
              field('callback', cmp),
            ]),
          ),
        ),
        '[3, 2, 1]',
      );
    });
    test('list_sort_by key', () async {
      final keyFn = lambdaExpr(
        stdCall('negate', msg([field('value', ref('input'))])),
      );
      expect(
        await evalPrint(
          lst(
            'list_sort_by',
            msg([
              field('list', ints([1, 2, 3])),
              field('callback', keyFn),
            ]),
          ),
        ),
        '[3, 2, 1]',
      );
    });
    test('list_reverse', () async {
      expect(
        await evalPrint(
          lst(
            'list_reverse',
            msg([
              field('list', ints([1, 2, 3])),
            ]),
          ),
        ),
        '[3, 2, 1]',
      );
    });
    test('list_slice named', () async {
      expect(
        await evalPrint(
          lst(
            'list_slice',
            msg([
              field('list', ints([1, 2, 3, 4, 5])),
              field('start', literal(1)),
              field('end', literal(3)),
            ]),
          ),
        ),
        '[2, 3]',
      );
    });
    test('list_slice positional', () async {
      expect(
        await evalPrint(
          lst(
            'list_slice',
            msg([
              field('list', ints([1, 2, 3, 4, 5])),
              field('arg0', literal(0)),
              field('arg1', literal(2)),
            ]),
          ),
        ),
        '[1, 2]',
      );
    });
    test('list_flat_map', () async {
      // The callback returns a raw List (via list_concat, which yields a
      // native List) so list_flat_map's `r is List` flatten branch fires.
      // (A bare list literal evaluates to BallList, which list_flat_map does
      // NOT flatten — unlike `expand` — a known BallList/List inconsistency.)
      final cb = lambdaExpr(
        stdCall(
          'list_concat',
          msg([
            field('list', listLit([ref('input')])),
            field('value', listLit([ref('input')])),
          ]),
        ),
      );
      expect(
        await evalPrint(
          lst(
            'list_flat_map',
            msg([
              field('list', ints([1, 2])),
              field('callback', cb),
            ]),
          ),
        ),
        '[1, 1, 2, 2]',
      );
    });
    test('list_zip', () async {
      expect(
        await evalPrint(
          lst(
            'list_zip',
            msg([
              field('list', ints([1, 2])),
              field('value', ints([3, 4])),
            ]),
          ),
        ),
        '[[1, 3], [2, 4]]',
      );
    });
    test('list_take / list_drop', () async {
      expect(
        await evalPrint(
          lst(
            'list_take',
            msg([
              field('list', ints([1, 2, 3, 4])),
              field('value', literal(2)),
            ]),
          ),
        ),
        '[1, 2]',
      );
      expect(
        await evalPrint(
          lst(
            'list_drop',
            msg([
              field('list', ints([1, 2, 3, 4])),
              field('value', literal(2)),
            ]),
          ),
        ),
        '[3, 4]',
      );
    });
    test('list_concat', () async {
      expect(
        await evalPrint(
          lst(
            'list_concat',
            msg([
              field('list', ints([1, 2])),
              field('value', ints([3, 4])),
            ]),
          ),
        ),
        '[1, 2, 3, 4]',
      );
    });
    test('list_clear', () async {
      expect(
        await evalPrint(
          lst(
            'list_clear',
            msg([
              field('list', ints([1, 2, 3])),
            ]),
          ),
        ),
        '[]',
      );
    });
    test('list_to_list', () async {
      expect(
        await evalPrint(
          lst(
            'list_to_list',
            msg([
              field('list', ints([1, 2])),
            ]),
          ),
        ),
        '[1, 2]',
      );
    });
    test('list_foreach prints each', () async {
      final cb = lambdaExpr(printToString(ref('input')));
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              lst(
                'list_foreach',
                msg([
                  field('list', ints([7, 8])),
                  field('function', cb),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7', '8']);
    });
    test('list_join', () async {
      expect(
        await evalPrintStr(
          lst(
            'list_join',
            msg([
              field('list', ints([1, 2, 3])),
              field('separator', literal('-')),
            ]),
          ),
        ),
        '1-2-3',
      );
    });
    test('string_join (std_collections)', () async {
      expect(
        await evalPrintStr(
          lst(
            'string_join',
            msg([
              field('list', ints([1, 2])),
              field('separator', literal(',')),
            ]),
          ),
        ),
        '1,2',
      );
    });
    test('typed_list returns underlying list', () async {
      expect(
        await evalPrint(
          stdCall(
            'typed_list',
            msg([
              field('elements', ints([1, 2, 3])),
            ]),
          ),
        ),
        '[1, 2, 3]',
      );
    });
  });

  group('map ops', () {
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

    test('map_get', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_get',
            msg([
              field('map', mapOf({'a': 1, 'b': 2})),
              field('key', literal('b')),
            ]),
          ),
        ),
        '2',
      );
    });
    test('map_set', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_set',
            msg([
              field('map', mapOf({'a': 1})),
              field('key', literal('b')),
              field('value', literal(2)),
            ]),
          ),
        ),
        '{a: 1, b: 2}',
      );
    });
    test('map_delete', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_delete',
            msg([
              field('map', mapOf({'a': 1, 'b': 2})),
              field('key', literal('a')),
            ]),
          ),
        ),
        '{b: 2}',
      );
    });
    test('map_contains_key', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_contains_key',
            msg([
              field('map', mapOf({'a': 1})),
              field('key', literal('a')),
            ]),
          ),
        ),
        'true',
      );
    });
    test('map_contains_value', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_contains_value',
            msg([
              field('map', mapOf({'a': 1})),
              field('value', literal(1)),
            ]),
          ),
        ),
        'true',
      );
    });
    test('map_put_if_absent absent', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_put_if_absent',
            msg([
              field('map', mapOf({'a': 1})),
              field('key', literal('b')),
              field('value', literal(5)),
            ]),
          ),
        ),
        '5',
      );
    });
    test('map_put_if_absent present', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_put_if_absent',
            msg([
              field('map', mapOf({'a': 1})),
              field('key', literal('a')),
              field('value', literal(5)),
            ]),
          ),
        ),
        '1',
      );
    });
    test('map_keys / map_values', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_keys',
            msg([
              field('map', mapOf({'a': 1, 'b': 2})),
            ]),
          ),
        ),
        '[a, b]',
      );
      expect(
        await evalPrint(
          stdCall(
            'map_values',
            msg([
              field('map', mapOf({'a': 1, 'b': 2})),
            ]),
          ),
        ),
        '[1, 2]',
      );
    });
    test('map_entries', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_entries',
            msg([
              field('map', mapOf({'a': 1})),
            ]),
          ),
        ),
        '[{key: a, value: 1}]',
      );
    });
    test('map_from_entries', () async {
      final entries = listLit([
        msg([field('key', literal('x')), field('value', literal(1))]),
        msg([field('key', literal('y')), field('value', literal(2))]),
      ]);
      expect(
        await evalPrint(
          stdCall('map_from_entries', msg([field('list', entries)])),
        ),
        '{x: 1, y: 2}',
      );
    });
    test('map_merge', () async {
      expect(
        await evalPrint(
          stdCall(
            'map_merge',
            msg([
              field('map', mapOf({'a': 1})),
              field('value', mapOf({'b': 2})),
            ]),
          ),
        ),
        '{a: 1, b: 2}',
      );
    });
    test('map_map', () async {
      final cb = _namedLambda(
        ['key', 'value'],
        msg([
          field('key', ref('key')),
          field(
            'value',
            stdCall(
              'multiply',
              msg([field('left', ref('value')), field('right', literal(10))]),
            ),
          ),
        ]),
      );
      expect(
        await evalPrint(
          stdCall(
            'map_map',
            msg([
              field('map', mapOf({'a': 1, 'b': 2})),
              field('callback', cb),
            ]),
          ),
        ),
        '{a: 10, b: 20}',
      );
    });
    test('map_filter', () async {
      final cb = _namedLambda(
        ['key', 'value'],
        stdCall(
          'greater_than',
          msg([field('left', ref('value')), field('right', literal(1))]),
        ),
      );
      expect(
        await evalPrint(
          stdCall(
            'map_filter',
            msg([
              field('map', mapOf({'a': 1, 'b': 2})),
              field('callback', cb),
            ]),
          ),
        ),
        '{b: 2}',
      );
    });
    test('map_is_empty / map_length', () async {
      expect(
        await evalPrint(
          stdCall('map_is_empty', msg([field('map', mapOf({}))])),
        ),
        'true',
      );
      expect(
        await evalPrint(
          stdCall(
            'map_length',
            msg([
              field('map', mapOf({'a': 1, 'b': 2})),
            ]),
          ),
        ),
        '2',
      );
    });
  });

  group('set ops', () {
    Map<String, dynamic> setOf(List<int> xs) => stdCall(
      'set_create',
      msg([
        field('elements', listLit([for (final x in xs) literal(x)])),
      ]),
    );

    test('set_add', () async {
      expect(
        await evalPrint(
          stdCall(
            'set_length',
            msg([
              field(
                'set',
                stdCall(
                  'set_add',
                  msg([
                    field('set', setOf([1, 2])),
                    field('value', literal(3)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        '3',
      );
    });
    test('set_remove', () async {
      expect(
        await evalPrint(
          stdCall(
            'set_length',
            msg([
              field(
                'set',
                stdCall(
                  'set_remove',
                  msg([
                    field('set', setOf([1, 2, 3])),
                    field('value', literal(2)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        '2',
      );
    });
    test('set_contains', () async {
      expect(
        await evalPrint(
          stdCall(
            'set_contains',
            msg([
              field('set', setOf([1, 2, 3])),
              field('value', literal(2)),
            ]),
          ),
        ),
        'true',
      );
    });
    test('set_union', () async {
      expect(
        await evalPrint(
          stdCall(
            'set_length',
            msg([
              field(
                'set',
                stdCall(
                  'set_union',
                  msg([
                    field('left', setOf([1, 2])),
                    field('right', setOf([2, 3])),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        '3',
      );
    });
    test('set_intersection', () async {
      expect(
        await evalPrint(
          stdCall(
            'set_length',
            msg([
              field(
                'set',
                stdCall(
                  'set_intersection',
                  msg([
                    field('left', setOf([1, 2, 3])),
                    field('right', setOf([2, 3, 4])),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        '2',
      );
    });
    test('set_difference', () async {
      expect(
        await evalPrint(
          stdCall(
            'set_length',
            msg([
              field(
                'set',
                stdCall(
                  'set_difference',
                  msg([
                    field('left', setOf([1, 2, 3])),
                    field('right', setOf([2])),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        '2',
      );
    });
    test('set_is_empty', () async {
      expect(
        await evalPrint(
          stdCall('set_is_empty', msg([field('set', setOf([]))])),
        ),
        'true',
      );
    });
    test('set_to_list', () async {
      expect(
        await evalPrint(
          stdCall(
            'set_to_list',
            msg([
              field('set', setOf([1, 2, 3])),
            ]),
          ),
        ),
        '[1, 2, 3]',
      );
    });
  });

  group('string ops', () {
    test(
      'string_length',
      () async => expect(
        await evalPrint(stdCall('string_length', unMsg('hello'))),
        '5',
      ),
    );
    test(
      'string_is_empty true',
      () async => expect(
        await evalPrint(stdCall('string_is_empty', unMsg(''))),
        'true',
      ),
    );
    test('string_is_empty list receiver', () async {
      expect(
        await evalPrint(
          stdCall('string_is_empty', msg([field('value', listLit([]))])),
        ),
        'true',
      );
    });
    test(
      'string_concat',
      () async => expect(
        await evalPrintStr(
          stdCall(
            'string_concat',
            msg([
              field('left', literal('foo')),
              field('right', literal('bar')),
            ]),
          ),
        ),
        'foobar',
      ),
    );
    test(
      'string_contains',
      () async => expect(
        await evalPrint(
          stdCall(
            'string_contains',
            msg([
              field('left', literal('hello')),
              field('right', literal('ell')),
            ]),
          ),
        ),
        'true',
      ),
    );
    test(
      'string_starts_with',
      () async => expect(
        await evalPrint(
          stdCall(
            'string_starts_with',
            msg([
              field('left', literal('hello')),
              field('right', literal('he')),
            ]),
          ),
        ),
        'true',
      ),
    );
    test(
      'string_ends_with',
      () async => expect(
        await evalPrint(
          stdCall(
            'string_ends_with',
            msg([
              field('left', literal('hello')),
              field('right', literal('lo')),
            ]),
          ),
        ),
        'true',
      ),
    );
    test(
      'string_index_of',
      () async => expect(
        await evalPrint(
          stdCall(
            'string_index_of',
            msg([
              field('left', literal('hello')),
              field('right', literal('l')),
            ]),
          ),
        ),
        '2',
      ),
    );
    test(
      'string_last_index_of',
      () async => expect(
        await evalPrint(
          stdCall(
            'string_last_index_of',
            msg([
              field('left', literal('hello')),
              field('right', literal('l')),
            ]),
          ),
        ),
        '3',
      ),
    );
    test('string_substring start+end', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'string_substring',
            msg([
              field('value', literal('hello')),
              field('start', literal(1)),
              field('end', literal(3)),
            ]),
          ),
        ),
        'el',
      );
    });
    test('string_substring start only', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'string_substring',
            msg([field('value', literal('hello')), field('start', literal(2))]),
          ),
        ),
        'llo',
      );
    });
    test('string_char_at', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'string_char_at',
            msg([
              field('target', literal('hello')),
              field('index', literal(1)),
            ]),
          ),
        ),
        'e',
      );
    });
    test('string_char_code_at', () async {
      expect(
        await evalPrint(
          stdCall(
            'string_char_code_at',
            msg([field('target', literal('A')), field('index', literal(0))]),
          ),
        ),
        '65',
      );
    });
    test('string_code_unit_at', () async {
      expect(
        await evalPrint(
          stdCall(
            'string_code_unit_at',
            msg([field('target', literal('B')), field('index', literal(0))]),
          ),
        ),
        '66',
      );
    });
    test('string_from_char_code', () async {
      expect(
        await evalPrintStr(stdCall('string_from_char_code', unMsg(65))),
        'A',
      );
    });
    test('string_to_upper / string_to_lower', () async {
      expect(
        await evalPrintStr(stdCall('string_to_upper', unMsg('abc'))),
        'ABC',
      );
      expect(
        await evalPrintStr(stdCall('string_to_lower', unMsg('ABC'))),
        'abc',
      );
    });
    test('string_trim / trim_start / trim_end', () async {
      expect(await evalPrintStr(stdCall('string_trim', unMsg('  x  '))), 'x');
      expect(
        await evalPrintStr(stdCall('string_trim_start', unMsg('  x  '))),
        'x  ',
      );
      expect(
        await evalPrintStr(stdCall('string_trim_end', unMsg('  x  '))),
        '  x',
      );
    });
    test('string_replace first', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'string_replace',
            msg([
              field('value', literal('aaa')),
              field('from', literal('a')),
              field('to', literal('b')),
            ]),
          ),
        ),
        'baa',
      );
    });
    test('string_replace_all', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'string_replace_all',
            msg([
              field('value', literal('aaa')),
              field('from', literal('a')),
              field('to', literal('b')),
            ]),
          ),
        ),
        'bbb',
      );
    });
    test('string_split', () async {
      expect(
        await evalPrint(
          stdCall(
            'string_split',
            msg([
              field('string', literal('a,b,c')),
              field('delimiter', literal(',')),
            ]),
          ),
        ),
        '[a, b, c]',
      );
    });
    test('string_repeat', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'string_repeat',
            msg([field('value', literal('ab')), field('count', literal(3))]),
          ),
        ),
        'ababab',
      );
    });
    test('string_pad_left / pad_right', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'string_pad_left',
            msg([
              field('value', literal('7')),
              field('width', literal(3)),
              field('padding', literal('0')),
            ]),
          ),
        ),
        '007',
      );
      expect(
        await evalPrintStr(
          stdCall(
            'string_pad_right',
            msg([
              field('value', literal('7')),
              field('width', literal(3)),
              field('padding', literal('0')),
            ]),
          ),
        ),
        '700',
      );
    });
  });

  group('regex', () {
    test('regex_match', () async {
      expect(
        await evalPrint(
          stdCall(
            'regex_match',
            msg([
              field('left', literal('abc123')),
              field('right', literal(r'\d+')),
            ]),
          ),
        ),
        'true',
      );
    });
    test('regex_find', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'regex_find',
            msg([
              field('left', literal('abc123')),
              field('right', literal(r'\d+')),
            ]),
          ),
        ),
        '123',
      );
    });
    test('regex_find_all', () async {
      expect(
        await evalPrint(
          stdCall(
            'regex_find_all',
            msg([
              field('left', literal('a1b2c3')),
              field('right', literal(r'\d')),
            ]),
          ),
        ),
        '[1, 2, 3]',
      );
    });
    test('regex_replace first', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'regex_replace',
            msg([
              field('value', literal('a1b2')),
              field('from', literal(r'\d')),
              field('to', literal('#')),
            ]),
          ),
        ),
        'a#b2',
      );
    });
    test('regex_replace_all', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'regex_replace_all',
            msg([
              field('value', literal('a1b2')),
              field('from', literal(r'\d')),
              field('to', literal('#')),
            ]),
          ),
        ),
        'a#b#',
      );
    });
  });

  group('math', () {
    test(
      'math_abs',
      () async => expect(await evalPrint(stdCall('math_abs', unMsg(-5))), '5'),
    );
    test(
      'math_floor',
      () async =>
          expect(await evalPrint(stdCall('math_floor', unMsg(3.7))), '3'),
    );
    test(
      'math_ceil',
      () async =>
          expect(await evalPrint(stdCall('math_ceil', unMsg(3.2))), '4'),
    );
    test(
      'math_trunc',
      () async =>
          expect(await evalPrint(stdCall('math_trunc', unMsg(3.9))), '3'),
    );
    test(
      'math_pow',
      () async =>
          expect(await evalPrint(stdCall('math_pow', binMsg(2, 10))), '1024.0'),
    );
    test(
      'math_log',
      () async => expect(await evalPrint(stdCall('math_log', unMsg(1))), '0.0'),
    );
    test(
      'math_log2',
      () async =>
          expect(await evalPrint(stdCall('math_log2', unMsg(8))), '3.0'),
    );
    test('math_log10', () async {
      // log10(1000) is 2.9999999999999996 in IEEE 754 — assert ~3 not exact.
      final v = double.parse(
        await evalPrint(stdCall('math_log10', unMsg(1000))),
      );
      expect(v, closeTo(3.0, 1e-9));
    });
    test(
      'math_exp',
      () async => expect(await evalPrint(stdCall('math_exp', unMsg(0))), '1.0'),
    );
    test(
      'math_sin',
      () async => expect(await evalPrint(stdCall('math_sin', unMsg(0))), '0.0'),
    );
    test(
      'math_cos',
      () async => expect(await evalPrint(stdCall('math_cos', unMsg(0))), '1.0'),
    );
    test(
      'math_tan',
      () async => expect(await evalPrint(stdCall('math_tan', unMsg(0))), '0.0'),
    );
    test(
      'math_asin',
      () async =>
          expect(await evalPrint(stdCall('math_asin', unMsg(0))), '0.0'),
    );
    test(
      'math_acos',
      () async =>
          expect(await evalPrint(stdCall('math_acos', unMsg(1))), '0.0'),
    );
    test(
      'math_atan',
      () async =>
          expect(await evalPrint(stdCall('math_atan', unMsg(0))), '0.0'),
    );
    test(
      'math_atan2',
      () async =>
          expect(await evalPrint(stdCall('math_atan2', binMsg(0, 1))), '0.0'),
    );
    test('math_min / math_max', () async {
      expect(await evalPrint(stdCall('math_min', binMsg(3, 5))), '3');
      expect(await evalPrint(stdCall('math_max', binMsg(3, 5))), '5');
    });
    test('math_clamp', () async {
      expect(
        await evalPrint(
          stdCall(
            'math_clamp',
            msg([
              field('value', literal(10)),
              field('min', literal(0)),
              field('max', literal(5)),
            ]),
          ),
        ),
        '5',
      );
    });
    test('math constants', () async {
      expect(await evalPrint(stdCall('math_pi', msg([]))), '3.141592653589793');
      expect(await evalPrint(stdCall('math_e', msg([]))), '2.718281828459045');
      expect(await evalPrint(stdCall('math_infinity', msg([]))), 'Infinity');
      expect(await evalPrint(stdCall('math_nan', msg([]))), 'NaN');
    });
    test('math_is_nan', () async {
      expect(
        await evalPrint(
          stdCall(
            'math_is_nan',
            msg([field('value', stdCall('math_nan', msg([])))]),
          ),
        ),
        'true',
      );
    });
    test('math_is_finite', () async {
      expect(await evalPrint(stdCall('math_is_finite', unMsg(1.0))), 'true');
    });
    test('math_is_infinite', () async {
      expect(
        await evalPrint(
          stdCall(
            'math_is_infinite',
            msg([field('value', stdCall('math_infinity', msg([])))]),
          ),
        ),
        'true',
      );
    });
    test(
      'math_sign',
      () async =>
          expect(await evalPrint(stdCall('math_sign', unMsg(-3))), '-1'),
    );
    test(
      'math_gcd',
      () async =>
          expect(await evalPrint(stdCall('math_gcd', binMsg(12, 18))), '6'),
    );
    test(
      'math_lcm',
      () async =>
          expect(await evalPrint(stdCall('math_lcm', binMsg(4, 6))), '12'),
    );
  });

  group('encoding & convert', () {
    test('json_encode', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'json_encode',
            msg([
              field('value', listLit([literal(1), literal(2)])),
            ]),
          ),
        ),
        '[1,2]',
      );
    });
    test('json_decode', () async {
      expect(
        await evalPrint(
          stdCall('json_decode', msg([field('value', literal('[1,2,3]'))])),
        ),
        '[1, 2, 3]',
      );
    });
    test('utf8 round-trip', () async {
      final encoded = stdCall(
        'utf8_encode',
        msg([field('value', literal('Hi'))]),
      );
      expect(
        await evalPrintStr(
          stdCall('utf8_decode', msg([field('value', encoded)])),
        ),
        'Hi',
      );
    });
    test('base64 round-trip', () async {
      final encoded = stdCall(
        'base64_encode',
        msg([
          field(
            'value',
            stdCall('utf8_encode', msg([field('value', literal('Hi'))])),
          ),
        ]),
      );
      final decodedBytes = stdCall(
        'base64_decode',
        msg([field('value', encoded)]),
      );
      expect(
        await evalPrintStr(
          stdCall('utf8_decode', msg([field('value', decodedBytes)])),
        ),
        'Hi',
      );
    });
  });

  group('datetime', () {
    test('now / now_micros / timestamp_ms produce ints', () async {
      expect(
        int.parse(await evalPrint(stdCall('now', msg([])))),
        greaterThan(0),
      );
      expect(
        int.parse(await evalPrint(stdCall('now_micros', msg([])))),
        greaterThan(0),
      );
      expect(
        int.parse(await evalPrint(stdCall('timestamp_ms', msg([])))),
        greaterThan(0),
      );
    });
    test('format_timestamp + parse_timestamp round-trip', () async {
      // 2021-01-01T00:00:00Z = 1609459200000 ms
      final formatted = await evalPrintStr(
        stdCall(
          'format_timestamp',
          msg([field('timestamp_ms', literal(1609459200000))]),
        ),
      );
      expect(formatted.startsWith('2021-01-01'), isTrue);
      final parsed = await evalPrint(
        stdCall('parse_timestamp', msg([field('value', literal(formatted))])),
      );
      expect(parsed, '1609459200000');
    });
    test('duration_add / duration_subtract', () async {
      expect(
        await evalPrint(stdCall('duration_add', binMsg(1000, 500))),
        '1500',
      );
      expect(
        await evalPrint(stdCall('duration_subtract', binMsg(1000, 500))),
        '500',
      );
    });
    test('date components return ints', () async {
      for (final f in ['year', 'month', 'day', 'hour', 'minute', 'second']) {
        final v = int.parse(await evalPrint(stdCall(f, msg([]))));
        expect(v, greaterThanOrEqualTo(0));
      }
    });
  });

  group('io & concurrency', () {
    test('random_int within range', () async {
      final v = int.parse(
        await evalPrint(
          stdCall(
            'random_int',
            msg([field('min', literal(5)), field('max', literal(5))]),
          ),
        ),
      );
      expect(v, 5);
    });
    test('random_double in [0,1)', () async {
      final v = double.parse(
        await evalPrint(stdCall('random_double', msg([]))),
      );
      expect(v, inInclusiveRange(0.0, 1.0));
    });
    test('sleep_ms zero is no-op', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('sleep_ms', literal(0))),
            stmt(printExpr(literal('done'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['done']);
    });
    test('mutex_create returns id and lock/unlock no-op', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('m', stdCall('mutex_create', msg([]))),
            stmt(stdCall('mutex_lock', ref('m'))),
            stmt(stdCall('mutex_unlock', ref('m'))),
            stmt(printToString(ref('m'))),
          ]),
        ],
      );
      final lines = await runAndCapture(program);
      expect(int.parse(lines.single), greaterThanOrEqualTo(0));
    });
    test('scoped_lock runs body', () async {
      final body = lambdaExpr(literal(42));
      expect(
        await evalPrint(stdCall('scoped_lock', msg([field('body', body)]))),
        '42',
      );
    });
    test('atomic_load / atomic_store', () async {
      expect(await evalPrint(stdCall('atomic_load', unMsg(9))), '9');
    });
    test('atomic_compare_exchange returns true', () async {
      expect(
        await evalPrint(stdCall('atomic_compare_exchange', msg([]))),
        'true',
      );
    });
    test('thread_join no-op', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('thread_join', msg([]))),
            stmt(printExpr(literal('ok'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['ok']);
    });
  });

  group('misc expressions', () {
    test('paren returns inner value', () async {
      expect(
        await evalPrint(stdCall('paren', msg([field('value', literal(7))]))),
        '7',
      );
    });
    test('symbol prints like native Dart Symbol("name") (#65)', () async {
      // Dart's print(#foo) prints `Symbol("foo")`, not the bare name.
      expect(
        await evalPrintStr(
          stdCall('symbol', msg([field('value', literal('foo'))])),
        ),
        'Symbol("foo")',
      );
    });
    test('type_literal returns type name', () async {
      expect(
        await evalPrintStr(
          stdCall('type_literal', msg([field('type', literal('int'))])),
        ),
        'int',
      );
    });
  });

  group('builtin class static methods', () {
    test('List.generate', () async {
      final gen = lambdaExpr(
        stdCall(
          'multiply',
          msg([field('left', ref('input')), field('right', literal(10))]),
        ),
      );
      expect(
        await evalPrint(
          call(
            'generate',
            input: msg([
              field('self', ref('List')),
              field('arg0', literal(3)),
              field('arg1', gen),
            ]),
          ),
        ),
        '[0, 10, 20]',
      );
    });
    test('List.filled', () async {
      expect(
        await evalPrint(
          call(
            'filled',
            input: msg([
              field('self', ref('List')),
              field('arg0', literal(3)),
              field('arg1', literal('x')),
            ]),
          ),
        ),
        '[x, x, x]',
      );
    });
    test('List.of', () async {
      expect(
        await evalPrint(
          call(
            'of',
            input: msg([
              field('self', ref('List')),
              field('arg0', listLit([literal(1), literal(2)])),
            ]),
          ),
        ),
        '[1, 2]',
      );
    });
    test('List.from', () async {
      expect(
        await evalPrint(
          call(
            'from',
            input: msg([
              field('self', ref('List')),
              field('arg0', listLit([literal(3), literal(4)])),
            ]),
          ),
        ),
        '[3, 4]',
      );
    });
    test('Map.fromEntries', () async {
      final entries = listLit([
        msg([field('key', literal('a')), field('value', literal(1))]),
      ]);
      expect(
        await evalPrint(
          call(
            'fromEntries',
            input: msg([field('self', ref('Map')), field('arg0', entries)]),
          ),
        ),
        '{a: 1}',
      );
    });
  });

  group('index access', () {
    test('index into a list', () async {
      expect(
        await evalPrint(
          stdCall(
            'index',
            msg([
              field('target', listLit([literal(10), literal(20)])),
              field('index', literal(1)),
            ]),
          ),
        ),
        '20',
      );
    });
    test('index into a map', () async {
      final m = stdCall(
        'map_create',
        msg([
          field(
            'entries',
            listLit([
              msg([field('key', literal('k')), field('value', literal(42))]),
            ]),
          ),
        ]),
      );
      expect(
        await evalPrint(
          stdCall(
            'index',
            msg([field('target', m), field('index', literal('k'))]),
          ),
        ),
        '42',
      );
    });
    test('index into a string', () async {
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
  });

  group('map_create variants', () {
    test('map_create with single entry (not a list)', () async {
      final single = stdCall(
        'map_create',
        msg([
          field(
            'entry',
            msg([field('key', literal('x')), field('value', literal(9))]),
          ),
        ]),
      );
      expect(await evalPrint(single), '{x: 9}');
    });
    test('map_create with no args yields empty map', () async {
      expect(await evalPrint(stdCall('map_create', msg([]))), '{}');
    });
  });

  group('switch_expr (eager dispatch)', () {
    test('matches a value case', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'switch_expr',
                  msg([
                    field('subject', literal(2)),
                    field(
                      'cases',
                      listLit([
                        msg([
                          field('pattern_expr', literal(1)),
                          field('body', literal('one')),
                        ]),
                        msg([
                          field('pattern_expr', literal(2)),
                          field('body', literal('two')),
                        ]),
                        msg([
                          field('is_default', literal(true)),
                          field('body', literal('other')),
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
      expect((await runAndCapture(program)).single, 'two');
    });
    test('falls through to default', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'switch_expr',
                  msg([
                    field('subject', literal(99)),
                    field(
                      'cases',
                      listLit([
                        msg([
                          field('pattern_expr', literal(1)),
                          field('body', literal('one')),
                        ]),
                        msg([
                          field('is_default', literal(true)),
                          field('body', literal('def')),
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
      expect((await runAndCapture(program)).single, 'def');
    });
  });

  group('concurrency with body', () {
    test('thread_spawn runs body', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'thread_spawn',
                msg([
                  field('body', lambdaExpr(printExpr(literal('in-thread')))),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['in-thread']);
    });
    test('atomic_store returns null (no-op)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('atomic_store', msg([field('value', literal(1))]))),
            stmt(printExpr(literal('ok'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['ok']);
    });
  });

  group('list comprehensions & spread', () {
    Map<String, dynamic> collectionFor(
      String varName,
      Map<String, dynamic> iterable,
      Map<String, dynamic> body,
    ) => stdCall(
      'collection_for',
      msg([
        field('variable', literal(varName)),
        field('iterable', iterable),
        field('body', body),
      ]),
    );

    test('for-each comprehension splices items', () async {
      final comp = collectionFor(
        'x',
        listLit([literal(1), literal(2), literal(3)]),
        stdCall(
          'multiply',
          msg([field('left', ref('x')), field('right', literal(10))]),
        ),
      );
      expect(await evalPrint(listLit([comp])), '[10, 20, 30]');
    });
    test('C-style comprehension', () async {
      final comp = stdCall(
        'collection_for',
        msg([
          field('init', literal('var i = 0')),
          field(
            'condition',
            stdCall(
              'less_than',
              msg([field('left', ref('i')), field('right', literal(3))]),
            ),
          ),
          field(
            'update',
            stdCall('pre_increment', msg([field('value', ref('i'))])),
          ),
          field('body', ref('i')),
        ]),
      );
      expect(await evalPrint(listLit([comp])), '[0, 1, 2]');
    });
    test('collection_if then branch', () async {
      final comp = stdCall(
        'collection_if',
        msg([field('condition', literal(true)), field('then', literal(99))]),
      );
      expect(await evalPrint(listLit([literal(1), comp])), '[1, 99]');
    });
    test('collection_if else branch', () async {
      final comp = stdCall(
        'collection_if',
        msg([
          field('condition', literal(false)),
          field('then', literal(99)),
          field('else', literal(7)),
        ]),
      );
      expect(await evalPrint(listLit([comp])), '[7]');
    });
    test('spread splices a list', () async {
      final sp = stdCall(
        'spread',
        msg([
          field('value', listLit([literal(2), literal(3)])),
        ]),
      );
      expect(
        await evalPrint(listLit([literal(1), sp, literal(4)])),
        '[1, 2, 3, 4]',
      );
    });
    test('null_spread with null contributes nothing', () async {
      final sp = stdCall(
        'null_spread',
        msg([
          field('value', {'literal': {}}),
        ]),
      );
      expect(await evalPrint(listLit([literal(1), sp])), '[1]');
    });
  });

  group('map comprehensions & spread', () {
    Map<String, dynamic> entry(
      Map<String, dynamic> k,
      Map<String, dynamic> v,
    ) => msg([field('key', k), field('value', v)]);

    test('map for-each comprehension', () async {
      final comp = stdCall(
        'collection_for',
        msg([
          field('variable', literal('x')),
          field('iterable', listLit([literal(1), literal(2)])),
          field(
            'body',
            entry(
              stdCall('to_string', msg([field('value', ref('x'))])),
              stdCall(
                'multiply',
                msg([field('left', ref('x')), field('right', literal(10))]),
              ),
            ),
          ),
        ]),
      );
      final mapCreate = call(
        'map_create',
        module: 'std',
        input: msg([field('element', comp)]),
      );
      expect(await evalPrint(mapCreate), '{1: 10, 2: 20}');
    });
    test('map collection_if', () async {
      final comp = stdCall(
        'collection_if',
        msg([
          field('condition', literal(true)),
          field('then', entry(literal('a'), literal(1))),
        ]),
      );
      final mapCreate = call(
        'map_create',
        module: 'std',
        input: msg([field('element', comp)]),
      );
      expect(await evalPrint(mapCreate), '{a: 1}');
    });
    test('map spread merges entries', () async {
      final base = stdCall(
        'map_create',
        msg([
          field('entries', listLit([entry(literal('a'), literal(1))])),
        ]),
      );
      final sp = stdCall('spread', msg([field('value', base)]));
      final mapCreate = call(
        'map_create',
        module: 'std',
        input: msg([
          field('element', entry(literal('b'), literal(2))),
          field('element', sp),
        ]),
      );
      // entries are b then spread-a; insertion order: b, a.
      final result = await evalPrint(mapCreate);
      expect(result.contains('a: 1'), isTrue);
      expect(result.contains('b: 2'), isTrue);
    });
  });

  group('switch_expr pattern matching', () {
    // String patterns (go through _matchStringPattern).
    Future<String> switchStr(
      Object subject,
      List<(Object?, String)> cases,
    ) async {
      final caseMsgs = <Map<String, dynamic>>[];
      for (final (pat, body) in cases) {
        if (pat == null) {
          caseMsgs.add(
            msg([
              field('is_default', literal(true)),
              field('body', literal(body)),
            ]),
          );
        } else {
          caseMsgs.add(
            msg([
              field('pattern', literal(pat as String)),
              field('body', literal(body)),
            ]),
          );
        }
      }
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'switch_expr',
                  msg([
                    field('subject', literal(subject)),
                    field('cases', listLit(caseMsgs)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      return (await runAndCapture(program)).single;
    }

    test('string relational pattern "> 5"', () async {
      expect(await switchStr(10, [('> 5', 'big'), (null, 'small')]), 'big');
      expect(await switchStr(3, [('> 5', 'big'), (null, 'small')]), 'small');
    });
    test('string const pattern "true"', () async {
      expect(await switchStr(true, [('true', 'yes'), (null, 'no')]), 'yes');
    });
    test('string type pattern "int"', () async {
      expect(
        await switchStr(7, [('int', 'an-int'), (null, 'other')]),
        'an-int',
      );
    });
    test('string direct value equality', () async {
      expect(
        await switchStr('hi', [('hi', 'matched'), (null, 'no')]),
        'matched',
      );
    });

    // Structured patterns (go through _matchStructuredPattern via pattern_expr).
    Map<String, dynamic> patternMsg(
      Map<String, dynamic> kind,
      List<Map<String, dynamic>> extra,
    ) => msg([field('__pattern_kind__', kind), ...extra]);

    Future<String> switchPat(
      Map<String, dynamic> subject,
      Map<String, dynamic> patternExpr,
      String body,
    ) async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'switch_expr',
                  msg([
                    field('subject', subject),
                    field(
                      'cases',
                      listLit([
                        msg([
                          field('pattern_expr', patternExpr),
                          field('body', literal(body)),
                        ]),
                        msg([
                          field('is_default', literal(true)),
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
      return (await runAndCapture(program)).single;
    }

    test('structured type_test pattern', () async {
      final pat = patternMsg(literal('type_test'), [
        field('type', literal('int')),
        field('name', literal('x')),
      ]);
      expect(await switchPat(literal(5), pat, 'int-match'), 'int-match');
    });
    test('structured const pattern', () async {
      final pat = patternMsg(literal('const'), [field('value', literal(42))]);
      expect(await switchPat(literal(42), pat, 'is-42'), 'is-42');
      expect(await switchPat(literal(1), pat, 'is-42'), 'default');
    });
    test('structured relational pattern', () async {
      final pat = patternMsg(literal('relational'), [
        field('operator', literal('>=')),
        field('operand', literal(10)),
      ]);
      expect(await switchPat(literal(20), pat, 'ge-10'), 'ge-10');
      expect(await switchPat(literal(5), pat, 'ge-10'), 'default');
    });
    test('structured wildcard pattern', () async {
      final pat = patternMsg(literal('wildcard'), []);
      expect(await switchPat(literal(99), pat, 'any'), 'any');
    });
    test('structured var pattern with type', () async {
      final pat = patternMsg(literal('var'), [
        field('type', literal('int')),
        field('name', literal('n')),
      ]);
      expect(await switchPat(literal(3), pat, 'bound'), 'bound');
    });
    test('structured logical_or pattern', () async {
      final pat = patternMsg(literal('logical_or'), [
        field(
          'left',
          patternMsg(literal('const'), [field('value', literal(1))]),
        ),
        field(
          'right',
          patternMsg(literal('const'), [field('value', literal(2))]),
        ),
      ]);
      expect(await switchPat(literal(2), pat, 'one-or-two'), 'one-or-two');
    });
    test('structured list pattern', () async {
      final pat = patternMsg(literal('list'), [
        field(
          'elements',
          listLit([
            patternMsg(literal('const'), [field('value', literal(1))]),
            patternMsg(literal('const'), [field('value', literal(2))]),
          ]),
        ),
      ]);
      expect(
        await switchPat(listLit([literal(1), literal(2)]), pat, 'list-match'),
        'list-match',
      );
      expect(
        await switchPat(listLit([literal(1), literal(9)]), pat, 'list-match'),
        'default',
      );
    });
  });
}

/// Builds a lambda whose parameter names are explicitly captured so callbacks
/// that receive a record of positional args (e.g. reduce/sort comparators,
/// map_map) can bind them by name.
Map<String, dynamic> _namedLambda(
  List<String> params,
  Map<String, dynamic> body,
) {
  return {
    'lambda': {
      'name': '',
      'inputType': 'dynamic',
      'body': body,
      'metadata': {
        'params': [
          for (final p in params) {'name': p, 'type': 'dynamic'},
        ],
      },
    },
  };
}
