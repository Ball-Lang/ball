// Wave-5 tail-coverage tests for engine_control_flow.dart.
//
// A direct continuation of engine_control_flow_coverage_test.dart and
// engine_control_flow_extra_coverage_test.dart (and engine_tail_coverage_test),
// this file targets the still-uncovered branches of the tree-walking
// interpreter's control-flow implementation: the string-form for-loop init
// simple-expression parser (BallList/BallMap/raw-Map receivers, `*` and `/`
// operators), do_while return/labeled/break propagation, switch-default break,
// compound/inc-dec assignment onto BallMap and raw-List and field targets,
// the full family of labeled loop signal-propagation arms (labeled-continue,
// unlabeled-break, and "signal targets an OUTER loop"), single-expression
// cascades, dart_await_for, direct-input yield / yield_each, portable-set and
// native-Set instance methods, and the wrapper-type (BallString / BallInt /
// BallMap) receiver-unwrap arms of _dispatchBuiltinInstanceMethod.
//
// Several branches only arise for values the Dart reference engine never
// produces from source literals (native Dart `Set`s, `BallString`/`BallInt`
// wrappers, `BallMap` typed maps). Those are reached the way a real embedder
// would create them: via a custom [BallModuleHandler] (`nat`) that returns
// native/wrapped values, which then flow through the ordinary interpreter
// dispatch paths. This mirrors how the TS/C++ self-hosts naturally hold such
// values.
//
// Field-name conventions match the engine's extractors (binary ops read
// left/right, unary ops read value, index reads target/index, assign reads
// target/value/op, loops read init/condition/update/body/variable/iterable).
import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Self-contained builder helpers (independent of engine_test.dart). ──

/// A custom module whose functions return *native* Dart collections and Ball
/// value wrappers — values the Dart engine never mints from source literals but
/// that the interpreter's dispatch paths must still handle (they arise on the
/// TS/C++ self-hosts). Each call returns a FRESH object so mutation tests do not
/// leak across cases.
class _NatHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'nat';

  @override
  FutureOr<Object?> call(String function, Object? input, BallCallable engine) {
    switch (function) {
      // Native Dart sets (insertion-ordered LinkedHashSet).
      case 'set':
        return <Object?>{1, 2, 3};
      case 'set2':
        return <Object?>{2, 3, 4};
      case 'eset':
        return <Object?>{};
      // Native Dart lists (NOT BallList wrappers).
      case 'list':
        return <Object?>[3, 4];
      case 'list123':
        return <Object?>[1, 2, 3];
      case 'list10':
        return <Object?>[10, 20, 30];
      // Ball value wrappers.
      case 'bmap':
        return BallMap(<String, Object?>{'a': 1, 'b': 2});
      case 'bmap0':
        return BallMap(<String, Object?>{'c': 0});
      case 'bstr':
        return const BallString('abcd');
      case 'bint':
        return const BallInt(5);
      // A typed-object map that reads as a StringBuffer, plus a generic
      // typed object (non-StringBuffer) for the fallback toString arm.
      case 'sbuf':
        return BallMap(<String, Object?>{
          '__type__': 'StringBuffer',
          '__buffer__': 'hi',
        });
      case 'typedobj':
        return BallMap(<String, Object?>{'__type__': 'Foo', 'x': 1});
      default:
        throw BallRuntimeError('Unknown nat function: "$function"');
    }
  }
}

Future<List<String>> runAndCapture(
  Program program, {
  List<BallModuleHandler>? handlers,
}) async {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    moduleHandlers: handlers ?? [StdModuleHandler(), _NatHandler()],
  );
  await engine.run();
  return lines;
}

const _stdFnNames = <String>[
  'print',
  'to_string',
  'add',
  'subtract',
  'multiply',
  'divide',
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
  'if',
  'for',
  'for_in',
  'while',
  'do_while',
  'switch',
  'switch_expr',
  'return',
  'break',
  'continue',
  'labeled',
  'label',
  'goto',
  'assign',
  'index',
  'pre_increment',
  'pre_decrement',
  'post_increment',
  'post_decrement',
  'to_double',
  'to_int',
  'cascade',
  'null_aware_cascade',
  'yield',
  'yield_each',
  'record',
  'spread',
  'set_create',
  'map_create',
  'map_get',
  'list_remove_at',
  'list_pop',
  'dart_await_for',
];

Map<String, dynamic> _natModule() => {
  'name': 'nat',
  'functions': [
    for (final n in const [
      'set',
      'set2',
      'eset',
      'list',
      'list123',
      'list10',
      'bmap',
      'bmap0',
      'bstr',
      'bint',
      'sbuf',
      'typedobj',
    ])
      {'name': n, 'isBase': true},
  ],
};

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

Map<String, dynamic> natCall(String function) => call(function, module: 'nat');

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

Map<String, dynamic> fieldAccess(Map<String, dynamic> object, String fieldN) =>
    {
      'fieldAccess': {'object': object, 'field': fieldN},
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

// ── Small expression helpers. ──

Map<String, dynamic> bin(
  String fn,
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) => stdCall(fn, msg([field('left', left), field('right', right)]));

Map<String, dynamic> notOf(Map<String, dynamic> value) =>
    stdCall('not', msg([field('value', value)]));

Map<String, dynamic> idx(
  Map<String, dynamic> target,
  Map<String, dynamic> index,
) => stdCall('index', msg([field('target', target), field('index', index)]));

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

Map<String, dynamic> lengthOf(Map<String, dynamic> selfExpr) =>
    call('length', input: msg([field('self', selfExpr)]));

Map<String, dynamic> ifThen(
  Map<String, dynamic> condition,
  Map<String, dynamic> then,
) => stdCall('if', msg([field('condition', condition), field('then', then)]));

Map<String, dynamic> cFor({
  required Map<String, dynamic> init,
  required Map<String, dynamic> condition,
  required Map<String, dynamic> update,
  required Map<String, dynamic> body,
}) => stdCall(
  'for',
  msg([
    field('init', init),
    field('condition', condition),
    field('update', update),
    field('body', body),
  ]),
);

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

Map<String, dynamic> whileLoop(
  Map<String, dynamic> condition,
  Map<String, dynamic> body,
) =>
    stdCall('while', msg([field('condition', condition), field('body', body)]));

Map<String, dynamic> doWhile(
  Map<String, dynamic> condition,
  Map<String, dynamic> body,
) => stdCall(
  'do_while',
  msg([field('body', body), field('condition', condition)]),
);

Map<String, dynamic> labeled(String label, Map<String, dynamic> body) =>
    stdCall(
      'labeled',
      msg([field('label', literal(label)), field('body', body)]),
    );

Map<String, dynamic> breakL(String label) =>
    stdCall('break', msg([field('label', literal(label))]));

Map<String, dynamic> continueL(String label) =>
    stdCall('continue', msg([field('label', literal(label))]));

Map<String, dynamic> breakUnlabeled() => stdCall('break', msg([]));

Map<String, dynamic> intList(List<int> xs) =>
    listLit([for (final x in xs) literal(x)]);

/// Run a single expression through `to_string` + `print`; return the one line.
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
  // ─────────────────────────────────────────────────────────────────────────
  group('for-init string-form simple-expr parser (_evalSimpleInitExpr)', () {
    // Runs a C-style for whose `init` is a "var NAME = <expr>" string literal,
    // seeding NAME from a simple expression parsed against pre-bound variables,
    // then counts using NAME so output confirms the parsed value.
    Map<String, dynamic> stringInitFor({
      required String init,
      required Map<String, dynamic> condition,
      required Map<String, dynamic> update,
      required Map<String, dynamic> body,
    }) => cFor(
      init: literal(init),
      condition: condition,
      update: update,
      body: body,
    );

    Program countDownProgram({
      required List<Map<String, dynamic>> setup,
      required String init,
      required Map<String, dynamic> condition,
    }) => buildProgram(
      functions: [
        mainFn([
          ...setup,
          stmt(
            stringInitFor(
              init: init,
              condition: condition,
              update: assign(ref('n'), bin('subtract', ref('n'), literal(1))),
              body: printToString(ref('n')),
            ),
          ),
        ]),
      ],
    );

    test(
      'init "var n = bs.length - 1" (BallString.length prop-op-num)',
      () async {
        // bs is a BallString wrapper → obj is BallString branch.
        final program = countDownProgram(
          setup: [letStmt('bs', natCall('bstr'))],
          init: 'var n = bs.length - 1',
          condition: bin('gte', ref('n'), literal(0)),
        );
        // 'abcd'.length(4) - 1 = 3 → 3,2,1,0.
        expect(await runAndCapture(program), ['3', '2', '1', '0']);
      },
    );

    test('init "var n = arr.length * 2" (BallList.length, `*`)', () async {
      final program = countDownProgram(
        setup: [
          letStmt('arr', intList([1, 2, 3])),
        ],
        init: 'var n = arr.length * 2',
        condition: bin('greater_than', ref('n'), literal(4)),
      );
      // BallList length(3) * 2 = 6 → 6,5.
      expect(await runAndCapture(program), ['6', '5']);
    });

    test('init "var n = ks.length / 2" (raw List.length, `/`)', () async {
      final program = countDownProgram(
        setup: [letStmt('ks', natCall('list123'))],
        init: 'var n = ks.length / 2',
        condition: bin('gte', ref('n'), literal(0)),
      );
      // native List length(3) ~/ 2 = 1 → 1,0.
      expect(await runAndCapture(program), ['1', '0']);
    });

    test('init "var n = o.length - 1" (BallMap.length prop-op-num)', () async {
      final program = countDownProgram(
        setup: [letStmt('o', natCall('bmap'))],
        init: 'var n = o.length - 1',
        condition: bin('gte', ref('n'), literal(0)),
      );
      // BallMap entries(2) - 1 = 1 → 1,0.
      expect(await runAndCapture(program), ['1', '0']);
    });

    test('init "var n = m.length - 1" (raw Map.length prop-op-num)', () async {
      final program = countDownProgram(
        setup: [
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
                    msg([
                      field('key', literal('b')),
                      field('value', literal(2)),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ],
        init: 'var n = m.length - 1',
        condition: bin('gte', ref('n'), literal(0)),
      );
      // raw Map length(2) - 1 = 1 → 1,0.
      expect(await runAndCapture(program), ['1', '0']);
    });

    test('init "var n = m.x - 1" (_cfAsMap fallback on raw Map)', () async {
      final program = countDownProgram(
        setup: [
          letStmt(
            'm',
            stdCall(
              'map_create',
              msg([
                field(
                  'entries',
                  listLit([
                    msg([
                      field('key', literal('x')),
                      field('value', literal(5)),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ],
        init: 'var n = m.x - 1',
        condition: bin('greater_than', ref('n'), literal(0)),
      );
      // m['x'](5) - 1 = 4 → 4,3,2,1.
      expect(await runAndCapture(program), ['4', '3', '2', '1']);
    });

    test('init "var n = a / b" (var-op-var `/`)', () async {
      final program = countDownProgram(
        setup: [letStmt('a', literal(12)), letStmt('b', literal(4))],
        init: 'var n = a / b',
        condition: bin('greater_than', ref('n'), literal(0)),
      );
      // 12 ~/ 4 = 3 → 3,2,1.
      expect(await runAndCapture(program), ['3', '2', '1']);
    });

    // prop-access ("var m = X.prop") branches: raw List / BallMap / raw Map /
    // _cfAsMap fallback. (BallList.length prop-access is already covered by the
    // sibling tail-coverage file.)
    Program countDownProgramM({
      required List<Map<String, dynamic>> setup,
      required String init,
      required Map<String, dynamic> condition,
    }) => buildProgram(
      functions: [
        mainFn([
          ...setup,
          stmt(
            stringInitFor(
              init: init,
              condition: condition,
              update: assign(ref('m'), bin('subtract', ref('m'), literal(1))),
              body: printToString(ref('m')),
            ),
          ),
        ]),
      ],
    );

    test('init "var m = ks.length" (raw List.length prop-access)', () async {
      final program = countDownProgramM(
        setup: [letStmt('ks', natCall('list123'))],
        init: 'var m = ks.length',
        condition: bin('greater_than', ref('m'), literal(0)),
      );
      expect(await runAndCapture(program), ['3', '2', '1']);
    });

    test('init "var m = o.length" (BallMap.length prop-access)', () async {
      final program = countDownProgramM(
        setup: [letStmt('o', natCall('bmap'))],
        init: 'var m = o.length',
        condition: bin('greater_than', ref('m'), literal(0)),
      );
      expect(await runAndCapture(program), ['2', '1']);
    });

    test('init "var m = mp.length" (raw Map.length prop-access)', () async {
      final program = countDownProgramM(
        setup: [
          letStmt(
            'mp',
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
        ],
        init: 'var m = mp.length',
        condition: bin('greater_than', ref('m'), literal(0)),
      );
      expect(await runAndCapture(program), ['2', '1']);
    });

    test('init "var m = mp.y" (_cfAsMap fallback prop-access)', () async {
      final program = countDownProgramM(
        setup: [
          letStmt(
            'mp',
            stdCall(
              'map_create',
              msg([
                field(
                  'entries',
                  listLit([
                    msg([
                      field('key', literal('y')),
                      field('value', literal(2)),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ],
        init: 'var m = mp.y',
        condition: bin('greater_than', ref('m'), literal(0)),
      );
      expect(await runAndCapture(program), ['2', '1']);
    });

    test('for init as a plain expression (non-string, non-block)', () async {
      // init is an `assign` call expression → the else arm of _evalForInit.
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(5)),
            stmt(
              cFor(
                init: assign(ref('i'), literal(0)),
                condition: bin('less_than', ref('i'), literal(2)),
                update: assign(ref('i'), bin('add', ref('i'), literal(1))),
                body: printToString(ref('i')),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1']);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('if / do_while / switch error and signal arms', () {
    test('std.if missing then throws BallRuntimeError', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('if', msg([field('condition', literal(true))]))),
          ]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('plain do_while consumes an unlabeled break', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              doWhile(
                literal(true),
                blockExpr([
                  stmt(printExpr(literal('x'))),
                  stmt(breakUnlabeled()),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['x']);
    });

    test('do_while body return propagates out of the function', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'g',
            'body': doWhile(
              literal(true),
              blockExpr([
                stmt(stdCall('return', msg([field('value', literal(42))]))),
              ]),
            ),
          },
          mainFn([stmt(printToString(call('g')))]),
        ],
      );
      expect(await runAndCapture(program), ['42']);
    });

    test('do_while body break targeting an OUTER label propagates', () async {
      // for_in is the labeled loop; the inner plain do_while emits break outer.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'outer',
                forIn(
                  't',
                  intList([1]),
                  blockExpr([
                    stmt(
                      doWhile(
                        literal(true),
                        blockExpr([
                          stmt(printExpr(literal('z'))),
                          stmt(breakL('outer')),
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
      expect(await runAndCapture(program), ['z']);
    });

    test('switch default body break returns null (no leak)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'switch',
                msg([
                  field('subject', literal(99)),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('value', literal(1)),
                        field('body', printExpr(literal('one'))),
                      ]),
                      msg([
                        field('is_default', literal(true)),
                        field(
                          'body',
                          blockExpr([
                            stmt(printExpr(literal('99'))),
                            stmt(breakUnlabeled()),
                          ]),
                        ),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['99']);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('assignment / inc-dec target arms (_evalAssign, _evalIncDec)', () {
    test('assign(x, list_remove_at(list: x, ...)) mutates in place', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', intList([1, 2, 3])),
            stmt(
              assign(
                ref('xs'),
                stdCall(
                  'list_remove_at',
                  msg([field('list', ref('xs')), field('index', literal(0))]),
                ),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[2, 3]']);
    });

    test('field-access compound assign obj.field += val (raw Map)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'o',
              stdCall(
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
            stmt(assign(fieldAccess(ref('o'), 'x'), literal(5), op: '+=')),
            stmt(printToString(idx(ref('o'), literal('x')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['6']);
    });

    test('index assign on an empty set coerces it to a map (#68)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'm',
              stdCall('set_create', msg([field('elements', listLit([]))])),
            ),
            stmt(assign(idx(ref('m'), literal('a')), literal(1))),
            stmt(printToString(idx(ref('m'), literal('a')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1']);
    });

    test('compound index assign on a raw List: xs[1] += 5', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', natCall('list10')),
            stmt(assign(idx(ref('xs'), literal(1)), literal(5), op: '+=')),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[10, 25, 30]']);
    });

    test('compound index assign on a BallMap: o["a"] += 4', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('o', natCall('bmap')),
            stmt(assign(idx(ref('o'), literal('a')), literal(4), op: '+=')),
            stmt(printToString(idx(ref('o'), literal('a')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['5']);
    });

    test('pre-increment on a BallMap index: ++o["c"]', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('o', natCall('bmap0')),
            stmt(
              stdCall(
                'pre_increment',
                msg([field('value', idx(ref('o'), literal('c')))]),
              ),
            ),
            stmt(printToString(idx(ref('o'), literal('c')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1']);
    });

    test('post-increment on a field access: o.x++', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'o',
              stdCall(
                'map_create',
                msg([
                  field(
                    'entries',
                    listLit([
                      msg([
                        field('key', literal('x')),
                        field('value', literal(5)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(
              stdCall(
                'post_increment',
                msg([field('value', fieldAccess(ref('o'), 'x'))]),
              ),
            ),
            stmt(printToString(fieldAccess(ref('o'), 'x'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['6']);
    });

    test('inc-dec fallback: post_increment on a bare literal', () async {
      // valueExpr is a literal (not ref/index/fieldAccess) → the compute-only
      // fallback arm; ++ on a bare value just yields value+1.
      expect(
        await evalPrint(
          stdCall('post_increment', msg([field('value', literal(5))])),
        ),
        '6',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('labeled loops: continue / unlabeled-break / outer-signal arms', () {
    // Counter-mutating body used by while/do_while variants.
    Map<String, dynamic> incI() =>
        assign(ref('i'), bin('add', ref('i'), literal(1)));

    test('labeled for with a double-valued string init', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'f',
                cFor(
                  init: literal('var d = 1.5'),
                  condition: bin('less_than', ref('d'), literal(3.0)),
                  update: assign(ref('d'), bin('add', ref('d'), literal(1))),
                  body: printToString(ref('d')),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1.5', '2.5']);
    });

    test('labeled for with a bool `true` string init', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'f',
                cFor(
                  init: literal('var flag = true'),
                  condition: ref('flag'),
                  update: assign(ref('flag'), literal(false)),
                  body: printExpr(literal('x')),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['x']);
    });

    test('labeled for with a bool `false` string init', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'f',
                cFor(
                  init: literal('var flag = false'),
                  condition: notOf(ref('flag')),
                  update: assign(ref('flag'), literal(true)),
                  body: printExpr(literal('y')),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['y']);
    });

    test('labeled for with a plain-expression init', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(9)),
            stmt(
              labeled(
                'f',
                cFor(
                  init: assign(ref('i'), literal(0)),
                  condition: bin('less_than', ref('i'), literal(2)),
                  update: incI(),
                  body: printToString(ref('i')),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1']);
    });

    test(
      'labeled for: body break targeting an OUTER label propagates',
      () async {
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                labeled(
                  'outer',
                  blockExpr([
                    stmt(
                      labeled(
                        'inner',
                        cFor(
                          init: literal('var i = 0'),
                          condition: bin('less_than', ref('i'), literal(3)),
                          update: incI(),
                          body: blockExpr([
                            stmt(printExpr(literal('a'))),
                            stmt(breakL('outer')),
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
        expect(await runAndCapture(program), ['a']);
      },
    );

    test('labeled for consumes an unlabeled break', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'f',
                cFor(
                  init: literal('var i = 0'),
                  condition: bin('less_than', ref('i'), literal(3)),
                  update: incI(),
                  body: blockExpr([
                    stmt(printToString(ref('i'))),
                    stmt(breakUnlabeled()),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0']);
    });

    test('labeled for_in consumes an unlabeled break', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'L',
                forIn(
                  'x',
                  intList([1, 2, 3]),
                  blockExpr([
                    stmt(printToString(ref('x'))),
                    stmt(breakUnlabeled()),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1']);
    });

    test(
      'labeled for_in: body break targeting an OUTER label propagates',
      () async {
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                labeled(
                  'outer',
                  blockExpr([
                    stmt(
                      labeled(
                        'inner',
                        forIn(
                          'x',
                          intList([1]),
                          blockExpr([
                            stmt(printExpr(literal('b'))),
                            stmt(breakL('outer')),
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
        expect(await runAndCapture(program), ['b']);
      },
    );

    test('labeled while with labeled continue', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0)),
            stmt(
              labeled(
                'w',
                whileLoop(
                  bin('less_than', ref('i'), literal(3)),
                  blockExpr([
                    stmt(incI()),
                    stmt(
                      ifThen(
                        bin('equals', ref('i'), literal(2)),
                        blockExpr([stmt(continueL('w'))]),
                      ),
                    ),
                    stmt(printToString(ref('i'))),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1', '3']);
    });

    test('labeled while consumes an unlabeled break', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0)),
            stmt(
              labeled(
                'w',
                whileLoop(
                  bin('less_than', ref('i'), literal(3)),
                  blockExpr([
                    stmt(printToString(ref('i'))),
                    stmt(incI()),
                    stmt(breakUnlabeled()),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0']);
    });

    test(
      'labeled while: body break targeting an OUTER label propagates',
      () async {
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                labeled(
                  'outer',
                  blockExpr([
                    stmt(
                      labeled(
                        'w',
                        whileLoop(
                          literal(true),
                          blockExpr([
                            stmt(printExpr(literal('c'))),
                            stmt(breakL('outer')),
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
        expect(await runAndCapture(program), ['c']);
      },
    );

    test(
      'labeled do_while with labeled continue re-checks condition',
      () async {
        // continue 'd' at i>=2 makes the post-continue condition (i<2) fail →
        // exercises the continue → condition-check → break path.
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt('i', literal(0)),
              stmt(
                labeled(
                  'd',
                  doWhile(
                    bin('less_than', ref('i'), literal(2)),
                    blockExpr([
                      stmt(incI()),
                      stmt(
                        ifThen(
                          bin('gte', ref('i'), literal(2)),
                          blockExpr([stmt(continueL('d'))]),
                        ),
                      ),
                      stmt(printToString(ref('i'))),
                    ]),
                  ),
                ),
              ),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['1']);
      },
    );

    test('labeled do_while consumes an unlabeled break', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              labeled(
                'd',
                doWhile(
                  literal(true),
                  blockExpr([
                    stmt(printExpr(literal('w'))),
                    stmt(breakUnlabeled()),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['w']);
    });

    test(
      'labeled do_while: body break targeting an OUTER label propagates',
      () async {
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                labeled(
                  'outer',
                  blockExpr([
                    stmt(
                      labeled(
                        'd',
                        doWhile(
                          literal(true),
                          blockExpr([
                            stmt(printExpr(literal('e'))),
                            stmt(breakL('outer')),
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
        expect(await runAndCapture(program), ['e']);
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('label wrapper: returned goto-shaped map (_gotoSignalLabel)', () {
    test('non-matching returned goto map is not re-entered', () async {
      // The label body returns a `{kind: goto, label: other}` map (portable
      // flow-signal form). _gotoSignalLabel recognizes it but the label does
      // not match this wrapper ('start'), so the body runs exactly once.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'label',
                  msg([
                    field('name', literal('start')),
                    field(
                      'body',
                      stdCall(
                        'map_create',
                        msg([
                          field(
                            'entries',
                            listLit([
                              msg([
                                field('key', literal('kind')),
                                field('value', literal('goto')),
                              ]),
                              msg([
                                field('key', literal('label')),
                                field('value', literal('other')),
                              ]),
                            ]),
                          ),
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
      expect(await runAndCapture(program), ['{kind: goto, label: other}']);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('cascade with a single (non-list) section (_evalLazyCascade)', () {
    test('sections is one call expression, not a list literal', () async {
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
                    call(
                      'add',
                      input: msg([
                        field('self', ref('__cascade_self__')),
                        field('arg0', literal(1)),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[1]']);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('dart_await_for delegates to for_in (_evalAwaitFor)', () {
    test('await-for over a list iterates like for_in', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'dart_await_for',
                msg([
                  field('variable', literal('x')),
                  field('iterable', intList([1, 2])),
                  field('body', printToString(ref('x'))),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1', '2']);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('yield / yield_each with direct (non-message) input', () {
    Map<String, dynamic> genFn(String name, Map<String, dynamic> body) => {
      'name': name,
      'metadata': {'kind': 'function', 'is_sync_star': true},
      'body': body,
    };

    test('yield with a bare-literal input collects the value', () async {
      final program = buildProgram(
        functions: [
          genFn(
            'nums',
            blockExpr([
              stmt(call('yield', module: 'std', input: literal(5))),
              stmt(call('yield', module: 'std', input: literal(6))),
            ]),
          ),
          mainFn([stmt(printToString(call('nums')))]),
        ],
      );
      expect(await runAndCapture(program), ['[5, 6]']);
    });

    test('yield_each with a bare list-literal input splices it', () async {
      final program = buildProgram(
        functions: [
          genFn(
            'nums',
            blockExpr([
              stmt(call('yield_each', module: 'std', input: intList([1, 2]))),
            ]),
          ),
          mainFn([stmt(printToString(call('nums')))]),
        ],
      );
      expect(await runAndCapture(program), ['[1, 2]']);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('portable-set instance methods (addAll / toSet)', () {
    Map<String, dynamic> setOf(List<int> xs) => stdCall(
      'set_create',
      msg([
        field('elements', listLit([for (final x in xs) literal(x)])),
      ]),
    );

    test('set.addAll(list) unions new elements in place', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('s', setOf([1, 2])),
            stmt(
              call(
                'addAll',
                input: msg([
                  field('self', ref('s')),
                  field('arg0', intList([2, 3])),
                ]),
              ),
            ),
            stmt(printToString(lengthOf(ref('s')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3']);
    });

    test('set.toSet() returns an equal set', () async {
      expect(
        await evalPrint(
          lengthOf(
            call(
              'toSet',
              input: msg([
                field('self', setOf([1, 2])),
              ]),
            ),
          ),
        ),
        '2',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('List-block method-form + non-function + raw-List-arg arms', () {
    Map<String, dynamic> selfCall(
      String method,
      Map<String, dynamic> selfExpr, {
      List<Map<String, dynamic>> args = const [],
    }) => call(method, input: msg([field('self', selfExpr), ...args]));

    test('isEmpty / isNotEmpty called as methods on a list', () async {
      expect(await evalPrint(selfCall('isEmpty', listLit([]))), 'true');
      expect(await evalPrint(selfCall('isNotEmpty', intList([1]))), 'true');
    });

    test(
      'map / where with a non-function arg returns the list unchanged',
      () async {
        expect(
          await evalPrint(
            selfCall('map', intList([1, 2]), args: [field('arg0', literal(5))]),
          ),
          '[1, 2]',
        );
        expect(
          await evalPrint(
            selfCall(
              'where',
              intList([1, 2]),
              args: [field('arg0', literal(5))],
            ),
          ),
          '[1, 2]',
        );
      },
    );

    test('reduce on an empty list throws StateError', () async {
      final addFn = lambdaExpr(
        stdCall(
          'add',
          msg([field('left', ref('arg0')), field('right', ref('arg1'))]),
        ),
      );
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(selfCall('reduce', listLit([]), args: [field('arg0', addFn)])),
          ]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(isA<StateError>()));
    });

    test('filled as an instance method on a list', () async {
      expect(
        await evalPrint(
          selfCall(
            'filled',
            listLit([]),
            args: [field('arg0', literal(3)), field('arg1', literal(0))],
          ),
        ),
        '[0, 0, 0]',
      );
    });

    test('union / intersection / difference with a raw-List arg', () async {
      expect(
        await evalPrint(
          selfCall(
            'union',
            intList([1, 2]),
            args: [field('arg0', natCall('list'))],
          ),
        ),
        '[1, 2, 3, 4]',
      );
      expect(
        await evalPrint(
          selfCall(
            'intersection',
            intList([1, 2, 3]),
            args: [field('arg0', natCall('list'))],
          ),
        ),
        '[3]',
      );
      expect(
        await evalPrint(
          selfCall(
            'difference',
            intList([1, 2, 3]),
            args: [field('arg0', natCall('list'))],
          ),
        ),
        '[1, 2]',
      );
    });

    test('addAll with a raw-List arg unions in place', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('xs', intList([1, 2])),
            stmt(
              call(
                'addAll',
                input: msg([
                  field('self', ref('xs')),
                  field('arg0', natCall('list')),
                ]),
              ),
            ),
            stmt(printToString(ref('xs'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[1, 2, 3, 4]']);
    });

    test('followedBy with a raw-List arg', () async {
      expect(
        await evalPrint(
          selfCall(
            'followedBy',
            intList([1, 2]),
            args: [field('arg0', natCall('list'))],
          ),
        ),
        '[1, 2, 3, 4]',
      );
    });

    test(
      'expand: raw-List return, scalar return, and non-function arg',
      () async {
        // Lambda returns a native (raw) List → the `r is List` splice arm.
        expect(
          await evalPrint(
            selfCall(
              'expand',
              intList([1, 2]),
              args: [field('arg0', lambdaExpr(natCall('list')))],
            ),
          ),
          '[3, 4, 3, 4]',
        );
        // Lambda returns a scalar → the else (add r) arm.
        expect(
          await evalPrint(
            selfCall(
              'expand',
              intList([1, 2]),
              args: [field('arg0', lambdaExpr(ref('input')))],
            ),
          ),
          '[1, 2]',
        );
        // Non-function arg → returns the list unchanged.
        expect(
          await evalPrint(
            selfCall(
              'expand',
              intList([1, 2]),
              args: [field('arg0', literal(5))],
            ),
          ),
          '[1, 2]',
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  group(
    'wrapper-type receivers (BallString / BallInt) unwrap for dispatch',
    () {
      test('String method on a BallString receiver', () async {
        expect(
          await evalPrintStr(
            call('toUpperCase', input: msg([field('self', natCall('bstr'))])),
          ),
          'ABCD',
        );
      });

      test('num method on a BallInt receiver', () async {
        expect(
          await evalPrint(
            call('toDouble', input: msg([field('self', natCall('bint'))])),
          ),
          '5.0',
        );
      });
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  group(
    'native Dart Set instance methods (_dispatchBuiltinInstanceMethod)',
    () {
      Map<String, dynamic> setSelf(
        String method,
        String natFn, {
        List<Map<String, dynamic>> args = const [],
      }) => call(method, input: msg([field('self', natCall(natFn)), ...args]));

      test('length / isEmpty / isNotEmpty', () async {
        expect(await evalPrint(setSelf('length', 'set')), '3');
        expect(await evalPrint(setSelf('isEmpty', 'eset')), 'true');
        expect(await evalPrint(setSelf('isNotEmpty', 'set')), 'true');
      });

      test('contains / toList / toSet', () async {
        expect(
          await evalPrint(
            setSelf('contains', 'set', args: [field('arg0', literal(2))]),
          ),
          'true',
        );
        expect(await evalPrint(setSelf('toList', 'set')), '[1, 2, 3]');
        expect(await evalPrint(lengthOf(setSelf('toSet', 'set'))), '3');
      });

      test('union with a Set arg and with a List arg', () async {
        expect(
          await evalPrint(
            lengthOf(
              setSelf('union', 'set', args: [field('arg0', natCall('set2'))]),
            ),
          ),
          '4',
        );
        expect(
          await evalPrint(
            lengthOf(
              setSelf('union', 'set', args: [field('arg0', natCall('list'))]),
            ),
          ),
          '4',
        );
      });

      test('intersection with a Set arg and with a List arg', () async {
        expect(
          await evalPrint(
            lengthOf(
              setSelf(
                'intersection',
                'set',
                args: [field('arg0', natCall('set2'))],
              ),
            ),
          ),
          '2',
        );
        expect(
          await evalPrint(
            lengthOf(
              setSelf(
                'intersection',
                'set',
                args: [field('arg0', natCall('list'))],
              ),
            ),
          ),
          '1',
        );
      });

      test('difference with a Set arg and with a List arg', () async {
        expect(
          await evalPrint(
            lengthOf(
              setSelf(
                'difference',
                'set',
                args: [field('arg0', natCall('set2'))],
              ),
            ),
          ),
          '1',
        );
        expect(
          await evalPrint(
            lengthOf(
              setSelf(
                'difference',
                'set',
                args: [field('arg0', natCall('list'))],
              ),
            ),
          ),
          '2',
        );
      });

      test('add mutates a bound native set', () async {
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt('s', natCall('set')),
              stmt(
                call(
                  'add',
                  input: msg([
                    field('self', ref('s')),
                    field('arg0', literal(4)),
                  ]),
                ),
              ),
              stmt(printToString(lengthOf(ref('s')))),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['4']);
      });

      test('addAll(iterable) mutates a bound native set', () async {
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt('s', natCall('set')),
              stmt(
                call(
                  'addAll',
                  input: msg([
                    field('self', ref('s')),
                    field('arg0', natCall('list')),
                  ]),
                ),
              ),
              stmt(printToString(lengthOf(ref('s')))),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['4']);
      });

      test('remove mutates a bound native set', () async {
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt('s', natCall('set')),
              stmt(
                call(
                  'remove',
                  input: msg([
                    field('self', ref('s')),
                    field('arg0', literal(2)),
                  ]),
                ),
              ),
              stmt(printToString(lengthOf(ref('s')))),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['2']);
      });

      test('forEach over a native set', () async {
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(
                call(
                  'forEach',
                  input: msg([
                    field('self', natCall('set')),
                    field('arg0', lambdaExpr(printToString(ref('input')))),
                  ]),
                ),
              ),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['1', '2', '3']);
      });

      test('map over a native set returns a list', () async {
        final tenX = lambdaExpr(
          stdCall(
            'multiply',
            msg([field('left', ref('input')), field('right', literal(10))]),
          ),
        );
        expect(
          await evalPrint(setSelf('map', 'set', args: [field('arg0', tenX)])),
          '[10, 20, 30]',
        );
      });

      test('where over a native set returns a set', () async {
        final gtOne = lambdaExpr(
          stdCall(
            'greater_than',
            msg([field('left', ref('input')), field('right', literal(1))]),
          ),
        );
        expect(
          await evalPrint(
            lengthOf(setSelf('where', 'set', args: [field('arg0', gtOne)])),
          ),
          '2',
        );
        // `filter` shares the `where` arm (fall-through case label).
        expect(
          await evalPrint(
            lengthOf(setSelf('filter', 'set', args: [field('arg0', gtOne)])),
          ),
          '2',
        );
      });
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  group('null-aware / plain index assign on BallMap and raw Map targets', () {
    test('plain index assign on a BallMap: o["a"] = 9', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('o', natCall('bmap')),
            stmt(assign(idx(ref('o'), literal('a')), literal(9))),
            stmt(printToString(idx(ref('o'), literal('a')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['9']);
    });

    test('null-aware index assign on a BallMap (missing key)', () async {
      // o has no 'z' → current is null → RHS is evaluated and stored.
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('o', natCall('bmap')),
            stmt(assign(idx(ref('o'), literal('z')), literal(9), op: '??=')),
            stmt(printToString(idx(ref('o'), literal('z')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['9']);
    });

    test('null-aware index assign on a raw Map (missing key)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'mp',
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
            stmt(assign(idx(ref('mp'), literal('z')), literal(7), op: '??=')),
            stmt(printToString(idx(ref('mp'), literal('z')))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });

    test(
      'null-aware index assign on a non-indexable target (fallback)',
      () async {
        // Indexing a String with ??= matches no container arm → the final
        // fallback simply evaluates and returns the RHS.
        expect(
          await evalPrintStr(
            assign(idx(literal('abc'), literal(0)), literal('x'), op: '??='),
          ),
          'x',
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('StringBuffer + generic typed-object toString (map-methods block)', () {
    test('StringBuffer.writeln then toString', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('sb', natCall('sbuf')),
            stmt(
              call(
                'writeln',
                input: msg([
                  field('self', ref('sb')),
                  field('arg0', literal('x')),
                ]),
              ),
            ),
            stmt(
              printExpr(
                call('toString', input: msg([field('self', ref('sb'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['hix\n']);
    });

    test('StringBuffer.length', () async {
      expect(
        await evalPrint(
          call('length', input: msg([field('self', natCall('sbuf'))])),
        ),
        '2',
      );
    });

    test('StringBuffer.clear empties the buffer', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('sb', natCall('sbuf')),
            stmt(call('clear', input: msg([field('self', ref('sb'))]))),
            stmt(
              printExpr(
                call('toString', input: msg([field('self', ref('sb'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['']);
    });

    test('generic toString on a non-StringBuffer typed object', () async {
      // typeName 'Foo' (not StringBuffer) → the generic-toString arm.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                call(
                  'toString',
                  input: msg([field('self', natCall('typedobj'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      final out = await runAndCapture(program);
      expect(out, hasLength(1));
      expect(out.single, isNotEmpty);
    });
  });
}
