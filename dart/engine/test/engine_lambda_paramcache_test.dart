/// #246 — lambda param binding must not collide via the name-keyed _paramCache.
///
/// Root cause: `_paramCache` is keyed `'$moduleName.${func.name}'`; a lambda's
/// name is always "" so every nameless function keys to "$moduleName.". The fix
/// stops writing nameless functions to the cache and makes the lookup extract a
/// nameless function's params inline.
///
/// These tests build lambdas that carry DISTINCT named params AND a degenerate
/// empty-named module function that (pre-fix) would pollute _paramCache["main."],
/// then assert each lambda still binds ITS OWN param. They lock in the
/// non-colliding behavior that #64 (lambda.typed_param carve-out closure) will
/// rely on.
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

Future<List<String>> _run(Map<String, dynamic> json) async {
  final lines = <String>[];
  await BallEngine(
    Program()..mergeFromProto3Json(json),
    stdout: lines.add,
  ).run();
  return lines;
}

Map<String, dynamic> _lit(Object? v) => v is int
    ? {
        'literal': {'intValue': '$v'},
      }
    : {
        'literal': {'stringValue': '$v'},
      };

Map<String, dynamic> _ref(String n) => {
  'reference': {'name': n},
};

Map<String, dynamic> _mc(List<MapEntry<String, Map<String, dynamic>>> fields) =>
    {
      'messageCreation': {
        'fields': [
          for (final e in fields) {'name': e.key, 'value': e.value},
        ],
      },
    };

Map<String, dynamic> _std(
  String fn,
  List<MapEntry<String, Map<String, dynamic>>> input,
) => {
  'call': {'module': 'std', 'function': fn, 'input': _mc(input)},
};

/// A lambda that declares a single NAMED param [param] and returns it.
Map<String, dynamic> _namedParamLambda(String param) => {
  'lambda': {
    'name': '',
    'inputType': 'int',
    'metadata': {
      'params': [
        {'name': param},
      ],
    },
    'body': _ref(param),
  },
};

/// print(to_string(<expr>))
Map<String, dynamic> _printStmt(Map<String, dynamic> expr) => {
  'expression': _std('print', [
    MapEntry('message', _std('to_string', [MapEntry('value', expr)])),
  ]),
};

/// invoke(callee: <lambda>, value: <arg>)
Map<String, dynamic> _invoke(Map<String, dynamic> callee, int arg) =>
    _std('invoke', [MapEntry('callee', callee), MapEntry('value', _lit(arg))]);

Map<String, dynamic> _program({required bool withPoison}) {
  final mainStatements = <Map<String, dynamic>>[
    // Bind two lambdas with DISTINCT named params, then invoke each.
    {
      'let': {'name': 'la', 'value': _namedParamLambda('pa')},
    },
    {
      'let': {'name': 'lb', 'value': _namedParamLambda('pb')},
    },
    _printStmt(_invoke(_ref('la'), 11)),
    _printStmt(_invoke(_ref('lb'), 22)),
  ];

  final mainFns = <Map<String, dynamic>>[
    {
      'name': 'main',
      'outputType': 'void',
      'body': {
        'block': {'statements': mainStatements},
      },
    },
  ];

  if (withPoison) {
    // A degenerate empty-named module function carrying its own params. Under
    // the pre-fix code its registration writes _paramCache["main."]=["POISON"];
    // the fix skips caching nameless functions so this never pollutes.
    mainFns.add({
      'name': '',
      'outputType': 'int',
      'metadata': {
        'params': [
          {'name': 'POISON'},
        ],
      },
      'body': _ref('POISON'),
    });
  }

  return {
    'name': 'test',
    'version': '1.0.0',
    'modules': [
      {
        'name': 'std',
        'functions': [
          {'name': 'print', 'isBase': true},
          {'name': 'to_string', 'isBase': true},
          {'name': 'invoke', 'isBase': true},
        ],
      },
      {'name': 'main', 'functions': mainFns},
    ],
    'entryModule': 'main',
    'entryFunction': 'main',
  };
}

void main() {
  test('two lambdas with distinct named params each bind their own', () async {
    expect(await _run(_program(withPoison: false)), ['11', '22']);
  });

  test(
    'a degenerate empty-named module function does not pollute lambda params',
    () async {
      // Even with a nameless module function that (pre-fix) caches params under
      // "main.", each lambda must still bind its own param — no collision.
      expect(await _run(_program(withPoison: true)), ['11', '22']);
    },
  );
}
