// Wave-5 miscellaneous tail-coverage for the engine `lib/` product code.
//
// Targets the object-oriented machinery and a handful of stray fallbacks that
// the other wave-5 files and engine_test.dart do not reach:
//   • engine.dart          — _consumeGeneratorFlow (FlowSignal yield path),
//                            the default `stderr` sink, the *runtime*
//                            expression-depth guard, the method-inheritance
//                            dispatch table (_resolveInstanceMethodDispatch /
//                            _lookupTypeMethodWithInheritance) and the
//                            Map-typed top-level-var empty-list coercion.
//   • engine_invocation.dart — the typeDef-based (_callObjectConstructor) and
//                            typeDef-less (_buildConstructorInstance)
//                            constructor flows, _applyConstructorInitializers
//                            (every literal kind), _invokeSuperConstructor
//                            (explicit + default super, all arg token kinds),
//                            and the lazy module-resolver path.
//   • engine_types.dart    — _ballToDouble's non-numeric fallback and the
//                            map_keys/map_values non-map fallbacks.
//
// Kept self-contained (does not import engine_test.dart helpers), mirroring the
// engine_tail_coverage_test.dart house style.
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:ball_resolver/ball_resolver.dart';
import 'package:test/test.dart';

// ── Self-contained builders ──────────────────────────────────────────────

Future<List<String>> runAndCapture(
  Program program, {
  ModuleResolver? resolver,
}) async {
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add, resolver: resolver);
  await engine.run();
  return lines;
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

Map<String, dynamic> fieldAcc(Map<String, dynamic> object, String name) => {
  'fieldAccess': {'object': object, 'field': name},
};

Map<String, dynamic> blockExpr(
  List<Map<String, dynamic>> statements, {
  Map<String, dynamic>? result,
}) {
  final b = <String, dynamic>{'statements': statements};
  if (result != null) b['result'] = result;
  return {'block': b};
}

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

Map<String, dynamic> printExpr(Map<String, dynamic> value) =>
    stdCall('print', msg([field('message', value)], typeName: 'PrintInput'));

Map<String, dynamic> printToString(Map<String, dynamic> expr) =>
    printExpr(stdCall('to_string', msg([field('value', expr)])));

Map<String, dynamic> stdModule(List<String> names) => {
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
    for (final n in names) {'name': n, 'isBase': true},
  ],
};

Program program({
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> typeDefs = const [],
  List<Map<String, dynamic>> moduleImports = const [],
  List<Map<String, dynamic>> extraModules = const [],
  List<String> std = const ['print', 'to_string', 'string_interpolation'],
}) {
  final main = <String, dynamic>{'name': 'main', 'functions': functions};
  if (typeDefs.isNotEmpty) main['typeDefs'] = typeDefs;
  if (moduleImports.isNotEmpty) main['moduleImports'] = moduleImports;
  final json = {
    'name': 'test',
    'version': '1.0.0',
    'modules': [stdModule(std), main, ...extraModules],
    'entryModule': 'main',
    'entryFunction': 'main',
  };
  return Program()..mergeFromProto3Json(json);
}

Future<String> evalPrint(
  Map<String, dynamic> expr, {
  List<String> std = const ['print', 'to_string'],
}) async {
  final p = program(
    functions: [
      mainFn([stmt(printToString(expr))]),
    ],
    std: std,
  );
  final lines = await runAndCapture(p);
  return lines.single;
}

void main() {
  group('_consumeGeneratorFlow FlowSignal path (engine.dart)', () {
    // A sync* generator that yields via BARE (module-unqualified) `yield`
    // calls. Unlike `std.yield`, an unqualified `yield` is not intercepted by
    // _evalCall's std control-flow switch, so it dispatches through the std
    // handler that returns a `_FlowSignal`, which _consumeGeneratorFlow then
    // collects into the active generator.
    test(
      'bare yield / yield_each collected via _consumeGeneratorFlow',
      () async {
        final p = program(
          std: ['print', 'to_string', 'yield', 'yield_each'],
          functions: [
            {
              'name': 'gen',
              'metadata': {'kind': 'function', 'is_sync_star': true},
              'body': blockExpr([
                stmt(call('yield', input: msg([field('value', literal(1))]))),
                stmt(call('yield', input: msg([field('value', literal(2))]))),
                stmt(
                  call(
                    'yield_each',
                    input: msg([
                      field('value', listLit([literal(3), literal(4)])),
                    ]),
                  ),
                ),
              ]),
            },
            mainFn([stmt(printToString(call('gen')))]),
          ],
        );
        expect(await runAndCapture(p), ['[1, 2, 3, 4]']);
      },
    );
  });

  group('default stderr sink (engine.dart)', () {
    test('print_error routes through the default io.stderr closure', () async {
      // Construct without a `stderr:` callback so the default
      // `((s) => io.stderr.writeln(s))` closure is exercised when print_error
      // writes. (Output goes to the real stderr; we only assert stdout stays
      // empty and no exception is thrown.)
      final p = program(
        std: ['print', 'print_error'],
        functions: [
          mainFn([
            stmt(
              stdCall(
                'print_error',
                msg([field('message', literal('wave5-misc-stderr'))]),
              ),
            ),
          ]),
        ],
      );
      final lines = <String>[];
      final engine = BallEngine(p, stdout: lines.add);
      await engine.run();
      expect(lines, isEmpty);
    });
  });

  group('runtime expression-depth guard (engine.dart)', () {
    test('deep recursion trips _checkExpressionDepth', () async {
      // `loop` recurses unconditionally. Its static body depth is tiny (passes
      // construction-time validation) but the *runtime* expression depth grows
      // per recursion level, tripping the runtime guard well before the
      // recursion-depth limit.
      final p = program(
        std: ['print'],
        functions: [
          {'name': 'loop', 'body': call('loop')},
          mainFn([stmt(call('loop'))]),
        ],
      );
      final engine = BallEngine(p, stdout: (_) {}, maxExpressionDepth: 150);
      await expectLater(
        engine.run(),
        throwsA(
          isA<BallRuntimeError>().having(
            (e) => e.message,
            'message',
            contains('too deep'),
          ),
        ),
      );
    });
  });

  group('Map-typed top-level var empty-list coercion (engine.dart)', () {
    test(
      'empty raw-list initializer for a Map field becomes an empty map',
      () async {
        // The initializer evaluates to a raw (Dart) empty List — map_values of an
        // empty map returns `[]` — which the Map-typed top-level coercion rewrites
        // into an empty ordered map.
        final p = program(
          std: ['print', 'to_string', 'map_create', 'map_values'],
          functions: [
            {
              'name': 'registry',
              'outputType': 'Map<String, int>',
              'metadata': {'kind': 'top_level_variable'},
              'body': stdCall(
                'map_values',
                msg([
                  field(
                    'map',
                    stdCall('map_create', msg([field('entries', listLit([]))])),
                  ),
                ]),
              ),
            },
            mainFn([stmt(printToString(ref('registry')))]),
          ],
        );
        expect(await runAndCapture(p), ['{}']);
      },
    );
  });

  group('_ballToDouble non-numeric fallback (engine_types.dart)', () {
    test('to_double of a String returns 0.0', () async {
      expect(
        await evalPrint(
          stdCall('to_double', msg([field('value', literal('abc'))])),
          std: ['print', 'to_string', 'to_double'],
        ),
        '0.0',
      );
    });
    test('int_to_double of a bool returns 0.0', () async {
      expect(
        await evalPrint(
          stdCall('int_to_double', msg([field('value', literal(true))])),
          std: ['print', 'to_string', 'int_to_double'],
        ),
        '0.0',
      );
    });
  });

  group('map_keys/map_values non-map fallback (engine_types.dart)', () {
    test('map_keys on a non-map value returns []', () async {
      expect(
        await evalPrint(
          stdCall('map_keys', msg([field('map', literal(5))])),
          std: ['print', 'to_string', 'map_keys'],
        ),
        '[]',
      );
    });
    test('map_values on a non-map value returns []', () async {
      expect(
        await evalPrint(
          stdCall('map_values', msg([field('map', literal(5))])),
          std: ['print', 'to_string', 'map_values'],
        ),
        '[]',
      );
    });
    test(
      'map_contains_key on a non-map value throws (inconsistency)',
      () async {
        // Documents that map_contains_key FAILS LOUD on a non-map while
        // map_keys/map_values silently return [] (see report).
        final p = program(
          std: ['print', 'to_string', 'map_contains_key'],
          functions: [
            mainFn([
              stmt(
                printToString(
                  stdCall(
                    'map_contains_key',
                    msg([field('map', literal(5)), field('key', literal(1))]),
                  ),
                ),
              ),
            ]),
          ],
        );
        await expectLater(runAndCapture(p), throwsA(isA<BallRuntimeError>()));
      },
    );
  });

  group(
    'async internal-error rethrow via _unwrapBallFuture (engine_types)',
    () {
      // An async function whose body throws a BallRuntimeError internally: the
      // error is captured into a BallFutureError, then rethrown by
      // _unwrapBallFuture when the result is awaited.
      Map<String, dynamic> tryCatchPrint(Map<String, dynamic> body) => stdCall(
        'try',
        msg([
          field('body', body),
          field(
            'catches',
            listLit([
              msg([
                field('variable', literal('e')),
                field('body', printExpr(ref('e'))),
              ]),
            ]),
          ),
        ]),
      );

      test('await rethrows a BallRuntimeError from an async body', () async {
        final p = program(
          std: ['print', 'to_string', 'try', 'dart_await', 'map_contains_key'],
          functions: [
            {
              'name': 'boom',
              'metadata': {'kind': 'function', 'is_async': true},
              'body': blockExpr([
                stmt(
                  stdCall(
                    'map_contains_key',
                    msg([field('map', literal(5)), field('key', literal(1))]),
                  ),
                ),
              ]),
            },
            mainFn([
              stmt(
                tryCatchPrint(
                  stdCall('dart_await', msg([field('value', call('boom'))])),
                ),
              ),
            ]),
          ],
        );
        final lines = await runAndCapture(p);
        expect(lines.single, contains('expected Map or Set'));
      });

      test(
        'await wraps + rethrows a raw Dart error from an async body',
        () async {
          final p = program(
            std: ['print', 'to_string', 'try', 'dart_await', 'list_get'],
            functions: [
              {
                'name': 'boom',
                'metadata': {'kind': 'function', 'is_async': true},
                'body': blockExpr([
                  stmt(
                    stdCall(
                      'list_get',
                      msg([
                        field('list', listLit([literal(0)])),
                        field('index', literal(5)),
                      ]),
                    ),
                  ),
                ]),
              },
              mainFn([
                stmt(
                  tryCatchPrint(
                    stdCall('dart_await', msg([field('value', call('boom'))])),
                  ),
                ),
              ]),
            ],
          );
          final lines = await runAndCapture(p);
          expect(lines.single, contains('RangeError'));
        },
      );
    },
  );

  group('method-inheritance dispatch table (engine.dart)', () {
    // Methods named `Type.method` (dotted, no `class` metadata) register into
    // _typeMethodDispatch but are NOT collected into an instance's __methods__
    // (which only matches by `class` metadata or an exact bare-name pattern) and
    // are missed by _resolveMethod's qualified-key probe — so dispatch falls
    // through to _resolveInstanceMethodDispatch, which walks the superclass
    // chain / mixins via _lookupTypeMethodWithInheritance.

    test(
      'inherited method resolved via superclass chain (qualified type)',
      () async {
        // __type__ carries the module-qualified 'main:Dog' so the colon-branch of
        // _lookupTypeMethodWithInheritance (modPart substring) is exercised. Call
        // twice so the second hit returns from _instanceMethodCache.
        final p = program(
          std: ['print', 'to_string'],
          functions: [
            {'name': 'Animal.speak', 'body': literal('animal-speaks')},
            mainFn([
              letStmt('d', msg([], typeName: 'main:Dog')),
              stmt(
                printToString(
                  call('speak', input: msg([field('self', ref('d'))])),
                ),
              ),
              stmt(
                printToString(
                  call('speak', input: msg([field('self', ref('d'))])),
                ),
              ),
            ]),
          ],
          typeDefs: [
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
        );
        expect(await runAndCapture(p), ['animal-speaks', 'animal-speaks']);
      },
    );

    test('method resolved via mixin (bare type)', () async {
      // __type__ is the bare 'Robot' (no colon) so the modPart falls back to the
      // current module, and resolution succeeds only through the mixin branch.
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {'name': 'Walkable.walk', 'body': literal('robot-walks')},
          mainFn([
            letStmt('r', msg([], typeName: 'Robot')),
            stmt(
              printToString(
                call('walk', input: msg([field('self', ref('r'))])),
              ),
            ),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Walkable',
            'descriptor': {'name': 'Walkable', 'field': []},
          },
          {
            'name': 'main:Robot',
            'descriptor': {'name': 'Robot', 'field': []},
            'metadata': {
              'mixins': ['Walkable'],
            },
          },
        ],
      );
      expect(await runAndCapture(p), ['robot-walks']);
    });
  });

  group('typeDef constructor with super() (engine_invocation.dart)', () {
    // Base.new / Derived.new both have bodies -> _callObjectConstructor.
    // Derived.new forwards an explicit super() whose arg tokens cover every
    // literal branch of _invokeSuperConstructor: string, int, double, true,
    // false. An unsupplied `opt` param exercises the default-value path.
    List<Map<String, dynamic>> baseFields() => [
      {
        'name': 'a',
        'number': 1,
        'label': 'LABEL_OPTIONAL',
        'type': 'TYPE_STRING',
      },
      {
        'name': 'b',
        'number': 2,
        'label': 'LABEL_OPTIONAL',
        'type': 'TYPE_INT64',
      },
      {
        'name': 'c',
        'number': 3,
        'label': 'LABEL_OPTIONAL',
        'type': 'TYPE_DOUBLE',
      },
      {
        'name': 'd',
        'number': 4,
        'label': 'LABEL_OPTIONAL',
        'type': 'TYPE_BOOL',
      },
      {
        'name': 'e',
        'number': 5,
        'label': 'LABEL_OPTIONAL',
        'type': 'TYPE_BOOL',
      },
    ];

    test('explicit super() forwards string/int/double/bool tokens', () async {
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {
            'name': 'Base.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'a', 'is_this': true},
                {'name': 'b', 'is_this': true},
                {'name': 'c', 'is_this': true},
                {'name': 'd', 'is_this': true},
                {'name': 'e', 'is_this': true},
              ],
            },
            'body': blockExpr([]),
          },
          {
            'name': 'Derived.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'own', 'is_this': true},
                {'name': 'opt', 'is_this': true, 'default_value': 99},
              ],
              'initializers': [
                {'kind': 'super', 'args': "('hi', 42, 3.5, true, false)"},
              ],
            },
            'body': blockExpr([]),
          },
          mainFn([
            letStmt(
              'o',
              call('Derived', input: msg([field('own', literal(7))])),
            ),
            stmt(printToString(fieldAcc(ref('o'), 'own'))),
            stmt(printToString(fieldAcc(ref('o'), 'opt'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Base',
            'descriptor': {'name': 'Base', 'field': baseFields()},
          },
          {
            'name': 'main:Derived',
            'descriptor': {
              'name': 'Derived',
              'field': [
                {
                  'name': 'own',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
                {
                  'name': 'opt',
                  'number': 2,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
            'metadata': {'superclass': 'Base'},
          },
        ],
      );
      expect(await runAndCapture(p), ['7', '99']);
    });

    test('default super() (no initializer) forwards resolved params', () async {
      // Derived2.new has no explicit super() -> the default-super branch of
      // _invokeSuperConstructor forwards all resolved params to Base2.new.
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {
            'name': 'Base2.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'x', 'is_this': true},
              ],
            },
            'body': blockExpr([]),
          },
          {
            'name': 'Derived2.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'x', 'is_this': true},
              ],
            },
            'body': blockExpr([]),
          },
          mainFn([
            letStmt(
              'o',
              call('Derived2', input: msg([field('x', literal(5))])),
            ),
            stmt(printToString(fieldAcc(ref('o'), 'x'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Base2',
            'descriptor': {
              'name': 'Base2',
              'field': [
                {
                  'name': 'x',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
          },
          {
            'name': 'main:Derived2',
            'descriptor': {
              'name': 'Derived2',
              'field': [
                {
                  'name': 'x',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
            'metadata': {'superclass': 'Base2'},
          },
        ],
      );
      expect(await runAndCapture(p), ['5']);
    });

    test(
      'superclass without a constructor uses _buildSuperObject fallback',
      () async {
        // Base3 has a typeDef but NO constructor, so _invokeSuperConstructor
        // returns null and _callObjectConstructor falls back to _buildSuperObject.
        final p = program(
          std: ['print', 'to_string'],
          functions: [
            {
              'name': 'Derived3.new',
              'metadata': {
                'kind': 'constructor',
                'params': [
                  {'name': 'own', 'is_this': true},
                ],
              },
              'body': blockExpr([]),
            },
            mainFn([
              letStmt(
                'o',
                call('Derived3', input: msg([field('own', literal(3))])),
              ),
              stmt(printToString(fieldAcc(ref('o'), 'own'))),
            ]),
          ],
          typeDefs: [
            {
              'name': 'main:Base3',
              'descriptor': {
                'name': 'Base3',
                'field': [
                  {
                    'name': 'label',
                    'number': 1,
                    'label': 'LABEL_OPTIONAL',
                    'type': 'TYPE_STRING',
                  },
                ],
              },
            },
            {
              'name': 'main:Derived3',
              'descriptor': {
                'name': 'Derived3',
                'field': [
                  {
                    'name': 'own',
                    'number': 1,
                    'label': 'LABEL_OPTIONAL',
                    'type': 'TYPE_INT64',
                  },
                ],
              },
              'metadata': {'superclass': 'Base3'},
            },
          ],
        );
        expect(await runAndCapture(p), ['3']);
      },
    );

    test('constructor body with explicit return of self', () async {
      // Base.new body ends with `return self` -> the FlowSignal-return branch
      // of the constructor result handling (finalResult = result.value).
      final p = program(
        std: ['print', 'to_string', 'return'],
        functions: [
          {
            'name': 'Ret.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'x', 'is_this': true},
              ],
            },
            'body': blockExpr([
              stmt(stdCall('return', msg([field('value', ref('self'))]))),
            ]),
          },
          mainFn([
            letStmt('o', call('Ret', input: msg([field('x', literal(11))]))),
            stmt(printToString(fieldAcc(ref('o'), 'x'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Ret',
            'descriptor': {
              'name': 'Ret',
              'field': [
                {
                  'name': 'x',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
          },
        ],
      );
      expect(await runAndCapture(p), ['11']);
    });
  });

  group('no-body constructor initializers (engine_invocation.dart)', () {
    // Widget.new has NO body -> _buildConstructorInstance ->
    // _applyConstructorInitializers exercising every initializer literal kind.
    test('_applyConstructorInitializers covers all literal kinds', () async {
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {
            'name': 'Widget.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'x', 'is_this': true},
                {'name': 'coords'},
                {'name': 'sopt', 'default_value': 'def'},
                {'name': 'bopt', 'default_value': true},
              ],
              'initializers': [
                {'kind': 'field', 'name': 'first', 'value': 'coords[0]'},
                {'kind': 'field', 'name': 'oob', 'value': 'coords[9]'},
                {'kind': 'field', 'name': 'flagT', 'value': 'true'},
                {'kind': 'field', 'name': 'flagF', 'value': 'false'},
                {'kind': 'field', 'name': 'n', 'value': '5'},
                {'kind': 'field', 'name': 'r', 'value': '2.5'},
                {'kind': 'field', 'name': 'fromParam', 'value': 'x'},
                {'kind': 'field', 'name': 'fromUnknown', 'value': 'zzz'},
                {'kind': 'field', 'name': 'numI', 'value': 12},
                {'kind': 'field', 'name': 'numD', 'value': 2.5},
                {'kind': 'field', 'name': 'boolV', 'value': true},
                {'kind': 'field', 'name': 'nullV'},
              ],
            },
          },
          {
            'name': 'Widget.describe',
            'metadata': {'kind': 'method'},
            'body': literal('widget'),
          },
          mainFn([
            letStmt(
              'w',
              call(
                'Widget',
                input: msg([
                  field('x', literal(3)),
                  field('coords', listLit([literal(10), literal(20)])),
                ]),
              ),
            ),
            stmt(printToString(fieldAcc(ref('w'), 'first'))),
            stmt(printToString(fieldAcc(ref('w'), 'oob'))),
            stmt(printToString(fieldAcc(ref('w'), 'flagT'))),
            stmt(printToString(fieldAcc(ref('w'), 'flagF'))),
            stmt(printToString(fieldAcc(ref('w'), 'n'))),
            stmt(printToString(fieldAcc(ref('w'), 'r'))),
            stmt(printToString(fieldAcc(ref('w'), 'fromParam'))),
            stmt(printToString(fieldAcc(ref('w'), 'fromUnknown'))),
            stmt(printToString(fieldAcc(ref('w'), 'numI'))),
            stmt(printToString(fieldAcc(ref('w'), 'numD'))),
            stmt(printToString(fieldAcc(ref('w'), 'boolV'))),
            stmt(printToString(fieldAcc(ref('w'), 'nullV'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Widget',
            'descriptor': {'name': 'Widget', 'field': []},
          },
        ],
      );
      expect(await runAndCapture(p), [
        '10',
        'null',
        'true',
        'false',
        '5',
        '2.5',
        '3',
        'zzz',
        '12',
        '2.5',
        'true',
        'null',
      ]);
    });

    test('no-body constructor with super() merges super fields', () async {
      // Kid.new (no body) extends Parent.new (no body) via super(pv).
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {
            'name': 'Parent.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'pv', 'is_this': true},
              ],
            },
          },
          {
            'name': 'Kid.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'kv', 'is_this': true},
              ],
              'initializers': [
                {'kind': 'super', 'args': "('inherited')"},
              ],
            },
          },
          mainFn([
            letStmt('k', call('Kid', input: msg([field('kv', literal(1))]))),
            stmt(printToString(fieldAcc(ref('k'), 'kv'))),
            stmt(printToString(fieldAcc(ref('k'), 'pv'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Parent',
            'descriptor': {
              'name': 'Parent',
              'field': [
                {
                  'name': 'pv',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_STRING',
                },
              ],
            },
          },
          {
            'name': 'main:Kid',
            'descriptor': {
              'name': 'Kid',
              'field': [
                {
                  'name': 'kv',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
            'metadata': {'superclass': 'Parent'},
          },
        ],
      );
      expect(await runAndCapture(p), ['1', 'inherited']);
    });

    test('no-body constructor whose superclass has no constructor', () async {
      // Kid2.new (no body) extends Solo (typeDef only, no ctor) -> the
      // _buildSuperObject fallback inside _buildConstructorInstance.
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {
            'name': 'Kid2.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'kv', 'is_this': true},
              ],
            },
          },
          mainFn([
            letStmt('k', call('Kid2', input: msg([field('kv', literal(2))]))),
            stmt(printToString(fieldAcc(ref('k'), 'kv'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Solo',
            'descriptor': {
              'name': 'Solo',
              'field': [
                {
                  'name': 'base',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_STRING',
                },
              ],
            },
          },
          {
            'name': 'main:Kid2',
            'descriptor': {
              'name': 'Kid2',
              'field': [
                {
                  'name': 'kv',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
            'metadata': {'superclass': 'Solo'},
          },
        ],
      );
      expect(await runAndCapture(p), ['2']);
    });
  });

  group('constructor edge shapes (engine_invocation.dart)', () {
    test('constructor whose name has no dot', () async {
      // A constructor function named 'Gadget' (no dot) still routes through
      // _callObjectConstructor with typeName = the whole function name.
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {
            'name': 'Gadget',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'g', 'is_this': true},
              ],
            },
            'body': blockExpr([]),
          },
          mainFn([
            letStmt('gg', call('Gadget', input: msg([field('g', literal(5))]))),
            stmt(printToString(fieldAcc(ref('gg'), 'g'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Gadget',
            'descriptor': {
              'name': 'Gadget',
              'field': [
                {
                  'name': 'g',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
          },
        ],
      );
      expect(await runAndCapture(p), ['5']);
    });

    test('single non-this param maps onto the sole declared field', () async {
      // params.length == 1 and the class has exactly one field, but the param
      // is neither `is_this` nor named after that field -> it is mapped onto the
      // sole field name.
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {
            'name': 'Single.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'x'},
              ],
            },
            'body': blockExpr([]),
          },
          mainFn([
            letStmt('s', call('Single', input: msg([field('x', literal(9))]))),
            stmt(printToString(fieldAcc(ref('s'), 'val'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Single',
            'descriptor': {
              'name': 'Single',
              'field': [
                {
                  'name': 'val',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
          },
        ],
      );
      expect(await runAndCapture(p), ['9']);
    });

    test('no-body constructor called with a bare scalar input', () async {
      // A no-body constructor invoked with a non-map scalar input exercises the
      // `params.length == 1` scalar branch of _buildConstructorInstance.
      final p = program(
        std: ['print', 'to_string'],
        functions: [
          {
            'name': 'Scalar.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'n', 'is_this': true},
              ],
            },
          },
          mainFn([
            letStmt('sc', call('Scalar', input: literal(7))),
            stmt(printToString(fieldAcc(ref('sc'), 'n'))),
          ]),
        ],
        typeDefs: [
          {
            'name': 'main:Scalar',
            'descriptor': {
              'name': 'Scalar',
              'field': [
                {
                  'name': 'n',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
          },
        ],
      );
      expect(await runAndCapture(p), ['7']);
    });

    test('async function with explicit return', () async {
      // async (non-generator) function returning via a `return` statement hits
      // the FlowSignal-return branch of the async result handling; the BallFuture
      // it wraps auto-unwraps at the (non-async) call site.
      final p = program(
        std: ['print', 'to_string', 'return'],
        functions: [
          {
            'name': 'asyncRet',
            'metadata': {'kind': 'function', 'is_async': true},
            'body': blockExpr([
              stmt(stdCall('return', msg([field('value', literal(42))]))),
            ]),
          },
          mainFn([stmt(printToString(call('asyncRet')))]),
        ],
      );
      expect(await runAndCapture(p), ['42']);
    });
  });

  group('cross-module bare constructor + lazy resolve (engine_invocation)', () {
    test(
      'bare constructor name resolves via the constructor registry',
      () async {
        // Point.new lives in a NON-entry module ('shapes'); calling the bare
        // 'Point' from main misses the "$module.$fn.new" probe and hits the
        // _constructors[function] registry fallback.
        final p = program(
          std: ['print', 'to_string'],
          functions: [
            mainFn([
              letStmt(
                'pt',
                call('Point', input: msg([field('v', literal(8))])),
              ),
              stmt(printToString(fieldAcc(ref('pt'), 'v'))),
            ]),
          ],
          extraModules: [
            {
              'name': 'shapes',
              'functions': [
                {
                  'name': 'Point.new',
                  'metadata': {
                    'kind': 'constructor',
                    'params': [
                      {'name': 'v', 'is_this': true},
                    ],
                  },
                },
              ],
              'typeDefs': [
                {
                  'name': 'shapes:Point',
                  'descriptor': {
                    'name': 'Point',
                    'field': [
                      {
                        'name': 'v',
                        'number': 1,
                        'label': 'LABEL_OPTIONAL',
                        'type': 'TYPE_INT64',
                      },
                    ],
                  },
                },
              ],
            },
          ],
        );
        expect(await runAndCapture(p), ['8']);
      },
    );

    test('unresolved module is lazily loaded via the resolver', () async {
      // 'lazymod' is declared as a module import but is NOT in program.modules;
      // calling lazymod.greet triggers _tryLazyResolve + _indexModule.
      final lazyModuleJson = {
        'name': 'lazymod',
        'typeDefs': [
          {
            'name': 'lazymod:Box',
            'descriptor': {
              'name': 'Box',
              'field': [
                {
                  'name': 'w',
                  'number': 1,
                  'label': 'LABEL_OPTIONAL',
                  'type': 'TYPE_INT64',
                },
              ],
            },
          },
        ],
        'functions': [
          {
            'name': 'Box.new',
            'metadata': {
              'kind': 'constructor',
              'params': [
                {'name': 'w', 'is_this': true},
              ],
            },
          },
          {
            'name': 'greet',
            'metadata': {
              'kind': 'function',
              'params': [
                {'name': 'input'},
              ],
            },
            'body': literal('hello-from-lazymod'),
          },
        ],
      };
      final lazyModule = Module()..mergeFromProto3Json(lazyModuleJson);

      final p = program(
        std: ['print', 'to_string'],
        moduleImports: [
          {
            'name': 'lazymod',
            'inline': {'json': '{}'},
          },
        ],
        functions: [
          mainFn([
            stmt(
              printExpr(call('greet', module: 'lazymod', input: literal(0))),
            ),
          ]),
        ],
      );

      final lines = await runAndCapture(
        p,
        resolver: _FixedResolver(lazyModule),
      );
      expect(lines, ['hello-from-lazymod']);
    });
  });
}

/// Test resolver that always resolves to a single prebuilt [Module].
class _FixedResolver extends ModuleResolver {
  final Module module;
  _FixedResolver(this.module);

  @override
  Future<Module> resolve(ModuleImport import_) async => module;
}
