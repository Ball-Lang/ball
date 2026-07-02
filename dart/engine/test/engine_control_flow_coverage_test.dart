// Coverage-focused tests for engine_control_flow.dart — method dispatch on
// built-in instance types (List/Set/String/num/StringBuffer) and the
// control-flow base functions (if/for/while/for_in/do_while/switch/try,
// break/continue/return, assign + compound assign, increment/decrement).
//
// Built-in instance methods are invoked the way the encoder emits them:
//   call('<method>', input: msg([field('self', objExpr), field('arg0', ...)]))
// with an EMPTY module. A `self` field on the input triggers
// `_dispatchBuiltinInstanceMethod`.
import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

Future<List<String>> runAndCapture(Program program) async {
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add);
  await engine.run();
  return lines;
}

const _stdFnNames = <String>[
  'print',
  'add',
  'subtract',
  'multiply',
  'divide',
  'divide_double',
  'modulo',
  'negate',
  'less_than',
  'greater_than',
  'lte',
  'gte',
  'equals',
  'not_equals',
  'and',
  'or',
  'not',
  'to_string',
  'if',
  'for',
  'while',
  'for_in',
  'for_each',
  'do_while',
  'switch',
  'switch_expr',
  'try',
  'break',
  'continue',
  'return',
  'assign',
  'string_interpolation',
  'pre_increment',
  'pre_decrement',
  'post_increment',
  'post_decrement',
  'index',
  'ternary',
  'labeled',
  'label',
  'goto',
  'cascade',
  'null_aware_cascade',
  'throw',
  'list_get',
  'map_create',
  'set_create',
  'string_buffer_create',
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

Map<String, dynamic> namedLambda(
  List<String> params,
  Map<String, dynamic> body,
) => {
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

/// Invoke a built-in instance method: `self.method(args...)`.
Map<String, dynamic> method(
  Map<String, dynamic> self,
  String name, {
  Map<String, dynamic>? arg0,
  Map<String, dynamic>? arg1,
}) {
  final fields = <Map<String, dynamic>>[field('self', self)];
  if (arg0 != null) fields.add(field('arg0', arg0));
  if (arg1 != null) fields.add(field('arg1', arg1));
  return call(name, input: msg(fields));
}

/// Build a block expression from statements.
Map<String, dynamic> block(List<Map<String, dynamic>> statements) => {
  'block': {'statements': statements},
};

Future<String> evalPrint(Map<String, dynamic> expr) async {
  final program = buildProgram(
    functions: [
      mainFn([stmt(printToString(expr))]),
    ],
  );
  return (await runAndCapture(program)).single;
}

Future<String> evalPrintStr(Map<String, dynamic> expr) async {
  final program = buildProgram(
    functions: [
      mainFn([stmt(printExpr(expr))]),
    ],
  );
  return (await runAndCapture(program)).single;
}

Map<String, dynamic> ints(List<int> xs) =>
    listLit([for (final x in xs) literal(x)]);

Map<String, dynamic> fieldAcc(Map<String, dynamic> object, String fieldName) =>
    {
      'fieldAccess': {'object': object, 'field': fieldName},
    };

void main() {
  group('List instance methods', () {
    test('add mutates the list', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([1, 2])),
            stmt(method(ref('xs'), 'add', arg0: literal(3))),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '[1, 2, 3]');
    });

    test('removeLast', () async {
      expect(await evalPrint(method(ints([1, 2, 3]), 'removeLast')), '3');
    });
    test('removeAt', () async {
      expect(
        await evalPrint(method(ints([1, 2, 3]), 'removeAt', arg0: literal(1))),
        '2',
      );
    });
    test('insert', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([1, 3])),
            stmt(
              method(ref('xs'), 'insert', arg0: literal(1), arg1: literal(2)),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '[1, 2, 3]');
    });
    test('clear', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([1, 2, 3])),
            stmt(method(ref('xs'), 'clear')),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '[]');
    });
    test('contains', () async {
      expect(
        await evalPrint(method(ints([1, 2, 3]), 'contains', arg0: literal(2))),
        'true',
      );
    });
    test('indexOf', () async {
      expect(
        await evalPrint(method(ints([1, 2, 3]), 'indexOf', arg0: literal(3))),
        '2',
      );
    });
    test('join with separator', () async {
      expect(
        await evalPrintStr(method(ints([1, 2, 3]), 'join', arg0: literal('-'))),
        '1-2-3',
      );
    });
    test('join default separator', () async {
      expect(await evalPrintStr(method(ints([1, 2]), 'join')), '1, 2');
    });
    test('sublist start+end', () async {
      expect(
        await evalPrint(
          method(
            ints([1, 2, 3, 4]),
            'sublist',
            arg0: literal(1),
            arg1: literal(3),
          ),
        ),
        '[2, 3]',
      );
    });
    test('sublist start only', () async {
      expect(
        await evalPrint(
          method(ints([1, 2, 3, 4]), 'sublist', arg0: literal(2)),
        ),
        '[3, 4]',
      );
    });
    test('reversed', () async {
      expect(await evalPrint(method(ints([1, 2, 3]), 'reversed')), '[3, 2, 1]');
    });
    test('sort natural', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([3, 1, 2])),
            stmt(method(ref('xs'), 'sort')),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '[1, 2, 3]');
    });
    test('sort with comparator', () async {
      final cmp = namedLambda(
        ['a', 'b'],
        stdCall(
          'subtract',
          msg([field('left', ref('b')), field('right', ref('a'))]),
        ),
      );
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([1, 3, 2])),
            stmt(method(ref('xs'), 'sort', arg0: cmp)),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '[3, 2, 1]');
    });
    test('map', () async {
      final cb = lambdaExpr(
        stdCall(
          'multiply',
          msg([field('left', ref('input')), field('right', literal(2))]),
        ),
      );
      expect(
        await evalPrint(method(ints([1, 2, 3]), 'map', arg0: cb)),
        '[2, 4, 6]',
      );
    });
    test('where / filter', () async {
      final cb = lambdaExpr(
        stdCall(
          'greater_than',
          msg([field('left', ref('input')), field('right', literal(1))]),
        ),
      );
      expect(
        await evalPrint(method(ints([1, 2, 3]), 'where', arg0: cb)),
        '[2, 3]',
      );
      expect(
        await evalPrint(method(ints([1, 2, 3]), 'filter', arg0: cb)),
        '[2, 3]',
      );
    });
    test('forEach', () async {
      final cb = lambdaExpr(printToString(ref('input')));
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(method(ints([4, 5]), 'forEach', arg0: cb)),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['4', '5']);
    });
    test('any / every', () async {
      final cb = lambdaExpr(
        stdCall(
          'greater_than',
          msg([field('left', ref('input')), field('right', literal(2))]),
        ),
      );
      expect(await evalPrint(method(ints([1, 2, 3]), 'any', arg0: cb)), 'true');
      expect(await evalPrint(method(ints([3, 4]), 'every', arg0: cb)), 'true');
    });
    test('reduce', () async {
      final cb = namedLambda(
        ['a', 'b'],
        stdCall(
          'add',
          msg([field('left', ref('a')), field('right', ref('b'))]),
        ),
      );
      expect(
        await evalPrint(method(ints([1, 2, 3, 4]), 'reduce', arg0: cb)),
        '10',
      );
    });
    test('fold', () async {
      final cb = namedLambda(
        ['arg0', 'arg1'],
        stdCall(
          'add',
          msg([field('left', ref('arg0')), field('right', ref('arg1'))]),
        ),
      );
      expect(
        await evalPrint(
          method(ints([1, 2, 3]), 'fold', arg0: literal(100), arg1: cb),
        ),
        '106',
      );
    });
    test('toList', () async {
      expect(await evalPrint(method(ints([1, 2]), 'toList')), '[1, 2]');
    });
    test('toSet', () async {
      expect(await evalPrint(method(ints([1, 2, 2, 3]), 'toSet')), '[1, 2, 3]');
    });
    test('toString', () async {
      expect(await evalPrintStr(method(ints([1, 2]), 'toString')), '[1, 2]');
    });
    test('expand', () async {
      final cb = lambdaExpr(listLit([ref('input'), ref('input')]));
      expect(
        await evalPrint(method(ints([1, 2]), 'expand', arg0: cb)),
        '[1, 1, 2, 2]',
      );
    });
    test('take / skip', () async {
      expect(
        await evalPrint(method(ints([1, 2, 3, 4]), 'take', arg0: literal(2))),
        '[1, 2]',
      );
      expect(
        await evalPrint(method(ints([1, 2, 3, 4]), 'skip', arg0: literal(2))),
        '[3, 4]',
      );
    });
    test('followedBy', () async {
      expect(
        await evalPrint(method(ints([1, 2]), 'followedBy', arg0: ints([3, 4]))),
        '[1, 2, 3, 4]',
      );
    });
    test('union (list as set)', () async {
      expect(
        await evalPrint(method(ints([1, 2]), 'union', arg0: ints([2, 3]))),
        '[1, 2, 3]',
      );
    });
    test('intersection (list as set)', () async {
      expect(
        await evalPrint(
          method(ints([1, 2, 3]), 'intersection', arg0: ints([2, 3, 4])),
        ),
        '[2, 3]',
      );
    });
    test('difference (list as set)', () async {
      expect(
        await evalPrint(method(ints([1, 2, 3]), 'difference', arg0: ints([2]))),
        '[1, 3]',
      );
    });
    test('addAll (set semantics, dedupes)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([1, 2])),
            stmt(method(ref('xs'), 'addAll', arg0: ints([2, 3]))),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '[1, 2, 3]');
    });
  });

  group('String instance methods', () {
    Map<String, dynamic> s(String v) => literal(v);
    test(
      'contains',
      () async => expect(
        await evalPrint(method(s('hello'), 'contains', arg0: s('ell'))),
        'true',
      ),
    );
    test(
      'substring start+end',
      () async => expect(
        await evalPrintStr(
          method(s('hello'), 'substring', arg0: literal(1), arg1: literal(3)),
        ),
        'el',
      ),
    );
    test(
      'substring start only',
      () async => expect(
        await evalPrintStr(method(s('hello'), 'substring', arg0: literal(2))),
        'llo',
      ),
    );
    test(
      'indexOf',
      () async => expect(
        await evalPrint(method(s('hello'), 'indexOf', arg0: s('l'))),
        '2',
      ),
    );
    test(
      'split',
      () async => expect(
        await evalPrint(method(s('a,b,c'), 'split', arg0: s(','))),
        '[a, b, c]',
      ),
    );
    test(
      'trim',
      () async => expect(await evalPrintStr(method(s('  x  '), 'trim')), 'x'),
    );
    test('toUpperCase / toLowerCase', () async {
      expect(await evalPrintStr(method(s('abc'), 'toUpperCase')), 'ABC');
      expect(await evalPrintStr(method(s('ABC'), 'toLowerCase')), 'abc');
    });
    test(
      'replaceAll',
      () async => expect(
        await evalPrintStr(
          method(s('aaa'), 'replaceAll', arg0: s('a'), arg1: s('b')),
        ),
        'bbb',
      ),
    );
    test('startsWith / endsWith', () async {
      expect(
        await evalPrint(method(s('hello'), 'startsWith', arg0: s('he'))),
        'true',
      );
      expect(
        await evalPrint(method(s('hello'), 'endsWith', arg0: s('lo'))),
        'true',
      );
    });
    test('padLeft / padRight', () async {
      expect(
        await evalPrintStr(
          method(s('7'), 'padLeft', arg0: literal(3), arg1: s('0')),
        ),
        '007',
      );
      expect(
        await evalPrintStr(
          method(s('7'), 'padRight', arg0: literal(3), arg1: s('0')),
        ),
        '700',
      );
    });
    test(
      'toString',
      () async => expect(await evalPrintStr(method(s('hi'), 'toString')), 'hi'),
    );
    test(
      'codeUnitAt',
      () async => expect(
        await evalPrint(method(s('A'), 'codeUnitAt', arg0: literal(0))),
        '65',
      ),
    );
    test(
      'compareTo',
      () async => expect(
        await evalPrint(method(s('a'), 'compareTo', arg0: s('b'))),
        '-1',
      ),
    );
  });

  group('num instance methods', () {
    // A computed double — `divide_double` returns a raw Dart double, which the
    // num method-dispatch branch handles. (A bare double literal evaluates to
    // BallDouble, which `_dispatchBuiltinInstanceMethod` does NOT unwrap to
    // num — see the reported latent inconsistency — so num methods on a double
    // literal fall through; the encoder routes literal `.round()`/`.toInt()`
    // through std math_* ops instead, so that path is not encoder-reachable.)
    Map<String, dynamic> dbl(double whole, double part) => stdCall(
      'divide_double',
      msg([field('left', literal(whole)), field('right', literal(part))]),
    );
    test(
      'toDouble (int receiver)',
      () async =>
          expect(await evalPrint(method(literal(3), 'toDouble')), '3.0'),
    );
    test(
      'toInt (computed double)',
      () async =>
          expect(await evalPrint(method(dbl(78.0, 10.0), 'toInt')), '7'),
    );
    test(
      'toString (int receiver)',
      () async =>
          expect(await evalPrintStr(method(literal(42), 'toString')), '42'),
    );
    test('toStringAsFixed (computed double)', () async {
      // 3.14159.../... — divide to get a non-integral double, then format.
      expect(
        await evalPrintStr(
          method(dbl(314159.0, 100000.0), 'toStringAsFixed', arg0: literal(2)),
        ),
        '3.14',
      );
    });
    test(
      'abs (int receiver)',
      () async => expect(await evalPrint(method(literal(-5), 'abs')), '5'),
    );
    test(
      'round (computed double)',
      () async =>
          expect(await evalPrint(method(dbl(36.0, 10.0), 'round')), '4'),
    );
    test(
      'floor (computed double)',
      () async =>
          expect(await evalPrint(method(dbl(36.0, 10.0), 'floor')), '3'),
    );
    test(
      'ceil (computed double)',
      () async => expect(await evalPrint(method(dbl(32.0, 10.0), 'ceil')), '4'),
    );
    test(
      'compareTo (int receiver)',
      () async => expect(
        await evalPrint(method(literal(2), 'compareTo', arg0: literal(5))),
        '-1',
      ),
    );
    test(
      'clamp (int receiver)',
      () async => expect(
        await evalPrint(
          method(literal(10), 'clamp', arg0: literal(0), arg1: literal(5)),
        ),
        '5',
      ),
    );
    test(
      'truncate (computed double)',
      () async =>
          expect(await evalPrint(method(dbl(39.0, 10.0), 'truncate')), '3'),
    );
    test(
      'remainder (int receiver)',
      () async => expect(
        await evalPrint(method(literal(10), 'remainder', arg0: literal(3))),
        '1',
      ),
    );
  });

  group('Set instance methods', () {
    Map<String, dynamic> setOf(List<int> xs) =>
        stdCall('set_create', msg([field('elements', ints(xs))]));
    test('union', () async {
      expect(await evalPrint(method(setOf([1, 2]), 'length')), '2');
    });
    test('add', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('s', setOf([1, 2])),
            stmt(method(ref('s'), 'add', arg0: literal(3))),
            stmt(printToString(method(ref('s'), 'length'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '3');
    });
    test('remove', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('s', setOf([1, 2, 3])),
            stmt(method(ref('s'), 'remove', arg0: literal(2))),
            stmt(printToString(method(ref('s'), 'length'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '2');
    });
    test('contains', () async {
      expect(
        await evalPrint(method(setOf([1, 2, 3]), 'contains', arg0: literal(2))),
        'true',
      );
    });
    test('isEmpty / isNotEmpty', () async {
      expect(await evalPrint(method(setOf([]), 'isEmpty')), 'true');
      expect(await evalPrint(method(setOf([1]), 'isNotEmpty')), 'true');
    });
    test('toList', () async {
      expect(await evalPrint(method(setOf([1, 2, 3]), 'toList')), '[1, 2, 3]');
    });
    test('map', () async {
      final cb = lambdaExpr(
        stdCall(
          'multiply',
          msg([field('left', ref('input')), field('right', literal(2))]),
        ),
      );
      expect(await evalPrint(method(setOf([1, 2]), 'map', arg0: cb)), '[2, 4]');
    });
    test('where', () async {
      final cb = lambdaExpr(
        stdCall(
          'greater_than',
          msg([field('left', ref('input')), field('right', literal(1))]),
        ),
      );
      // `Set.where` returns a lazy `Iterable`; the engine materializes it as a
      // list (same as `Set.map`), so it renders `[2, 3]`, not `{2, 3}`.
      expect(
        await evalPrint(method(setOf([1, 2, 3]), 'where', arg0: cb)),
        '[2, 3]',
      );
    });
    test('union returns combined set', () async {
      final union = method(setOf([1, 2]), 'union', arg0: setOf([2, 3]));
      expect(await evalPrint(method(union, 'length')), '3');
    });
    test('intersection', () async {
      final r = method(
        setOf([1, 2, 3]),
        'intersection',
        arg0: setOf([2, 3, 4]),
      );
      expect(await evalPrint(method(r, 'length')), '2');
    });
    test('difference', () async {
      final r = method(setOf([1, 2, 3]), 'difference', arg0: setOf([2]));
      expect(await evalPrint(method(r, 'length')), '2');
    });
  });

  group('control flow base functions', () {
    test('if / else taken branch', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'if',
            msg([
              field('condition', literal(true)),
              field('then', literal('yes')),
              field('else', literal('no')),
            ]),
          ),
        ),
        'yes',
      );
    });
    test('if else branch', () async {
      expect(
        await evalPrintStr(
          stdCall(
            'if',
            msg([
              field('condition', literal(false)),
              field('then', literal('yes')),
              field('else', literal('no')),
            ]),
          ),
        ),
        'no',
      );
    });
    test('while loop accumulates', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0)),
            letStmt('sum', literal(0)),
            stmt(
              stdCall(
                'while',
                msg([
                  field(
                    'condition',
                    stdCall(
                      'less_than',
                      msg([
                        field('left', ref('i')),
                        field('right', literal(3)),
                      ]),
                    ),
                  ),
                  field(
                    'body',
                    block([
                      stmt(
                        stdCall(
                          'assign',
                          msg([
                            field('target', ref('sum')),
                            field(
                              'value',
                              stdCall(
                                'add',
                                msg([
                                  field('left', ref('sum')),
                                  field('right', ref('i')),
                                ]),
                              ),
                            ),
                          ]),
                        ),
                      ),
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
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printToString(ref('sum'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '3');
    });
    test('for loop with string init', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('sum', literal(0)),
            stmt(
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
                        field('right', literal(4)),
                      ]),
                    ),
                  ),
                  field(
                    'update',
                    stdCall('pre_increment', msg([field('value', ref('i'))])),
                  ),
                  field(
                    'body',
                    stmt(
                      stdCall(
                        'assign',
                        msg([
                          field('target', ref('sum')),
                          field(
                            'value',
                            stdCall(
                              'add',
                              msg([
                                field('left', ref('sum')),
                                field('right', ref('i')),
                              ]),
                            ),
                          ),
                        ]),
                      ),
                    )['expression'],
                  ),
                ]),
              ),
            ),
            stmt(printToString(ref('sum'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '6');
    });
    test('for_in over a list', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('x')),
                  field('iterable', ints([10, 20, 30])),
                  field('body', printToString(ref('x'))),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['10', '20', '30']);
    });
    test('for_in over a string (chars)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('c')),
                  field('iterable', literal('ab')),
                  field('body', printExpr(ref('c'))),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['a', 'b']);
    });
    test('do_while runs body at least once', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(5)),
            stmt(
              stdCall(
                'do_while',
                msg([
                  field(
                    'body',
                    block([
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
                    ]),
                  ),
                  field('condition', literal(false)),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['5']);
    });
    test('break exits loop early', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('x')),
                  field('iterable', ints([1, 2, 3, 4])),
                  field(
                    'body',
                    block([
                      stmt(
                        stdCall(
                          'if',
                          msg([
                            field(
                              'condition',
                              stdCall(
                                'greater_than',
                                msg([
                                  field('left', ref('x')),
                                  field('right', literal(2)),
                                ]),
                              ),
                            ),
                            field('then', stdCall('break', msg([]))),
                          ]),
                        ),
                      ),
                      stmt(printToString(ref('x'))),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1', '2']);
    });
    test('continue skips iteration', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('x')),
                  field('iterable', ints([1, 2, 3])),
                  field(
                    'body',
                    block([
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
                            field('then', stdCall('continue', msg([]))),
                          ]),
                        ),
                      ),
                      stmt(printToString(ref('x'))),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1', '3']);
    });
    test('return from a function', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'pick',
            'metadata': {
              'kind': 'function',
              'params': [
                {'name': 'n', 'type': 'int'},
              ],
            },
            'body': block([
              stmt(
                stdCall(
                  'if',
                  msg([
                    field(
                      'condition',
                      stdCall(
                        'greater_than',
                        msg([
                          field('left', ref('n')),
                          field('right', literal(0)),
                        ]),
                      ),
                    ),
                    field(
                      'then',
                      stdCall('return', msg([field('value', literal('pos'))])),
                    ),
                  ]),
                ),
              ),
              stmt(stdCall('return', msg([field('value', literal('nonpos'))]))),
            ]),
          },
          mainFn([
            stmt(
              printExpr(
                call(
                  'pick',
                  module: 'main',
                  input: msg([field('n', literal(5))]),
                ),
              ),
            ),
            stmt(
              printExpr(
                call(
                  'pick',
                  module: 'main',
                  input: msg([field('n', literal(-1))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['pos', 'nonpos']);
    });
    test('switch statement matches a case', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(2)),
            stmt(
              stdCall(
                'switch',
                msg([
                  field('subject', ref('x')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('value', literal(1)),
                        field('body', printStrExpr('one')),
                      ]),
                      msg([
                        field('value', literal(2)),
                        field('body', printStrExpr('two')),
                      ]),
                      msg([
                        field('is_default', literal(true)),
                        field('body', printStrExpr('other')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['two']);
    });
    test('switch default case', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(99)),
            stmt(
              stdCall(
                'switch',
                msg([
                  field('subject', ref('x')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('value', literal(1)),
                        field('body', printStrExpr('one')),
                      ]),
                      msg([
                        field('is_default', literal(true)),
                        field('body', printStrExpr('other')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['other']);
    });
    test('try/catch catches a thrown value', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field(
                    'body',
                    block([
                      stmt(
                        stdCall(
                          'throw',
                          msg([field('value', literal('boom'))]),
                        ),
                      ),
                      stmt(printStrExpr('unreached')),
                    ]),
                  ),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('variable', literal('e')),
                        field('body', printStrExpr('caught')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['caught']);
    });
    test('try/finally always runs', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', printStrExpr('body')),
                  field('finally', printStrExpr('cleanup')),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['body', 'cleanup']);
    });
    test('and short-circuits (right not evaluated)', () async {
      expect(
        await evalPrint(
          stdCall(
            'and',
            msg([field('left', literal(false)), field('right', literal(true))]),
          ),
        ),
        'false',
      );
    });
    test('or short-circuits', () async {
      expect(
        await evalPrint(
          stdCall(
            'or',
            msg([field('left', literal(true)), field('right', literal(false))]),
          ),
        ),
        'true',
      );
    });
  });

  group('assignment & increment', () {
    test('simple assign', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(1)),
            stmt(
              stdCall(
                'assign',
                msg([field('target', ref('x')), field('value', literal(9))]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '9');
    });
    test('compound += numeric', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(1)),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(4)),
                  field('op', literal('+=')),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '5');
    });
    test('compound *= ', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(3)),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(4)),
                  field('op', literal('*=')),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '12');
    });
    test('compound ??= keeps non-null', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(7)),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(9)),
                  field('op', literal('??=')),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '7');
    });
    test('pre_increment returns new value and mutates', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(5)),
            stmt(
              printToString(
                stdCall('pre_increment', msg([field('value', ref('x'))])),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['6', '6']);
    });
    test('post_increment returns old value and mutates', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(5)),
            stmt(
              printToString(
                stdCall('post_increment', msg([field('value', ref('x'))])),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['5', '6']);
    });
    test('pre_decrement', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(5)),
            stmt(
              printToString(
                stdCall('pre_decrement', msg([field('value', ref('x'))])),
              ),
            ),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '4');
    });
    test('index assignment list[i] = v', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([1, 2, 3])),
            stmt(
              stdCall(
                'assign',
                msg([
                  field(
                    'target',
                    stdCall(
                      'index',
                      msg([
                        field('target', ref('xs')),
                        field('index', literal(0)),
                      ]),
                    ),
                  ),
                  field('value', literal(99)),
                ]),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '[99, 2, 3]');
    });
  });

  group('field-access getters (virtual properties)', () {
    Map<String, dynamic> setOf(List<int> xs) =>
        stdCall('set_create', msg([field('elements', ints(xs))]));
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

    test('list .length / .isEmpty / .isNotEmpty', () async {
      expect(await evalPrint(fieldAcc(ints([1, 2, 3]), 'length')), '3');
      expect(await evalPrint(fieldAcc(ints([]), 'isEmpty')), 'true');
      expect(await evalPrint(fieldAcc(ints([1]), 'isNotEmpty')), 'true');
    });
    test('string .length / .isEmpty', () async {
      expect(await evalPrint(fieldAcc(literal('abcd'), 'length')), '4');
      expect(await evalPrint(fieldAcc(literal(''), 'isEmpty')), 'true');
    });
    test('list .first / .last / .single', () async {
      expect(await evalPrint(fieldAcc(ints([5, 6, 7]), 'first')), '5');
      expect(await evalPrint(fieldAcc(ints([5, 6, 7]), 'last')), '7');
      expect(await evalPrint(fieldAcc(ints([9]), 'single')), '9');
    });
    test('list .reversed', () async {
      expect(
        await evalPrint(fieldAcc(ints([1, 2, 3]), 'reversed')),
        '[3, 2, 1]',
      );
    });
    test('map .keys / .values / .length / .entries', () async {
      final m = mapOf({'a': 1, 'b': 2});
      expect(await evalPrint(fieldAcc(m, 'keys')), '[a, b]');
      expect(await evalPrint(fieldAcc(m, 'values')), '[1, 2]');
      expect(await evalPrint(fieldAcc(m, 'length')), '2');
      expect(
        await evalPrint(fieldAcc(m, 'entries')),
        '[{key: a, value: 1}, {key: b, value: 2}]',
      );
    });
    test('map .isEmpty / .isNotEmpty', () async {
      expect(await evalPrint(fieldAcc(mapOf({}), 'isEmpty')), 'true');
      expect(await evalPrint(fieldAcc(mapOf({'a': 1}), 'isNotEmpty')), 'true');
    });
    test('set .length / .isEmpty', () async {
      expect(await evalPrint(fieldAcc(setOf([1, 2, 3]), 'length')), '3');
      expect(await evalPrint(fieldAcc(setOf([]), 'isEmpty')), 'true');
    });
    test('num .isNegative / .sign / .abs', () async {
      expect(await evalPrint(fieldAcc(literal(-3), 'isNegative')), 'true');
      expect(await evalPrint(fieldAcc(literal(-3), 'sign')), '-1');
      expect(await evalPrint(fieldAcc(literal(-3), 'abs')), '3');
    });
    test('value .runtimeType', () async {
      expect(await evalPrintStr(fieldAcc(literal(1), 'runtimeType')), 'int');
      expect(
        await evalPrintStr(fieldAcc(literal('s'), 'runtimeType')),
        'String',
      );
      expect(
        await evalPrintStr(fieldAcc(literal(true), 'runtimeType')),
        'bool',
      );
      expect(await evalPrintStr(fieldAcc(ints([1]), 'runtimeType')), 'List');
    });
    test('value .toString getter', () async {
      expect(await evalPrintStr(fieldAcc(literal(42), 'toString')), '42');
    });
  });

  group('compound assignment operators', () {
    Future<String> compound(int start, String op, int rhs) async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(start)),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(rhs)),
                  field('op', literal(op)),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      return (await runAndCapture(program)).single;
    }

    test('-=', () async => expect(await compound(10, '-=', 3), '7'));
    test('~/=', () async => expect(await compound(10, '~/=', 3), '3'));
    test('%=', () async => expect(await compound(10, '%=', 3), '1'));
    test('&=', () async => expect(await compound(6, '&=', 3), '2'));
    test('|=', () async => expect(await compound(6, '|=', 1), '7'));
    test('^=', () async => expect(await compound(6, '^=', 3), '5'));
    test('<<=', () async => expect(await compound(1, '<<=', 3), '8'));
    test('>>=', () async => expect(await compound(8, '>>=', 2), '2'));
    test('>>>=', () async => expect(await compound(8, '>>>=', 1), '4'));
    test('+= string concat', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('s', literal('a')),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('s')),
                  field('value', literal('b')),
                  field('op', literal('+=')),
                ]),
              ),
            ),
            stmt(printExpr(ref('s'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, 'ab');
    });
    test('/= true division', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'x',
              stdCall(
                'divide_double',
                msg([
                  field('left', literal(10.0)),
                  field('right', literal(1.0)),
                ]),
              ),
            ),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(4)),
                  field('op', literal('/=')),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect((await runAndCapture(program)).single, '2.5');
    });
  });

  group('increment/decrement on compound targets', () {
    test('pre_increment on list index mutates element', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([10, 20, 30])),
            stmt(
              printToString(
                stdCall(
                  'pre_increment',
                  msg([
                    field(
                      'value',
                      stdCall(
                        'index',
                        msg([
                          field('target', ref('xs')),
                          field('index', literal(1)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['21', '[10, 21, 30]']);
    });
    test('post_increment on list index returns old value', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', ints([5])),
            stmt(
              printToString(
                stdCall(
                  'post_increment',
                  msg([
                    field(
                      'value',
                      stdCall(
                        'index',
                        msg([
                          field('target', ref('xs')),
                          field('index', literal(0)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['5', '[6]']);
    });
  });

  group('for-loop string-init expressions', () {
    test('init "var n = s.length - 1" (prop OP num)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('s', literal('hello')),
            stmt(
              stdCall(
                'for',
                msg([
                  field('init', literal('var n = s.length - 1')),
                  field(
                    'condition',
                    stdCall(
                      'gte',
                      msg([
                        field('left', ref('n')),
                        field('right', literal(3)),
                      ]),
                    ),
                  ),
                  field(
                    'update',
                    stdCall('pre_decrement', msg([field('value', ref('n'))])),
                  ),
                  field('body', printToString(ref('n'))),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['4', '3']);
    });
    test('init "var i = arr.length" (prop access)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('arr', ints([1, 2, 3])),
            stmt(
              stdCall(
                'for',
                msg([
                  field('init', literal('var i = arr.length')),
                  field(
                    'condition',
                    stdCall(
                      'greater_than',
                      msg([
                        field('left', ref('i')),
                        field('right', literal(1)),
                      ]),
                    ),
                  ),
                  field(
                    'update',
                    stdCall('pre_decrement', msg([field('value', ref('i'))])),
                  ),
                  field('body', printToString(ref('i'))),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3', '2']);
    });
    test('init with bool literal "var done = false"', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'for',
                msg([
                  field('init', literal('var done = false')),
                  field(
                    'condition',
                    stdCall('not', msg([field('value', ref('done'))])),
                  ),
                  field(
                    'update',
                    stdCall(
                      'assign',
                      msg([
                        field('target', ref('done')),
                        field('value', literal(true)),
                      ]),
                    ),
                  ),
                  field('body', printToString(ref('done'))),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['false']);
    });
  });

  group('labeled loops', () {
    test('labeled break exits outer loop', () async {
      // outer: for x in [1,2,3]: for y in [1,2]: if x==2 break outer; print "x,y"
      final inner = stdCall(
        'for_in',
        msg([
          field('variable', literal('y')),
          field('iterable', ints([1, 2])),
          field(
            'body',
            block([
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
                    field(
                      'then',
                      stdCall('break', msg([field('label', literal('outer'))])),
                    ),
                  ]),
                ),
              ),
              stmt(printStrExpr2(ref('x'), ref('y'))),
            ]),
          ),
        ]),
      );
      final outer = stdCall(
        'labeled',
        msg([
          field('label', literal('outer')),
          field(
            'body',
            stdCall(
              'for_in',
              msg([
                field('variable', literal('x')),
                field('iterable', ints([1, 2, 3])),
                field('body', inner),
              ]),
            ),
          ),
        ]),
      );
      final program = buildProgram(
        functions: [
          mainFn([stmt(outer)]),
        ],
      );
      // x=1: y=1 -> "1-1", y=2 -> "1-2"; x=2 -> break outer.
      expect(await runAndCapture(program), ['1-1', '1-2']);
    });
  });
}

/// Prints "a-b" from two int expressions (for labeled-loop tests).
Map<String, dynamic> printStrExpr2(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  final concat = stdCall(
    'add',
    msg([
      field(
        'left',
        stdCall(
          'add',
          msg([
            field('left', stdCall('to_string', msg([field('value', a)]))),
            field('right', literal('-')),
          ]),
        ),
      ),
      field('right', stdCall('to_string', msg([field('value', b)]))),
    ]),
  );
  return printExpr(concat);
}

Map<String, dynamic> printStrExpr(String s) => printExpr(literal(s));
