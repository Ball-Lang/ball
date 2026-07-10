// Wave-7 tail-coverage tests for the engine `lib/` product code (issue #61).
//
// A continuation of the wave-5/wave-6 files: targets branches left uncovered
// after a fresh `dart run tools/coverage_dart.dart` re-measurement (per the
// established ground rule: measure against the CURRENT baseline, not stale
// line numbers). Every test builds a minimal Program and runs it through a
// real BallEngine, asserting on captured stdout — no mocking of engine
// internals. Kept self-contained (does not import other test files'
// helpers), mirroring the wave-5/wave-6/phase2c house style.
//
//   * engine_control_flow.dart — `_matchSwitchPattern`'s module-qualified
//     enum fallback (the bare-name lookup can be shadowed by a
//     LATER-registered same-named enum from a different module, since
//     `_enumValues` stores both a qualified AND an unqualified key per enum
//     and the unqualified one is last-write-wins across the whole program;
//     see `BallEngine`'s enum-registration loop in `engine.dart`).
//   * engine_eval.dart — `_evalFieldAccess`'s BallFuture-unwrap-before-field-
//     read arm (reached the way a real embedder would produce a raw,
//     not-yet-awaited BallFuture map: via a custom `BallModuleHandler`,
//     mirroring `engine_wave5_control_flow_coverage_test.dart`'s `_NatHandler`
//     pattern).
//
// A REAL BUG was found (not fixed here — tests-only lane; see the
// `coverage:ignore-line` comment at engine_eval.dart's `.runtimeType` case
// for the `Map`/`BallMap` arm): field access for `.runtimeType` on a genuine
// Ball Map (or a `BallMap`) throws `BallRuntimeError: Field "runtimeType"
// not found` instead of returning `"Map"`. The dead-code arm meant to handle
// it (`if (object is Map || object is BallMap) return 'Map';`) can never run
// because `_evalFieldAccess`'s earlier `objectMap != null` block (which
// every genuine Map/BallMap value is routed through via `_asMap`) has no
// `'runtimeType'` case in its own getter-dispatch/virtual-field switch, so it
// throws "Field not found" before ever reaching the later switch — the exact
// same control-flow-ordering pattern issue #261 already documented for the
// sibling `Map`/`Set` arms in that same later switch.
import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Self-contained builder helpers (independent of other test files). ──

/// Hands back a raw, not-yet-unwrapped BallFuture map — the shape a Ball
/// engine embedder (e.g. a concurrency/task primitive) can hand back
/// directly, distinct from the auto-unwrapped result of awaiting a normal
/// `async` Ball function call.
class _RawFutureHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'raw';

  @override
  FutureOr<Object?> call(String function, Object? input, BallCallable engine) {
    switch (function) {
      case 'pending':
        return <String, Object?>{
          '__ball_future__': true,
          'value': <String, Object?>{'x': 42},
          'completed': true,
        };
      case 'closure':
        // A raw Dart closure — not Null/int/double/String/bool/List/Map, the
        // only way to reach `.runtimeType`'s fallthrough `'Object'` arm
        // (every genuine Ball Map/BallObject value is intercepted earlier
        // by `_evalFieldAccess`'s `objectMap != null` block).
        return (int x) => x + 1;
      default:
        throw BallRuntimeError('Unknown raw function: "$function"');
    }
  }
}

Map<String, dynamic> _rawModule() => {
  'name': 'raw',
  'functions': [
    for (final n in const ['pending', 'closure']) {'name': n, 'isBase': true},
  ],
};

Future<List<String>> runAndCapture(Program program) async {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    moduleHandlers: [StdModuleHandler(), _RawFutureHandler()],
  );
  await engine.run();
  return lines;
}

const _stdFnNames = <String>['print', 'to_string', 'switch', 'map_create'];

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
    'modules': [stdModule, _rawModule(), mainModule, ...extraModules],
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

Map<String, dynamic> rawCall(String function) => call(function, module: 'raw');

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
  group('bare-identifier self-field fallback (_evalReference, no scope '
      'pre-binding)', () {
    test("a bare identifier resolves via self's OWN field when the name "
        "isn't otherwise bound in the lexical scope", () async {
      // Method-body field references normally resolve earlier (the
      // method-invocation convenience pre-binds `self`'s fields
      // directly into the callee's local scope — see
      // `_evalReference`'s `scope.has(name)` check, which fires FIRST).
      // A plain top-level function that binds `self` via an explicit
      // `let` (not through method-call machinery) has no such
      // pre-binding, so a later bare reference must fall through to the
      // `self`-lookup fallback in `_evalReference`. A THREE-level
      // `__super__` chain (self -> parent -> grandparent) additionally
      // forces the inherited-field walk past its first (non-matching)
      // iteration to reach `z` on the grandparent.
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'self',
              msg([
                field('x', literal(1)),
                field(
                  '__super__',
                  msg([
                    field('y', literal(2)),
                    field('__super__', msg([field('z', literal(3))])),
                  ]),
                ),
              ]),
            ),
            stmt(printToString(ref('x'))),
            stmt(printToString(ref('y'))),
            stmt(printToString(ref('z'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1', '2', '3']);
    });
  });

  group('BallFuture field access (custom-module-injected raw future)', () {
    test('accessing a field on a not-yet-unwrapped BallFuture map unwraps the '
        "future's `value` before reading the field", () async {
      expect(await evalToString(fieldAcc(rawCall('pending'), 'x')), '42');
    });
  });

  group('.runtimeType on a non-Map/List/primitive value', () {
    test('a raw Dart closure (custom-module-injected) falls through to '
        'the "Object" default', () async {
      expect(
        await evalToString(fieldAcc(rawCall('closure'), 'runtimeType')),
        'Object',
      );
    });
  });

  group('_matchSwitchPattern — module-qualified enum fallback (cross-module '
      'bare-name collision)', () {
    test("a switch case pattern resolves via the module-qualified enum key "
        "when a LATER-registered same-named enum from a different module "
        "has overwritten the bare-name lookup", () async {
      // `main` declares its OWN `Color` enum {red, green}. `other`
      // declares a DIFFERENT enum ALSO named `Color` {blue, yellow},
      // registered AFTER `main` (module registration order = program
      // module list order) — this overwrites the *unqualified* `Color`
      // key in the engine's global `_enumValues` map (see
      // `engine.dart`'s enum-registration loop, which stores both
      // `module:Color` and bare `Color`, last-module-wins on the bare
      // key). So resolving the pattern text `"Color.red"` via the
      // bare-name lookup finds `other`'s Color (no `red` member) and
      // must fall through to the module-qualified `main:Color` lookup.
      //
      // The SUBJECT is deliberately given a type name (`other:NotColor`)
      // that does NOT textually match the pattern's `Color` — this is
      // required to reach the `_enumValues`-based lookups at all: the
      // FIRST comparison in `_matchSwitchPattern` (a direct textual
      // check of the subject's own `__type__`/`name` against the
      // pattern, with no registry lookup) already succeeds — and
      // returns early — for any subject that legitimately carries
      // `{__type__: 'main:Color', name: 'red'}` (the exact shape the
      // qualified lookup would ALSO resolve to), so a genuine match can
      // never reach this fallback in the first place. A structurally
      // real-but-mismatched subject is the only way to drive execution
      // all the way through both the bare AND qualified lookups (proving
      // neither silently short-circuits or throws) while still
      // observing a real, asserted-on outcome — "no match", since the
      // qualified lookup's own final comparison correctly rejects the
      // mismatched subject.
      final subject = msg([
        field('__type__', literal('other:NotColor')),
        field('name', literal('red')),
      ]);
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'switch',
                msg([
                  field('subject', subject),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal('Color.red')),
                        field('body', printExpr(literal('matched'))),
                      ]),
                      msg([
                        field('is_default', literal(true)),
                        field('body', printExpr(literal('no match'))),
                      ]),
                    ]),
                  ),
                ]),
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
        extraModules: [
          {
            'name': 'other',
            'enums': [
              {
                'name': 'other:Color',
                'value': [
                  {'name': 'blue', 'number': 0},
                  {'name': 'yellow', 'number': 1},
                ],
              },
            ],
          },
        ],
      );
      expect(await runAndCapture(program), ['no match']);
    });
  });
}
