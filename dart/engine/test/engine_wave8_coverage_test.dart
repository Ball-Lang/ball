// Wave-8 tail-coverage tests for the engine `lib/` product code (issue #61).
//
// A continuation of the wave-5/6/7 files: targets the exact 0-hit lines a fresh
// `dart run tools/coverage_dart.dart` still reported for the `engine` package.
// Every test builds a minimal Program and runs it through a real BallEngine,
// asserting on captured stdout -- no mocking of engine internals.
//
// Several tests use a custom `BallModuleHandler` (the same embedder-extension
// mechanism the wave-7 file's `_RawFutureHandler` established) to hand the
// engine object shapes a native/embedder-backed value can legitimately carry
// -- e.g. an instance map whose `__methods__` hold a RAW (non-async) Dart
// closure, or a `BallMap`-typed `self`. The engine's dispatch logic must handle
// those shapes regardless of how they were produced, and these are the shapes
// that drive the otherwise-unhit dispatch arms.
import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// Custom module handler: hands back precise object shapes an embedder can
// return -- instance maps with raw Dart closures in `__methods__`, a
// `BallMap`-typed `self`, or a class-reference object. The engine dispatch code
// is what is under test; the handler merely supplies the input value.
class _ShapeHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'shape';

  @override
  FutureOr<Object?> call(String function, Object? input, BallCallable engine) {
    switch (function) {
      case 'widget':
        // `__methods__` holds a RAW SYNCHRONOUS closure: `method(input)`
        // returns a plain String (not a Future) -> engine_eval.dart line 266
        // (a typeDef method is always an async closure -> the Future arm 265).
        return <String, Object?>{
          '__type__': 'Widget',
          '__methods__': <String, Object?>{'ping': (Object? _) => 'pong'},
        };
      case 'box':
        // A `BallMap` (not `BallObject`, not plain `Map`) carrying `__type__`,
        // with NO `__methods__` -> the method call routes via `_resolveMethod`
        // (engine_eval.dart 275) and a field write hits ballObjectSetField's
        // BallMap arm (engine_types.dart 195/196).
        return BallMap(<String, Object?>{'__type__': 'main:Box', 'x': 0});
      case 'colorClass':
        // A class-reference object whose ref name is an ENUM's name -> the
        // "enum values on class ref" arm (engine_eval.dart 950/951).
        return BallMap(<String, Object?>{
          '__type__': '__class__',
          '__class_ref__': 'Color',
        });
      case 'child':
        // `greet` lives ONLY in the SUPER's `__methods__` -> the super-chain
        // method walk in `_evalFieldAccess` (engine_eval.dart 989/990).
        return <String, Object?>{
          '__type__': 'Child',
          '__super__': <String, Object?>{
            '__type__': 'Parent',
            '__methods__': <String, Object?>{
              'greet': (Object? _) => 'from-super',
            },
          },
        };
      case 'emptySelf':
        // A bare `self` envelope (no `__type__`): method dispatch falls straight
        // through to `_resolveAndCallFunction`.
        return <String, Object?>{};
      default:
        throw BallRuntimeError('Unknown shape function: "$function"');
    }
  }
}

Map<String, dynamic> _shapeModule() => {
  'name': 'shape',
  'functions': [
    for (final n in const ['widget', 'box', 'colorClass', 'child', 'emptySelf'])
      {'name': n, 'isBase': true},
  ],
};

Future<List<String>> runAndCapture(Program program) async {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    moduleHandlers: [StdModuleHandler(), _ShapeHandler()],
  );
  await engine.run();
  return lines;
}

const _stdFnNames = <String>[
  'print',
  'to_string',
  'switch',
  'not_equals',
  'assign',
  'break',
  'yield',
];

Program buildProgram({
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> enums = const [],
  List<Map<String, dynamic>> extraModules = const [],
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
    ],
  };
  final mainModule = <String, dynamic>{
    'name': 'main',
    'functions': functions,
    if (enums.isNotEmpty) 'enums': enums,
  };
  final programJson = {
    'name': 'test',
    'version': '1.0.0',
    'modules': [stdModule, _shapeModule(), mainModule, ...extraModules],
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

Map<String, dynamic> shapeCall(String function) =>
    call(function, module: 'shape');

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

Map<String, dynamic> assign(
  Map<String, dynamic> target,
  Map<String, dynamic> value,
) => stdCall(
  'assign',
  msg([
    field('target', target),
    field('value', value),
    field('op', literal('=')),
  ]),
);

Map<String, dynamic> block(
  List<Map<String, dynamic>> statements, {
  Map<String, dynamic>? result,
}) => {
  'block': {'statements': statements, if (result != null) 'result': result},
};

Map<String, dynamic> mainFn(List<Map<String, dynamic>> statements) => {
  'name': 'main',
  'body': block(statements),
};

// A method function `Type.method`, registered under key `main.Type.method` so
// `_resolveMethod(Type, method)` finds it.
Map<String, dynamic> methodFn(
  String qualifiedName,
  Map<String, dynamic> body,
) => {
  'name': qualifiedName,
  'metadata': {'kind': 'method'},
  'body': body,
};

void main() {
  group('instance-method dispatch on embedder-supplied objects', () {
    test('a RAW synchronous Function in __methods__ returns without a Future '
        '(engine_eval.dart:266)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                call('ping', input: msg([field('self', shapeCall('widget'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['pong']);
    });

    test('a __methods__-less typed self falls back to _resolveMethod, and a '
        'field write on a BallMap self hits ballObjectSetField '
        '(engine_eval.dart:275 + engine_types.dart:195/196)', () async {
      final program = buildProgram(
        functions: [
          methodFn(
            'main:Box.bump',
            block([stmt(assign(ref('x'), literal(99)))], result: ref('x')),
          ),
          mainFn([
            stmt(
              printToString(
                call('bump', input: msg([field('self', shapeCall('box'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['99']);
    });
  });

  group('field access on a class reference / super chain', () {
    test('an enum value read through a __class__ reference '
        '(engine_eval.dart:950/951)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                fieldAcc(fieldAcc(shapeCall('colorClass'), 'red'), 'name'),
              ),
            ),
          ]),
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

    test('a method found only via the super __methods__ walk '
        '(engine_eval.dart:989/990)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'not_equals',
                  msg([
                    field('left', fieldAcc(shapeCall('child'), 'greet')),
                    field('right', literal(null)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });
  });

  group('messageCreation method resolution via self type', () {
    test('a Module:method messageCreation resolves through self __type__ '
        '(engine_eval.dart:1633)', () async {
      final program = buildProgram(
        functions: [
          methodFn('main:Calc._helper', block([], result: literal('helped'))),
          mainFn([
            letStmt('self', msg([field('__type__', literal('main:Calc'))])),
            stmt(printToString(msg([], typeName: 'main:_helper'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['helped']);
    });
  });

  group('lambda positional-param binding vs the __type__ marker', () {
    test('a lambda param named __type__ is bound from the input map even '
        'though the marker key is skipped by the entry loop '
        '(engine_eval.dart:2065)', () async {
      final lambda = {
        'lambda': {
          'metadata': {
            'params': [
              {'name': '__type__'},
            ],
          },
          'body': ref('__type__'),
        },
      };
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('f', lambda),
            stmt(
              printToString(
                call(
                  'f',
                  input: msg([field('__type__', literal('marker-value'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['marker-value']);
    });
  });

  group('type-pattern matching -- Null arm', () {
    // A `case Null:` arm runs `_matchesTypePattern(subject, 'Null')`, whose
    // Null branch (engine_std.dart:2575) returns `value == null || value is
    // BallNull`. Driving it with a NON-null (int) subject exercises that branch
    // to its `false` result (the case is refuted, the default runs). A null
    // subject short-circuits `value == null` before the branch line is credited.
    test('a case Null: arm is refuted by a non-null subject '
        '(engine_std.dart:2575)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'switch',
                msg([
                  field('subject', literal(5)),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal('Null')),
                        field('body', printExpr(literal('is-null'))),
                      ]),
                      msg([
                        field('is_default', literal(true)),
                        field('body', printExpr(literal('not-null'))),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['not-null']);
    });
  });

  group('factory constructor with a non-return control-flow signal', () {
    test(
      'a factory ctor body that produces a break signal (self present) '
      'finalizes to the signal value (engine_invocation.dart:228/229)',
      () async {
        final program = buildProgram(
          functions: [
            {
              'name': 'W.make',
              'metadata': {'kind': 'constructor', 'is_factory': true},
              'body': stdCall('break', msg([])),
            },
            mainFn([
              stmt(
                printToString(
                  call(
                    'W.make',
                    module: 'main',
                    input: msg([field('self', shapeCall('emptySelf'))]),
                  ),
                ),
              ),
            ]),
          ],
        );
        expect(await runAndCapture(program), ['null']);
      },
    );
  });
}
