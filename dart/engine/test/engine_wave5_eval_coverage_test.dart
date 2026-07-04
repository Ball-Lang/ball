// Wave-5 coverage tests for engine_eval.dart — the tree-walking interpreter's
// core expression evaluator (part of 'engine.dart').
//
// These build real Ball `Program`s (proto3-JSON) and run them through
// `BallEngine`, asserting on captured stdout (or a thrown BallRuntimeError),
// mirroring the house style in engine_tail_coverage_test.dart. They target the
// harder-to-reach branches in engine_eval.dart that the main suite and other
// *_coverage_test.dart files miss: nested generic type-ref stringification,
// ordered-set virtual getters (first/last/single + empty throws), class-ref /
// builtin-class-ref field-access dispatch (static methods, named ctors),
// instance-method `__methods__` dispatch, messageCreation-as-callable
// resolution (top-level fn / method-on-self / cross-module scan), collection
// comprehension error paths, bytes literals, empty statements, lambda return
// flow, and Map-typed `let` coercion from an empty set/list.
//
// Self-contained builder helpers (kept independent of engine_test.dart), copied
// from engine_tail_coverage_test.dart's conventions.
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

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

const _stdFnNames = <String>[
  'print',
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
  'to_string',
  'if',
  'for',
  'for_in',
  'while',
  'do_while',
  'return',
  'break',
  'continue',
  'assign',
  'string_interpolation',
  'pre_increment',
  'pre_decrement',
  'post_increment',
  'post_decrement',
  'to_double',
  'to_int',
  'index',
  'switch',
  'switch_expr',
  'try',
  'throw',
  'yield',
  'yield_each',
  'cascade',
  'null_aware_cascade',
  'record',
  'spread',
  'null_spread',
  'collection_for',
  'collection_if',
  'invoke',
  'tear_off',
  'paren',
  'symbol',
  'type_literal',
  'null_coalesce',
  'assert',
  'list_push',
  'list_get',
  'list_length',
  'list_foreach',
  'list_map',
  'list_join',
  'list_slice',
  'list_flat_map',
  'list_to_list',
  'map_create',
  'map_get',
  'map_set',
  'map_keys',
  'map_values',
  'map_entries',
  'map_contains_key',
  'map_contains_value',
  'map_delete',
  'map_put_if_absent',
  'map_length',
  'map_is_empty',
  'set_create',
  'set_add',
  'set_contains',
  'set_length',
  'string_join',
  'string_is_empty',
  'string_runes',
  'string_split',
  'is',
  'is_not',
  'math_clamp',
  'math_pow',
  'json_encode',
  'json_decode',
  'print_error',
  'env_get',
  'args_get',
  'exit',
  'panic',
  'dart_list_generate',
  'dart_list_filled',
  'dart_await_for',
];

Map<String, dynamic> _stdModule({
  List<Map<String, dynamic>> extra = const [],
}) => {
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
    ...extra,
  ],
};

Program buildProgram({
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> typeDefs = const [],
  List<Map<String, dynamic>> enums = const [],
  List<Map<String, dynamic>> extraStdFunctions = const [],
  List<Map<String, dynamic>> extraModules = const [],
}) {
  final mainModule = <String, dynamic>{
    'name': 'main',
    'functions': functions,
    if (typeDefs.isNotEmpty) 'typeDefs': typeDefs,
    if (enums.isNotEmpty) 'enums': enums,
  };
  final programJson = {
    'name': 'test',
    'version': '1.0.0',
    'modules': [
      _stdModule(extra: extraStdFunctions),
      mainModule,
      ...extraModules,
    ],
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
  Map<String, dynamic>? metadata,
}) {
  final mc = <String, dynamic>{'typeName': typeName, 'fields': fields};
  if (metadata != null) mc['metadata'] = metadata;
  return {'messageCreation': mc};
}

Map<String, dynamic> field(String name, Map<String, dynamic> value) => {
  'name': name,
  'value': value,
};

Map<String, dynamic> fieldAcc(Map<String, dynamic> object, String name) => {
  'fieldAccess': {'object': object, 'field': name},
};

Map<String, dynamic> listLit(List<Map<String, dynamic>> elements) => {
  'literal': {
    'listValue': {'elements': elements},
  },
};

Map<String, dynamic> lambdaExpr(Map<String, dynamic> body) => {
  'lambda': {'name': '', 'inputType': 'dynamic', 'body': body},
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

Future<String> evalPrint(Map<String, dynamic> expr) async {
  final program = buildProgram(
    functions: [
      mainFn([stmt(printToString(expr))]),
    ],
  );
  final lines = await runAndCapture(program);
  return lines.single;
}

void main() {
  group('generic type-ref stringification (_typeRefValueToString)', () {
    // A typeDef-less, function-less messageCreation lands in the BallMap
    // fallthrough (engine_eval ~1492), where __type_args__ is derived from the
    // metadata.type_args struct. A nested generic + nullable ref exercises the
    // args/nullable branches of _typeRefValueToString (lines 42-50).
    test('nested generic + nullable metadata type_args → List<int>?', () async {
      final boxed = msg(
        [field('value', literal(1))],
        typeName: 'Box',
        metadata: {
          'type_args': [
            {
              'name': 'List',
              'type_args': ['int'],
              'nullable': true,
            },
          ],
        },
      );
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('b', boxed),
            stmt(printToString(fieldAcc(ref('b'), '__type_args__'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[List<int>?]']);
    });

    test('generic-in-typeName (Pair<int, String>) splits type args', () async {
      final paired = msg([
        field('first', literal(1)),
      ], typeName: 'Pair<int, String>');
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('p', paired),
            stmt(printToString(fieldAcc(ref('p'), '__type__'))),
            stmt(printToString(fieldAcc(ref('p'), '__type_args__'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['Pair', '[int, String]']);
    });
  });

  group('ordered-set virtual getters (engine_eval field access)', () {
    Map<String, dynamic> setOf(List<int> xs) => stdCall(
      'set_create',
      msg([
        field('elements', listLit([for (final x in xs) literal(x)])),
      ]),
    );

    test('set .first / .last / .single', () async {
      expect(await evalPrint(fieldAcc(setOf([7, 8, 9]), 'first')), '7');
      expect(await evalPrint(fieldAcc(setOf([7, 8, 9]), 'last')), '9');
      expect(await evalPrint(fieldAcc(setOf([42]), 'single')), '42');
    });

    test('set .first on empty set throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(setOf([]), 'first')))]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('set .last on empty set throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(setOf([]), 'last')))]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('set .single on non-singleton throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printToString(fieldAcc(setOf([1, 2]), 'single'))),
          ]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });
  });

  group('field-access error paths (engine_eval)', () {
    test('missing field on a map throws with Available list', () async {
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
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(m, 'nope')))]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('unknown field on a primitive int throws', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal(5), 'zzz')))]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });
  });

  group('class-ref field access: static method + named ctor (engine_eval)', () {
    // Widget has a static method + a named ctor but NO unnamed `.new`, so a bare
    // `ref('Widget')` resolves to the `__class__` namespace map (not a ctor
    // tear-off), letting fieldAccess exercise the static/named-ctor branches
    // (876-901). Binding the tear-off then invoking it also hits the
    // local-closure invoke path (196-198).
    List<Map<String, dynamic>> widgetFns(
      List<Map<String, dynamic>> mainStmts,
    ) => [
      {
        'name': 'main:Widget.make',
        'metadata': {'kind': 'static_method', 'class': 'Widget'},
        'body': blockExpr([], result: literal(42)),
      },
      {
        'name': 'main:Widget.origin',
        'metadata': {'kind': 'constructor', 'class': 'Widget'},
        'body': blockExpr([], result: literal('origin-made')),
      },
      mainFn(mainStmts),
    ];
    final widgetTypeDefs = [
      {
        'name': 'main:Widget',
        'descriptor': {'name': 'Widget', 'field': []},
      },
    ];

    test('Widget.make static tear-off invoked returns 42', () async {
      final program = buildProgram(
        functions: widgetFns([
          letStmt('mk', fieldAcc(ref('Widget'), 'make')),
          stmt(printToString(call('mk'))),
        ]),
        typeDefs: widgetTypeDefs,
      );
      expect(await runAndCapture(program), ['42']);
    });

    test('Widget.origin named-ctor tear-off invoked runs its body', () async {
      // Invoking the named-ctor tear-off runs the closure body (887-888); a
      // `kind: constructor` function returns its self-shell instance, so assert
      // the constructed instance surfaces rather than the block result.
      final program = buildProgram(
        functions: widgetFns([
          letStmt('o', fieldAcc(ref('Widget'), 'origin')),
          stmt(printToString(call('o'))),
        ]),
        typeDefs: widgetTypeDefs,
      );
      final lines = await runAndCapture(program);
      expect(lines.single, contains('main:Widget'));
    });

    test('unknown member on class-ref throws', () async {
      final program = buildProgram(
        functions: widgetFns([
          stmt(printToString(fieldAcc(ref('Widget'), 'nonesuch'))),
        ]),
        typeDefs: widgetTypeDefs,
      );
      await expectLater(runAndCapture(program), throwsA(isA<Object>()));
    });
  });

  group('builtin-class-ref field access closure (engine_eval)', () {
    // `List.filled` as a fieldAccess on the `List` builtin-class ref yields a
    // dispatch closure (859-866); invoking it runs the builtin static method.
    test('List.filled tear-off invoked builds a filled list', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('g', fieldAcc(ref('List'), 'filled')),
            stmt(
              printToString(
                call(
                  'g',
                  input: msg([
                    field('arg0', literal(3)),
                    field('arg1', literal(0)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[0, 0, 0]']);
    });

    test('unknown builtin static via tear-off throws (871)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('bad', fieldAcc(ref('List'), 'noSuchStatic')),
            stmt(
              printToString(
                call('bad', input: msg([field('arg0', literal(1))])),
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

  group('instance method __methods__ dispatch (engine_eval)', () {
    // Calling a method via the self-input call form on a BallObject dispatches
    // through the selfMap['__methods__'] walk (249-255).
    test('method call via self-input form returns method result', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'main:Animal.speak',
            'metadata': {'kind': 'method', 'class': 'Animal'},
            'body': blockExpr([], result: literal('woof')),
          },
          mainFn([
            letStmt('a', msg([], typeName: 'main:Animal')),
            stmt(
              printToString(
                call('speak', input: msg([field('self', ref('a'))])),
              ),
            ),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Animal',
            'descriptor': {'name': 'Animal', 'field': []},
          },
        ],
      );
      expect(await runAndCapture(program), ['woof']);
    });
  });

  group('bare field reference fallback on self (engine_eval)', () {
    // A method body referencing a bare field name (not self.x) resolves via the
    // `self` fallback: a direct own field (749-751) and an inherited super-chain
    // field (754-761). Base declares `legs` only via a metadata initializer, so
    // it lives on __super__, forcing the super-chain walk.
    test('own field + inherited field via bare references', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'main:Dog.describe',
            'metadata': {'kind': 'method', 'class': 'Dog'},
            // returns "sound=" + self.sound(own) then legs printed separately
            'body': blockExpr([
              stmt(printToString(ref('sound'))),
              stmt(printToString(ref('legs'))),
            ]),
          },
          mainFn([
            letStmt(
              'd',
              msg([field('sound', literal('bark'))], typeName: 'main:Dog'),
            ),
            stmt(call('describe', input: msg([field('self', ref('d'))]))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Animal',
            'descriptor': {'name': 'Animal', 'field': []},
            'metadata': {
              'fields': [
                {'name': 'legs', 'initializer': '4'},
              ],
            },
          },
          {
            'name': 'main:Dog',
            'descriptor': {
              'name': 'Dog',
              'field': [
                {
                  'name': 'sound',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_STRING',
                },
              ],
            },
            'metadata': {'superclass': 'Animal'},
          },
        ],
      );
      expect(await runAndCapture(program), ['bark', '4']);
    });
  });

  group('typeDef metadata-only fields + double-quote initializer', () {
    // A typeDef whose fields come from metadata (not the descriptor) exercises
    // _findTypeDef's metadata-fields collection (1602-1611) and _parseInitializer
    // with a double-quoted string literal (1689).
    test('metadata field with "double quoted" initializer', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('t', msg([], typeName: 'main:Thing')),
            stmt(printToString(fieldAcc(ref('t'), 'label'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Thing',
            'descriptor': {'name': 'Thing', 'field': []},
            'metadata': {
              'fields': [
                {'name': 'label', 'initializer': '"hi"'},
              ],
            },
          },
        ],
      );
      expect(await runAndCapture(program), ['hi']);
    });
  });

  group(
    'super object without parent typeDef (engine_eval _buildSuperObject)',
    () {
      // A subclass whose superclass has no typeDef makes _buildSuperObject take
      // its bare-super fallback (1782).
      test(
        'constructing a subclass of a typeDef-less super succeeds',
        () async {
          final program = buildProgram(
            functions: [
              mainFn([
                letStmt(
                  's',
                  msg([field('x', literal(1))], typeName: 'main:Sub'),
                ),
                stmt(printToString(fieldAcc(ref('s'), 'x'))),
              ]),
            ],
            typeDefs: [
              {
                'name': 'main:Sub',
                'descriptor': {
                  'name': 'Sub',
                  'field': [
                    {
                      'name': 'x',
                      'number': 1,
                      'label': 'LABEL_OPTIONAL',
                      'type': 'TYPE_INT64',
                    },
                  ],
                },
                'metadata': {'superclass': 'Ghost'},
              },
            ],
          );
          expect(await runAndCapture(program), ['1']);
        },
      );
    },
  );

  group('messageCreation resolving to a callable (engine_eval)', () {
    test('typeName names a top-level function', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'greet',
            'metadata': {'kind': 'function'},
            'body': blockExpr([], result: literal('greeted')),
          },
          mainFn([
            stmt(
              printToString(
                msg([field('arg0', literal(1))], typeName: 'greet'),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['greeted']);
    });

    test('typeName names a method on self (fnKey + self-type paths)', () async {
      final program = buildProgram(
        functions: [
          // helper: reached via fnKey 'main.main:Widget.helper' with self bound.
          {
            'name': 'main:Widget.helper',
            'metadata': {'kind': 'method', 'class': 'Widget'},
            'body': blockExpr([], result: literal('helped')),
          },
          // _priv: reached via self-type resolution (bare typeName '_priv').
          {
            'name': 'main:Widget._priv',
            'metadata': {'kind': 'method', 'class': 'Widget'},
            'body': blockExpr([], result: literal('private')),
          },
          // run drives both, as method bodies (self in scope).
          {
            'name': 'main:Widget.run',
            'metadata': {'kind': 'method', 'class': 'Widget'},
            'body': blockExpr([
              stmt(printToString(msg([], typeName: 'main:Widget.helper'))),
              stmt(printToString(msg([], typeName: '_priv'))),
            ]),
          },
          {
            'name': 'main:Widget.new',
            'metadata': {'kind': 'constructor', 'class': 'Widget'},
            'body': msg([], typeName: 'main:Widget'),
          },
          mainFn([
            letStmt('w', msg([], typeName: 'main:Widget')),
            stmt(call('run', input: msg([field('self', ref('w'))]))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Widget',
            'descriptor': {'name': 'Widget', 'field': []},
          },
        ],
      );
      expect(await runAndCapture(program), ['helped', 'private']);
    });

    test('typeName found by scanning another module (1552-1562)', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(msg([], typeName: 'compute')))]),
        ],
        extraModules: [
          {
            'name': 'util',
            'functions': [
              {
                'name': 'compute',
                'metadata': {'kind': 'function'},
                'body': blockExpr([], result: literal('computed')),
              },
            ],
          },
        ],
      );
      expect(await runAndCapture(program), ['computed']);
    });
  });

  group('constructor tear-off via module-prefixed reference (692-696)', () {
    test('extra-prefixed ref resolves to the Counter constructor', () async {
      // The constructor registers its bare key as the module-qualified name
      // `main:Counter`, so an extra prefix ("zz:main:Counter") forces the
      // colon-strip fallback (690-698) that a plain "main:Counter" would skip
      // (it resolves directly at 682).
      final program = buildProgram(
        functions: [
          {
            'name': 'main:Counter.new',
            'metadata': {
              'kind': 'constructor',
              'initializers': [
                {'kind': 'field', 'name': 'count', 'value': '0'},
              ],
            },
          },
          mainFn([
            letStmt('mk', ref('zz:main:Counter')),
            letStmt('c', call('mk')),
            stmt(printToString(fieldAcc(ref('c'), 'count'))),
          ]),
        ],
        typeDefs: [
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
      );
      expect(await runAndCapture(program), ['0']);
    });
  });

  group('list/map comprehension error + else paths (engine_eval)', () {
    Map<String, dynamic> collectionFor(List<Map<String, dynamic>> fields) =>
        stdCall('collection_for', msg(fields));

    test('list collection_for missing body throws (376)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'xs',
              listLit([
                collectionFor([
                  field('iterable', listLit([literal(1)])),
                ]),
              ]),
            ),
          ]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('list collection_for unrecognized shape throws (399)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'xs',
              listLit([
                collectionFor([field('body', literal(1))]),
              ]),
            ),
          ]),
        ],
      );
      await expectLater(
        runAndCapture(program),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('map comprehension collection_if else branch (573-575)', () async {
      // { if (false) 'a': 1 else 'b': 2 }  → {b: 2}
      final entry = (String k, int v) =>
          msg([field('key', literal(k)), field('value', literal(v))]);
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'm',
              stdCall(
                'map_create',
                msg([
                  field(
                    'element',
                    stdCall(
                      'collection_if',
                      msg([
                        field('condition', literal(false)),
                        field('then', entry('a', 1)),
                        field('else', entry('b', 2)),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
            stmt(printToString(ref('m'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['{b: 2}']);
    });

    test(
      'map comprehension collection_for missing body throws (589)',
      () async {
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt(
                'm',
                stdCall(
                  'map_create',
                  msg([
                    field(
                      'element',
                      stdCall(
                        'collection_for',
                        msg([
                          field('iterable', listLit([literal(1)])),
                        ]),
                      ),
                    ),
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
      },
    );

    test('map comprehension collection_for bad shape throws (609)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'm',
              stdCall(
                'map_create',
                msg([
                  field(
                    'element',
                    stdCall('collection_for', msg([field('body', literal(1))])),
                  ),
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

  group('lazy map_create eager fallback (485-488)', () {
    test(
      'map_create with a non-messageCreation input evals it eagerly',
      () async {
        // input is a block returning a {entries: [...]} message, not a bare
        // messageCreation, so _evalLazyMapCreate falls back to _stdMapCreate.
        final inner = msg([
          field(
            'entries',
            listLit([
              msg([field('key', literal('k')), field('value', literal(9))]),
            ]),
          ),
        ]);
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt('m', {
                'call': {
                  'module': 'std',
                  'function': 'map_create',
                  'input': blockExpr([], result: inner),
                },
              }),
              stmt(printToString(fieldAcc(ref('m'), 'k'))),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['9']);
      },
    );
  });

  group('duplicate messageCreation field names (1284-1292)', () {
    test('three same-named fields collapse to a list', () async {
      final dup = msg([
        field('item', literal(1)),
        field('item', literal(2)),
        field('item', literal(3)),
      ]);
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('m', dup),
            stmt(printToString(fieldAcc(ref('m'), 'item'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[1, 2, 3]']);
    });
  });

  group('Map-typed let coercion from empty set/list (1918-1922)', () {
    Map<String, dynamic> typedLet(String name, Map<String, dynamic> value) => {
      'let': {
        'name': name,
        'value': value,
        'metadata': {'keyword': 'var', 'type': 'Map<String, int>'},
      },
    };

    test('empty set literal coerces to empty map', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            typedLet('m', stdCall('set_create', msg([]))),
            stmt(printToString(ref('m'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['{}']);
    });
    // NOTE: the sibling `value is List && value.isEmpty` coercion (engine_eval
    // line 1921) is unreachable from a Ball list literal — those evaluate to a
    // BallList wrapper, never a raw Dart List — so it is intentionally not
    // covered here (see the report). The BallSet path above covers 1919-1920.
  });

  group('lambda return-flow, bytes, empty stmt, await_for (engine_eval)', () {
    test('lambda whose body returns via std.return (1980-1981)', () async {
      // list.map with a lambda whose block body contains an explicit return.
      final lam = lambdaExpr(
        blockExpr([
          stmt(stdCall('return', msg([field('value', literal(99))]))),
        ]),
      );
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                call(
                  'map',
                  input: msg([
                    field('self', listLit([literal(1), literal(2)])),
                    field('arg0', lam),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['[99, 99]']);
    });

    test('bytes literal length (316-318)', () async {
      final bytes = {
        'literal': {'bytesValue': 'AQID'}, // base64 of [1,2,3]
      };
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(bytes, 'length')))]),
        ],
      );
      expect(await runAndCapture(program), ['3']);
    });

    test('empty (notSet) statement is a no-op (1928-1929)', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'main',
            'body': {
              'block': {
                'statements': [
                  <String, dynamic>{},
                  stmt(printExpr(literal('ok'))),
                ],
              },
            },
          },
        ],
      );
      expect(await runAndCapture(program), ['ok']);
    });

    test('dart_await_for iterates like for_in (136)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'dart_await_for',
                msg([
                  field('variable', literal('x')),
                  field(
                    'iterable',
                    listLit([literal(1), literal(2), literal(3)]),
                  ),
                  field('body', printToString(ref('x'))),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1', '2', '3']);
    });

    test('empty (notSet) expression evaluates to null (75)', () async {
      // A messageCreation field value that is an empty Expression `{}` hits the
      // Expression_Expr.notSet arm of _evalExpression.
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(<String, dynamic>{}))]),
        ],
      );
      expect(await runAndCapture(program), ['null']);
    });
  });

  group('set virtual .length/.isEmpty/.isNotEmpty field access (842)', () {
    Map<String, dynamic> setOf(List<int> xs) => stdCall(
      'set_create',
      msg([
        field('elements', listLit([for (final x in xs) literal(x)])),
      ]),
    );
    test('length / isEmpty / isNotEmpty via fieldAccess', () async {
      expect(await evalPrint(fieldAcc(setOf([1, 2, 3]), 'length')), '3');
      expect(await evalPrint(fieldAcc(setOf([]), 'isEmpty')), 'true');
      expect(await evalPrint(fieldAcc(setOf([1]), 'isNotEmpty')), 'true');
    });
  });

  group('builtin-class tear-off with scalar input (864)', () {
    test(
      'scalar (non-map) input wraps as {arg0: ...} then dispatch throws',
      () async {
        // A non-map argument makes the closure build {arg0: input} (line 864);
        // dispatching an unknown static then throws.
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt('bad', fieldAcc(ref('List'), 'noSuchStatic')),
              stmt(printToString(call('bad', input: literal(1)))),
            ]),
          ],
        );
        await expectLater(
          runAndCapture(program),
          throwsA(isA<BallRuntimeError>()),
        );
      },
    );
  });

  group('top-level variable bare reference (778-779)', () {
    test('a top-level variable resolves from the global scope', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'greeting',
            'metadata': {'kind': 'top_level_variable'},
            'outputType': 'String',
            'body': blockExpr([], result: literal('hi')),
          },
          mainFn([stmt(printToString(ref('greeting')))]),
        ],
      );
      expect(await runAndCapture(program), ['hi']);
    });
  });

  group('single-param single-field constructor mapping (1357-1358)', () {
    test('lone param (name != field) maps to the lone field', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'main:Cell.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'v', 'type': 'int'},
              ],
            },
          },
          mainFn([
            letStmt(
              'c',
              msg([field('arg0', literal(7))], typeName: 'main:Cell'),
            ),
            stmt(printToString(fieldAcc(ref('c'), 'value'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Cell',
            'descriptor': {
              'name': 'Cell',
              'field': [
                {
                  'name': 'value',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
          },
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });
  });

  group('metadata type_args on a typeDef instance (1392-1395)', () {
    test('typeDef instance records __type_args__ from metadata', () async {
      final boxed = msg(
        [field('value', literal(1))],
        typeName: 'main:Box2',
        metadata: {
          'type_args': ['int'],
        },
      );
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('b', boxed),
            stmt(printToString(fieldAcc(ref('b'), '__type_args__'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Box2',
            'descriptor': {
              'name': 'Box2',
              'field': [
                {
                  'name': 'value',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
          },
        ],
      );
      expect(await runAndCapture(program), ['[int]']);
    });
  });

  group('constructor without a typeDef (1454-1489)', () {
    // A class that has a constructor but NO typeDef exercises the ctor-only
    // fallback in _evalMessageCreation (1454-1489). NOTE: the produced instance
    // carries __type__ but its explicit fields are dropped by this path (see the
    // report's flagged quirk), so we assert on the instance type, not a field.
    test(
      'messageCreation of a ctor-only class builds a typed instance',
      () async {
        final program = buildProgram(
          functions: [
            {
              'name': 'main:Gadget.new',
              'metadata': {'kind': 'constructor'},
            },
            mainFn([
              letStmt(
                'g',
                msg(
                  [field('color', literal('red'))],
                  typeName: 'main:Gadget',
                  metadata: {
                    'type_args': ['int'],
                  },
                ),
              ),
              stmt(printToString(ref('g'))),
            ]),
          ],
        );
        final lines = await runAndCapture(program);
        expect(lines.single, contains('main:Gadget'));
      },
    );
  });

  group('inherited getter via super chain (1116-1133)', () {
    test('grandparent getter resolves through two super levels', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'main:A.tag',
            'metadata': {'kind': 'method', 'is_getter': true, 'class': 'A'},
            'body': blockExpr([], result: literal('A-tag')),
          },
          mainFn([
            letStmt('c', msg([], typeName: 'main:C')),
            stmt(printToString(fieldAcc(ref('c'), 'tag'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:A',
            'descriptor': {'name': 'A', 'field': []},
          },
          {
            'name': 'main:B',
            'descriptor': {'name': 'B', 'field': []},
            'metadata': {'superclass': 'A'},
          },
          {
            'name': 'main:C',
            'descriptor': {'name': 'C', 'field': []},
            'metadata': {'superclass': 'B'},
          },
        ],
      );
      expect(await runAndCapture(program), ['A-tag']);
    });
  });

  group('inherited setter via super chain (_trySetterDispatch 1204-1217)', () {
    test('grandparent setter resolves through two super levels', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'main:A.prop',
            'metadata': {
              'kind': 'method',
              'is_setter': true,
              'class': 'A',
              'params': [
                {'name': 'value', 'type': 'int'},
              ],
            },
            'body': blockExpr([], result: ref('value')),
          },
          mainFn([
            letStmt('c', msg([], typeName: 'main:C')),
            stmt(
              printToString(
                stdCall(
                  'assign',
                  msg([
                    field('target', fieldAcc(ref('c'), 'prop')),
                    field('value', literal(9)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:A',
            'descriptor': {'name': 'A', 'field': []},
          },
          {
            'name': 'main:B',
            'descriptor': {'name': 'B', 'field': []},
            'metadata': {'superclass': 'A'},
          },
          {
            'name': 'main:C',
            'descriptor': {'name': 'C', 'field': []},
            'metadata': {'superclass': 'B'},
          },
        ],
      );
      expect(await runAndCapture(program), ['9']);
    });
  });

  group(
    'inherited field assignment syncs to super (_syncFieldToSelf 1262-1266)',
    () {
      test(
        'assigning a bare inherited field name mirrors onto __super__',
        () async {
          final program = buildProgram(
            functions: [
              {
                'name': 'main:Derived.bump',
                'metadata': {'kind': 'method', 'class': 'Derived'},
                'body': blockExpr([
                  stmt(
                    stdCall(
                      'assign',
                      msg([
                        field('target', ref('count')),
                        field('value', literal(5)),
                      ]),
                    ),
                  ),
                ]),
              },
              mainFn([
                letStmt('d', msg([], typeName: 'main:Derived')),
                stmt(call('bump', input: msg([field('self', ref('d'))]))),
                stmt(printToString(fieldAcc(ref('d'), 'count'))),
              ]),
            ],
            typeDefs: [
              {
                'name': 'main:Base',
                'descriptor': {
                  'name': 'Base',
                  'field': [
                    {
                      'name': 'count',
                      'number': 1,
                      'label': 'LABEL_OPTIONAL',
                      'type': 'TYPE_INT64',
                    },
                  ],
                },
                'metadata': {
                  'fields': [
                    {'name': 'count', 'initializer': '0'},
                  ],
                },
              },
              {
                'name': 'main:Derived',
                'descriptor': {'name': 'Derived', 'field': []},
                'metadata': {'superclass': 'Base'},
              },
            ],
          );
          expect(await runAndCapture(program), ['5']);
        },
      );
    },
  );
}
