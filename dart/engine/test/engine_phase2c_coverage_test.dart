// Phase-2c coverage tests for the Dart engine (issue #261 residual triage,
// following #61 Phase-2 / #262).
//
// Each group below targets one specific, per-arm-verified REACHABLE line (or
// small cluster) that `dart run tools/coverage_dart.dart` reported as
// hits=0 after #262 landed. Companion `coverage:ignore` markers (with a
// per-arm WHY) were applied directly at the sites that were instead proven
// genuinely unreachable — see the inline comments there for the evidence.
//
// Kept self-contained (does not import other test files' helpers), mirroring
// the engine_wave5_*_coverage_test.dart house style.
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Self-contained builders (same convention as the other wave-5 files) ──

Future<List<String>> runAndCapture(
  Program program, {
  List<BallModuleHandler>? handlers,
}) async {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    // Passing a custom handler list REPLACES the default StdModuleHandler
    // (BallEngine only defaults when null), so keep it in the mix.
    moduleHandlers: handlers == null ? null : [StdModuleHandler(), ...handlers],
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
  'to_double',
  'to_int',
  'index',
  'switch',
  'switch_expr',
  'try',
  'throw',
  'yield',
  'yield_each',
  'record',
  'is',
  'is_not',
  'as',
  'to_string_as_fixed',
  'compare_to',
  'list_push',
  'list_get',
  'list_length',
  'list_foreach',
  'list_to_list',
  'map_create',
  'map_get',
  'map_set',
  'map_keys',
  'map_values',
  'map_from_entries',
  'map_contains_key',
  'map_length',
  'map_is_empty',
  'set_create',
  'set_add',
  'set_contains',
  'set_length',
  'string_length',
  'string_is_empty',
  'math_abs',
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
    'modules': [_stdModule(), mainModule, ...extraModules],
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

Map<String, dynamic> bareCall(String function, Map<String, dynamic> input) =>
    call(function, input: input);

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
  group('to_string_as_fixed preserves negative-zero sign (engine_std)', () {
    // NOTE: per-arm investigation (issue #261) found the `!s.startsWith('-')`
    // re-add-the-sign arm this was meant to target is unreachable on the Dart
    // reference engine (the VM's own toStringAsFixed already keeps the sign;
    // the arm compensates only for the compiled TS/C++ self-hosts) and is now
    // `coverage:ignore`d with that evidence. Kept as a regression check for
    // the (already-covered) plain formatting path.
    test('(-0.0).toStringAsFixed(2) keeps the leading minus', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'to_string_as_fixed',
                  msg([
                    field('value', literal(-0.0)),
                    field('digits', literal(2)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['-0.00']);
    });
  });

  group('direct Set stringification (engine_std _ballToStringAsync)', () {
    // NOTE: per-arm investigation (issue #261) found the native-Set `v is
    // Set` arm this was meant to target is unreachable (`_isBallSet`
    // upstream already matches any Set) and is now `coverage:ignore`d with
    // that evidence. This test is kept as a regression check for the
    // (already-covered) `_isBallSet` rendering path it actually exercises.
    test('printing a NATIVE Dart Set directly renders {a, b, c}', () async {
      // set_create/set_add build the PORTABLE set (a {'__ball_set__': [...]}
      // map), which _isBallSet catches earlier in _ballToStringAsync — so it
      // never reaches the `v is Set` arm targeted here. Only a genuine native
      // Dart Set (surfaced via a custom module handler, mirroring the
      // `_NativeHandler` technique used elsewhere in this suite) exercises it.
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(call('native_set', module: 'ext')))]),
        ],
        extraModules: [
          {
            'name': 'ext',
            'functions': [
              {'name': 'native_set', 'isBase': true},
            ],
          },
        ],
      );
      expect(await runAndCapture(program, handlers: [_NativeSetHandler()]), [
        '{1, 2}',
      ]);
    });
  });

  group('direct exception stringification (engine_std _ballToStringAsync)', () {
    // NOTE: per-arm investigation (issue #261) found the `v is BallException`
    // arm this was meant to target is unreachable (the catch machinery in
    // `_evalLazyTry` always unwraps to `e.value` before binding the catch
    // variable, so Ball code can never hold a raw BallException) and is now
    // `coverage:ignore`d with that evidence. Kept as a regression check for
    // the (already-covered) catch-and-print-the-message path.
    test('printing a caught exception directly renders its message', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field(
                    'body',
                    blockExpr([
                      stmt(
                        stdCall(
                          'throw',
                          msg([
                            field('value', literal('boom')),
                            field('type', literal('Exception')),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                  field('catches', {
                    'literal': {
                      'listValue': {
                        'elements': [
                          msg([
                            field('variable', literal('e')),
                            field(
                              'body',
                              blockExpr([stmt(printToString(ref('e')))]),
                            ),
                          ]),
                        ],
                      },
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['boom']);
    });
  });

  group('type_check against Null/void (engine_std _typeMatches ~1973)', () {
    test('a null value matches type "Null"', () async {
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
  });

  group(
    'structured type_test pattern for "Null" (engine_std _matchesTypePattern ~2524)',
    () {
      test('switch_expr type_test pattern matches a null subject', () async {
        final pattern = msg([
          field('__pattern_kind__', literal('type_test')),
          field('type', literal('Null')),
          field('name', literal('x')),
        ]);
        final caseOf = msg([
          field('pattern', pattern),
          field('body', literal('is-null')),
        ]);
        final result = bareCall(
          'switch_expr',
          msg([
            field('subject', literal(null)),
            field('cases', listLit([caseOf])),
          ]),
        );
        expect(await evalToString(result), 'is-null');
      });
    },
  );

  group('yield_each splicing a nested BallGenerator (engine.dart ~73, '
      'engine_control_flow.dart ~1569)', () {
    // The only way a Ball-level value can BE a raw BallGenerator (rather than
    // the plain List a sync*/async* function call always returns to its
    // caller) is through a custom module handler that hands one back
    // directly — mirroring the `_NativeHandler` injection technique used
    // elsewhere in this suite for native Set/Iterable coverage.
    test(
      'yield_each on a directly-injected BallGenerator splices its values',
      () async {
        final handler = _GeneratorHandler();
        final program = buildProgram(
          functions: [
            {
              'name': 'nums',
              'metadata': {'kind': 'function', 'is_sync_star': true},
              'body': blockExpr([
                stmt(stdCall('yield', msg([field('value', literal(0))]))),
                stmt(
                  stdCall(
                    'yield_each',
                    msg([field('value', call('inner_gen', module: 'ext'))]),
                  ),
                ),
              ]),
            },
            mainFn([stmt(printToString(call('nums')))]),
          ],
          extraModules: [
            {
              'name': 'ext',
              'functions': [
                {'name': 'inner_gen', 'isBase': true},
              ],
            },
          ],
        );
        expect(await runAndCapture(program, handlers: [handler]), [
          '[0, 7, 8]',
        ]);
      },
    );

    test('bare (eager-dispatch) yield_each on a BallGenerator hits '
        'engine.dart _consumeGeneratorFlow', () async {
      // A module-qualified `stdCall` routes through the LAZY switch in
      // _evalCall straight to _evalYieldEach (control_flow.dart), which
      // checks scope.has('__generator__') directly. A BARE call instead
      // routes through the EAGER _callBaseFunction dispatch table (whose
      // 'yield_each' handler just wraps the value in a _FlowSignal with no
      // generator-scope check) — that signal only gets spliced into the
      // active generator when the call's result is later passed through
      // _consumeGeneratorFlow, exercising the `val is BallGenerator` arm
      // in engine.dart directly.
      final handler = _GeneratorHandler();
      final program = buildProgram(
        functions: [
          {
            'name': 'nums',
            'metadata': {'kind': 'function', 'is_sync_star': true},
            'body': blockExpr([
              stmt(
                bareCall(
                  'yield_each',
                  msg([field('value', call('inner_gen', module: 'ext'))]),
                ),
              ),
            ]),
          },
          mainFn([stmt(printToString(call('nums')))]),
        ],
        extraModules: [
          {
            'name': 'ext',
            'functions': [
              {'name': 'inner_gen', 'isBase': true},
            ],
          },
        ],
      );
      expect(await runAndCapture(program, handlers: [handler]), ['[7, 8]']);
    });
  });

  group(
    '??= compound assignment (engine_control_flow _evalNullAwareAssign)',
    () {
      // NOTE: per-arm investigation (issue #261) found `_applyCompoundOp`'s
      // own '??=' switch arm is unreachable (`_evalAssign` intercepts '??='
      // earlier, via `_evalNullAwareAssign`) and is now `coverage:ignore`d
      // with that evidence. This test is kept as a regression check for the
      // (already-covered) null-aware-assign path it actually exercises.
      test('x ??= y assigns only when x was null', () async {
        final program = buildProgram(
          functions: [
            mainFn([
              letStmt('x', literal(null)),
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
        expect(await runAndCapture(program), ['9']);
      });
    },
  );

  group('compound-assign syncs a top-level var from inside a function scope '
      '(engine_control_flow)', () {
    // NOTE: per-arm investigation (issue #261) found the dedicated
    // `_globalScope.set()` sync this was meant to target is unreachable
    // (`scope.set()` just above it already recurses to `_globalScope` for
    // any top-level var) and is now `coverage:ignore`d with that evidence.
    // Kept as a regression check that the mutation is visible globally.
    test('a function body can += a top-level variable', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'counter',
            'metadata': {'kind': 'top_level_variable'},
            'outputType': 'int',
            'body': blockExpr([], result: literal(1)),
          },
          {
            'name': 'bump',
            'body': blockExpr([
              stmt(
                stdCall(
                  'assign',
                  msg([
                    field('target', ref('counter')),
                    field('value', literal(1)),
                    field('op', literal('+=')),
                  ]),
                ),
              ),
            ]),
          },
          mainFn([stmt(call('bump')), stmt(printToString(ref('counter')))]),
        ],
      );
      expect(await runAndCapture(program), ['2']);
    });
  });

  group('typed catch on a Map-shaped (non-BallException) thrown value '
      '(engine_control_flow ~635-640)', () {
    test('on CustomError catch (e) matches a __type__-tagged map', () async {
      // `std.throw` always wraps its value in a native [BallException], so
      // `e is BallException` (the sibling arm just above) is always the one
      // that fires for anything thrown that way. The ONLY way the caught
      // Dart-level object can be a raw, non-BallException Map is for
      // something OTHER than std.throw to throw it directly — a custom
      // BallModuleHandler can (its `call()` is unconstrained Dart code).
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', blockExpr([stmt(call('boom', module: 'ext'))])),
                  field('catches', {
                    'literal': {
                      'listValue': {
                        'elements': [
                          msg([
                            field('type', literal('CustomError')),
                            field('variable', literal('e')),
                            field(
                              'body',
                              blockExpr([stmt(printExpr(literal('caught')))]),
                            ),
                          ]),
                        ],
                      },
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
        extraModules: [
          {
            'name': 'ext',
            'functions': [
              {'name': 'boom', 'isBase': true},
            ],
          },
        ],
      );
      expect(await runAndCapture(program, handlers: [_ThrowingHandler()]), [
        'caught',
      ]);
    });
  });

  group(
    'virtual field-access properties on Map/Set (engine_eval ~1007-1091)',
    () {
      test('Map.length / isEmpty / isNotEmpty', () async {
        final m = stdCall(
          'map_set',
          msg([
            field('map', stdCall('map_create', msg([]))),
            field('key', literal('a')),
            field('value', literal(1)),
          ]),
        );
        expect(await evalToString(fieldAcc(m, 'length')), '1');
        expect(await evalToString(fieldAcc(m, 'isNotEmpty')), 'true');
        expect(
          await evalToString(
            fieldAcc(stdCall('map_create', msg([])), 'isEmpty'),
          ),
          'true',
        );
      });

      test('Set.first / last / single', () async {
        final s = stdCall(
          'set_add',
          msg([
            field('set', stdCall('set_create', msg([]))),
            field('value', literal(7)),
          ]),
        );
        expect(await evalToString(fieldAcc(s, 'first')), '7');
        expect(await evalToString(fieldAcc(s, 'last')), '7');
        expect(await evalToString(fieldAcc(s, 'single')), '7');
      });

      test('Map.values sorts enum-shaped values by index', () async {
        // The sort predicate (v is Map && containsKey('index') &&
        // containsKey('__type__')) matches the raw Dart-map shape produced by
        // real enum-value resolution (_enumValues), not a hand-built
        // messageCreation — so build a genuine `enum Color { red, green }` and
        // put its VALUES into a map out of index order.
        final color = ref('Color');
        final theMap = msg([
          field('b', fieldAcc(color, 'green')),
          field('a', fieldAcc(color, 'red')),
        ]);
        final values = fieldAcc(theMap, 'values');
        final firstName = fieldAcc(
          stdCall(
            'list_get',
            msg([field('list', values), field('index', literal(0))]),
          ),
          'name',
        );
        final program = buildProgram(
          functions: [
            mainFn([stmt(printToString(firstName))]),
          ],
          enums: [
            {
              'name': 'main:Color',
              'value': [
                {'name': 'red', 'number': 0},
                {'name': 'green', 'number': 1},
              ],
            },
          ],
        );
        expect(await runAndCapture(program), ['red']);
      });

      test('double literal .isNegative / .sign / .abs', () async {
        // A double literal (not int) — per the engine's own convention
        // (documented at engine_std.dart's `to_string_as_fixed`/BallDouble
        // handling), double literals evaluate to BallDouble, exercising the
        // BallDouble-specific arms rather than the bare `object is num` one.
        expect(
          await evalToString(fieldAcc(literal(-3.5), 'isNegative')),
          'true',
        );
        expect(await evalToString(fieldAcc(literal(-3.5), 'sign')), '-1.0');
        expect(await evalToString(fieldAcc(literal(-3.5), 'abs')), '3.5');
      });
    },
  );
}

/// Throws a raw, `__type__`-tagged Map (NOT a [BallException]) — something
/// `std.throw` itself can never produce, but a custom module handler can.
class _ThrowingHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'ext';

  @override
  Object? call(String function, Object? input, BallCallable engine) {
    if (function == 'boom') {
      throw <String, Object?>{'__type__': 'main:CustomError', 'message': 'bad'};
    }
    throw BallRuntimeError('unknown ext fn: "$function"');
  }
}

/// Hands back a genuine (non-portable) Dart `Set`, the only way Ball-level
/// code can reach the native `v is Set` arm of `_ballToStringAsync` — the
/// engine's own `set_create`/`set_add` build the portable `{'__ball_set__':
/// [...]}` map form instead (see `_isBallSet`).
class _NativeSetHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'ext';

  @override
  Object? call(String function, Object? input, BallCallable engine) {
    if (function == 'native_set') return <int>{1, 2};
    throw BallRuntimeError('unknown ext fn: "$function"');
  }
}

/// Hands back a fresh [BallGenerator] with pre-populated values when called —
/// the only way Ball-level code can obtain a raw generator object (a normal
/// sync*/async* function call always resolves to a plain List/BallFuture
/// before returning to its caller; see engine_invocation.dart's generator
/// finalization).
class _GeneratorHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'ext';

  @override
  Object? call(String function, Object? input, BallCallable engine) {
    if (function == 'inner_gen') {
      return BallGenerator()
        ..yield_(7)
        ..yield_(8);
    }
    throw BallRuntimeError('unknown ext fn: "$function"');
  }
}
