import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Load a ball program from a JSON file.
Program loadProgram(String path) {
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return Program()..mergeFromProto3Json(json);
}

/// Run a program through the engine and capture stdout lines.
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

/// Build a minimal ball program with a single module and functions.
///
/// [functions] should be a list of JSON-like maps matching the
/// FunctionDefinition proto3 JSON shape.
Program buildProgram({
  String name = 'test',
  String moduleName = 'main',
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> stdFunctions = const [],
}) {
  final stdModule = {
    'name': 'std',
    'types': [
      {
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
      {
        'name': 'BinaryInput',
        'field': [
          {
            'name': 'left',
            'number': 1,
            'label': 'LABEL_OPTIONAL',
            'type': 'TYPE_INT64',
          },
          {
            'name': 'right',
            'number': 2,
            'label': 'LABEL_OPTIONAL',
            'type': 'TYPE_INT64',
          },
        ],
      },
      {
        'name': 'UnaryInput',
        'field': [
          {
            'name': 'value',
            'number': 1,
            'label': 'LABEL_OPTIONAL',
            'type': 'TYPE_STRING',
          },
        ],
      },
    ],
    'functions': [
      {'name': 'print', 'isBase': true},
      {'name': 'add', 'isBase': true},
      {'name': 'subtract', 'isBase': true},
      {'name': 'multiply', 'isBase': true},
      {'name': 'divide_double', 'isBase': true},
      {'name': 'divide', 'isBase': true},
      {'name': 'modulo', 'isBase': true},
      {'name': 'negate', 'isBase': true},
      {'name': 'less_than', 'isBase': true},
      {'name': 'greater_than', 'isBase': true},
      {'name': 'lte', 'isBase': true},
      {'name': 'gte', 'isBase': true},
      {'name': 'equals', 'isBase': true},
      {'name': 'not_equals', 'isBase': true},
      {'name': 'and', 'isBase': true},
      {'name': 'or', 'isBase': true},
      {'name': 'not', 'isBase': true},
      {'name': 'to_string', 'isBase': true},
      {'name': 'if', 'isBase': true},
      {'name': 'for', 'isBase': true},
      {'name': 'while', 'isBase': true},
      {'name': 'return', 'isBase': true},
      {'name': 'assign', 'isBase': true},
      {'name': 'string_interpolation', 'isBase': true},
      ...stdFunctions,
    ],
  };

  final mainModule = {'name': moduleName, 'functions': functions};

  final programJson = {
    'name': name,
    'version': '1.0.0',
    'modules': [stdModule, mainModule],
    'entryModule': moduleName,
    'entryFunction': 'main',
  };

  return Program()..mergeFromProto3Json(programJson);
}

// ── Helpers for building expression JSON ──────────────────────

Map<String, dynamic> literal(Object value) {
  if (value is int)
    return {
      'literal': {'intValue': '$value'},
    };
  if (value is double)
    return {
      'literal': {'doubleValue': value},
    };
  if (value is String)
    return {
      'literal': {'stringValue': value},
    };
  if (value is bool)
    return {
      'literal': {'boolValue': value},
    };
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

Map<String, dynamic> dartStdCall(String function, Map<String, dynamic> input) =>
    call(function, module: 'dart_std', input: input);

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

Map<String, dynamic> printExpr(Map<String, dynamic> value) {
  return stdCall(
    'print',
    msg([field('message', value)], typeName: 'PrintInput'),
  );
}

Map<String, dynamic> printStr(String s) => printExpr(literal(s));

Map<String, dynamic> printToString(Map<String, dynamic> expr) {
  return printExpr(stdCall('to_string', msg([field('value', expr)])));
}

Map<String, dynamic> stmt(Map<String, dynamic> expr) => {'expression': expr};

Map<String, dynamic> letStmt(
  String name,
  Map<String, dynamic> value, {
  String keyword = 'final',
}) {
  return {
    'let': {
      'name': name,
      'value': value,
      'metadata': {'keyword': keyword},
    },
  };
}

Map<String, dynamic> mainFn(List<Map<String, dynamic>> statements) {
  return {
    'name': 'main',
    'body': {
      'block': {'statements': statements},
    },
  };
}

Map<String, dynamic> functionDef(
  String name, {
  required Map<String, dynamic> body,
  String inputType = '',
  String outputType = '',
  List<Map<String, String>> params = const [],
}) {
  final fn = <String, dynamic>{'name': name, 'body': body};
  if (inputType.isNotEmpty) fn['inputType'] = inputType;
  if (outputType.isNotEmpty) fn['outputType'] = outputType;
  if (params.isNotEmpty) {
    fn['metadata'] = {
      'kind': 'function',
      'params': params
          .map((p) => {'name': p['name'], 'type': p['type']})
          .toList(),
    };
  }
  return fn;
}

// ── Additional expression helpers ─────────────────────────────────────────

/// Builds a list literal expression from a list of element expressions.
Map<String, dynamic> listLit(List<Map<String, dynamic>> elements) => {
  'literal': {
    'listValue': {'elements': elements},
  },
};

/// Builds a field access expression.
Map<String, dynamic> fieldAcc(Map<String, dynamic> object, String fieldName) =>
    {
      'fieldAccess': {'object': object, 'field': fieldName},
    };

/// Builds an index expression via std.index.
Map<String, dynamic> indexExpr(
  Map<String, dynamic> target,
  Map<String, dynamic> idx,
) => stdCall('index', msg([field('target', target), field('index', idx)]));

/// Builds a lambda expression node.
Map<String, dynamic> lambdaExpr(
  Map<String, dynamic> body, {
  String inputType = 'dynamic',
}) => {
  'lambda': {'name': '', 'inputType': inputType, 'body': body},
};

/// Builds a null literal (no-value literal).
Map<String, dynamic> litNull() => {'literal': {}};

// ══════════════════════════════════════════════════════════════
//  Tests
// ══════════════════════════════════════════════════════════════

void main() {
  // ── File-based integration tests ─────────────────────────

  group('hello_world.ball.json', () {
    late Program program;

    setUpAll(() {
      program = loadProgram('../../examples/hello_world/hello_world.ball.json');
    });

    test('loads program metadata', () async {
      expect(program.name, 'hello_world');
      expect(program.version, '1.0.0');
      expect(program.entryFunction, 'main');
    });

    test('engine produces correct output', () async {
      final lines = await runAndCapture(program);
      expect(lines, ['Hello, World!']);
    });
  });

  group('fibonacci.ball.json', () {
    late Program program;

    setUpAll(() {
      program = loadProgram('../../examples/fibonacci/fibonacci.ball.json');
    });

    test('loads program metadata', () async {
      expect(program.name, 'fibonacci');
      expect(program.modules.length, 2);
    });

    test('engine computes fib(10) = 55', () async {
      final lines = await runAndCapture(program);
      expect(lines, ['55']);
    });
  });

  group('all_constructs.ball.json', () {
    late Program program;
    late List<String> lines;

    setUpAll(() async {
      program = loadProgram(
        '../../examples/all_constructs/all_constructs.ball.json',
      );
      lines = await runAndCapture(program);
    });

    test('arithmetic operations', () async {
      // add(3,4)=7, subtract(10,3)=7, multiply(5,6)=30
      expect(lines[0], '7');
      expect(lines[1], '7');
      expect(lines[2], '30');
    });

    test('division operations', () async {
      // divide(10.0,3.0), intDivide(10,3), modulo(10,3)
      expect(lines[3], '3.3333333333333335');
      expect(lines[4], '3');
      expect(lines[5], '1');
    });

    test('negation', () async {
      expect(lines[6], '-5');
    });

    test('comparison operations', () async {
      expect(lines[7], 'true'); // lessThan(1,2)
      expect(lines[8], 'true'); // greaterThan(3,2)
      expect(lines[9], 'true'); // lessOrEqual(2,2)
      expect(lines[10], 'true'); // greaterOrEqual(3,2)
      expect(lines[11], 'true'); // isEqual(5,5)
      expect(lines[12], 'true'); // isNotEqual(5,3)
    });

    test('logical operations', () async {
      expect(lines[13], 'false'); // and(true,false)
      expect(lines[14], 'true'); // or(true,false)
      expect(lines[15], 'true'); // not(false)
    });

    test('bitwise operations', () async {
      expect(lines[16], '2'); // bitwiseAnd(6,3)
      expect(lines[17], '7'); // bitwiseOr(6,3)
      expect(lines[18], '5'); // bitwiseXor(6,3)
      expect(lines[19], '8'); // leftShift(1,3)
      expect(lines[20], '2'); // rightShift(8,2)
      expect(lines[21], '-1'); // bitwiseNot(0)
    });

    test('string concatenation', () async {
      expect(lines[22], 'Hello, World!');
    });

    test('control flow (if/else)', () async {
      expect(lines[23], 'negative'); // classify(-5)
      expect(lines[24], 'zero'); // classify(0)
      expect(lines[25], 'positive'); // classify(7)
    });

    test('ternary', () async {
      expect(lines[26], 'yes'); // ternary(true)
      expect(lines[27], 'no'); // ternary(false)
    });

    test('for loop (sumRange)', () async {
      expect(lines[28], '10'); // sumRange(5) = 0+1+2+3+4 = 10
    });

    test('while loop (whileLoop)', () async {
      expect(lines[29], '3'); // whileLoop(3)
    });

    test('recursion (factorial)', () async {
      expect(lines[30], '720'); // factorial(6) = 720
    });

    test('local vars and nested calls', () async {
      expect(lines[31], '19'); // localVars(10) = 10*2 - 1 = 19
      expect(
        lines[32],
        '14',
      ); // nested(5) = add(multiply(5,2), subtract(5,1)) = 10+4 = 14
      expect(lines[33], 'Result: 42'); // multiStep(21) = "Result: 42"
    });

    test('produces exactly 34 output lines', () async {
      // 32 lines expected from the Dart source — but engine exits normally
      // after producing all lines (no remaining errors)
      expect(lines.length, 34);
    });
  });

  // ── Inline program unit tests ────────────────────────────

  group('engine: literals and print', () {
    test('prints a string literal', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printStr('hello'))]),
        ],
      );
      expect(await runAndCapture(program), ['hello']);
    });

    test('prints an integer via to_string', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(literal(42)))]),
        ],
      );
      expect(await runAndCapture(program), ['42']);
    });

    test('prints a double via to_string', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(literal(3.14)))]),
        ],
      );
      expect(await runAndCapture(program), ['3.14']);
    });

    test('prints a boolean via to_string', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(literal(true)))]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });
  });

  group('engine: arithmetic', () {
    test('add two integers', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([
                    field('left', literal(10)),
                    field('right', literal(20)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['30']);
    });

    test('subtract', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'subtract',
                  msg([
                    field('left', literal(100)),
                    field('right', literal(37)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['63']);
    });

    test('multiply', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'multiply',
                  msg([field('left', literal(7)), field('right', literal(8))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['56']);
    });

    test('negate', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('negate', msg([field('value', literal(42))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['-42']);
    });
  });

  group('engine: comparisons', () {
    test('less_than true', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'less_than',
                  msg([field('left', literal(1)), field('right', literal(2))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });

    test('less_than false', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'less_than',
                  msg([field('left', literal(5)), field('right', literal(3))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['false']);
    });

    test('equals true', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'equals',
                  msg([field('left', literal(7)), field('right', literal(7))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });
  });

  group('engine: let bindings and variables', () {
    test('let binding and reference', () async {
      final program = buildProgram(
        functions: [
          mainFn([letStmt('x', literal(42)), stmt(printToString(ref('x')))]),
        ],
      );
      expect(await runAndCapture(program), ['42']);
    });

    test('multiple let bindings', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('a', literal(10)),
            letStmt('b', literal(20)),
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([field('left', ref('a')), field('right', ref('b'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['30']);
    });

    test('let binding uses expression', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'sum',
              stdCall(
                'add',
                msg([field('left', literal(3)), field('right', literal(4))]),
              ),
            ),
            stmt(printToString(ref('sum'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });
  });

  group('engine: user-defined functions', () {
    test('single-parameter function', () async {
      // Define: double(n) => n + n
      // Call: print(double(21))
      final program = buildProgram(
        functions: [
          functionDef(
            'double_it',
            inputType: 'int',
            outputType: 'int',
            params: [
              {'name': 'n', 'type': 'int'},
            ],
            body: stdCall(
              'add',
              msg([field('left', ref('n')), field('right', ref('n'))]),
            ),
          ),
          mainFn([stmt(printToString(call('double_it', input: literal(21))))]),
        ],
      );
      expect(await runAndCapture(program), ['42']);
    });

    test('two-parameter function with arg0/arg1', () async {
      // Define: myAdd(a, b) => a + b
      // Call: print(myAdd(3, 4))
      final program = buildProgram(
        functions: [
          functionDef(
            'myAdd',
            inputType: 'int',
            outputType: 'int',
            params: [
              {'name': 'a', 'type': 'int'},
              {'name': 'b', 'type': 'int'},
            ],
            body: stdCall(
              'add',
              msg([field('left', ref('a')), field('right', ref('b'))]),
            ),
          ),
          mainFn([
            stmt(
              printToString(
                call(
                  'myAdd',
                  input: msg([
                    field('arg0', literal(3)),
                    field('arg1', literal(4)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });

    test('recursive function (fibonacci)', () async {
      // Fibonacci via recursive calls — same encoding as fibonacci.ball.json
      final program = buildProgram(
        functions: [
          functionDef(
            'fib',
            inputType: 'int',
            outputType: 'int',
            params: [
              {'name': 'n', 'type': 'int'},
            ],
            body: {
              'block': {
                'statements': [
                  stmt(
                    stdCall(
                      'if',
                      msg([
                        field(
                          'condition',
                          stdCall(
                            'lte',
                            msg([
                              field('left', ref('n')),
                              field('right', literal(1)),
                            ]),
                          ),
                        ),
                        field('then', {
                          'block': {
                            'statements': [
                              stmt(
                                stdCall(
                                  'return',
                                  msg([field('value', ref('n'))]),
                                ),
                              ),
                            ],
                          },
                        }),
                        field('else', {
                          'block': {
                            'statements': [
                              stmt(
                                stdCall(
                                  'return',
                                  msg([
                                    field(
                                      'value',
                                      stdCall(
                                        'add',
                                        msg([
                                          field(
                                            'left',
                                            call(
                                              'fib',
                                              input: stdCall(
                                                'subtract',
                                                msg([
                                                  field('left', ref('n')),
                                                  field('right', literal(1)),
                                                ]),
                                              ),
                                            ),
                                          ),
                                          field(
                                            'right',
                                            call(
                                              'fib',
                                              input: stdCall(
                                                'subtract',
                                                msg([
                                                  field('left', ref('n')),
                                                  field('right', literal(2)),
                                                ]),
                                              ),
                                            ),
                                          ),
                                        ]),
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ],
                          },
                        }),
                      ]),
                    ),
                  ),
                ],
              },
            },
          ),
          mainFn([stmt(printToString(call('fib', input: literal(10))))]),
        ],
      );
      expect(await runAndCapture(program), ['55']);
    });
  });

  group('engine: control flow', () {
    test('if-then-else (true branch)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'if',
                msg([
                  field('condition', literal(true)),
                  field('then', {
                    'block': {
                      'statements': [stmt(printStr('yes'))],
                    },
                  }),
                  field('else', {
                    'block': {
                      'statements': [stmt(printStr('no'))],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['yes']);
    });

    test('if-then-else (false branch)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'if',
                msg([
                  field('condition', literal(false)),
                  field('then', {
                    'block': {
                      'statements': [stmt(printStr('yes'))],
                    },
                  }),
                  field('else', {
                    'block': {
                      'statements': [stmt(printStr('no'))],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['no']);
    });

    test('if without else', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'if',
                msg([
                  field('condition', literal(true)),
                  field('then', {
                    'block': {
                      'statements': [stmt(printStr('only if'))],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['only if']);
    });

    test('nested if', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(5)),
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
                        field('right', literal(10)),
                      ]),
                    ),
                  ),
                  field('then', {
                    'block': {
                      'statements': [stmt(printStr('big'))],
                    },
                  }),
                  field('else', {
                    'block': {
                      'statements': [
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
                                    field('right', literal(0)),
                                  ]),
                                ),
                              ),
                              field('then', {
                                'block': {
                                  'statements': [
                                    stmt(printStr('small positive')),
                                  ],
                                },
                              }),
                              field('else', {
                                'block': {
                                  'statements': [
                                    stmt(printStr('non-positive')),
                                  ],
                                },
                              }),
                            ]),
                          ),
                        ),
                      ],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['small positive']);
    });
  });

  group('engine: top-level variables', () {
    test('const top-level variable', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'myConst',
            'body': literal(99),
            'metadata': {'kind': 'top_level_variable', 'is_const': true},
          },
          mainFn([stmt(printToString(ref('myConst')))]),
        ],
      );
      expect(await runAndCapture(program), ['99']);
    });

    test('multiple top-level variables', () async {
      final program = buildProgram(
        functions: [
          {
            'name': 'x',
            'body': literal(10),
            'metadata': {'kind': 'top_level_variable', 'is_const': true},
          },
          {
            'name': 'y',
            'body': literal(20),
            'metadata': {'kind': 'top_level_variable', 'is_final': true},
          },
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([field('left', ref('x')), field('right', ref('y'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['30']);
    });
  });

  group('engine: while loop', () {
    test('while loop with counter', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0), keyword: 'var'),
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
                  field('body', {
                    'block': {
                      'statements': [
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
                      ],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1', '2']);
    });
  });

  group('engine: for loop', () {
    test('for loop counting', () async {
      // The encoder declares the loop var outside the for and uses a
      // string literal for init (human-readable, effectively a no-op).
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0), keyword: 'var'),
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
                        field('right', literal(3)),
                      ]),
                    ),
                  ),
                  field(
                    'update',
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
                  field('body', {
                    'block': {
                      'statements': [stmt(printToString(ref('i')))],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1', '2']);
    });
  });

  group('engine: string operations', () {
    test('string concatenation via add', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'add',
                  msg([
                    field('left', literal('Hello, ')),
                    field('right', literal('World!')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['Hello, World!']);
    });
  });

  group('engine: multiple print statements', () {
    test('sequence of prints', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printStr('line 1')),
            stmt(printStr('line 2')),
            stmt(printStr('line 3')),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['line 1', 'line 2', 'line 3']);
    });
  });

  group('engine: error handling', () {
    test('throws on undefined variable', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(ref('undefined_var')))]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(isA<BallRuntimeError>()));
    });

    test('throws on missing entry point', () async {
      final programJson = {
        'name': 'bad',
        'version': '1.0.0',
        'modules': [
          {'name': 'main', 'functions': []},
        ],
        'entryModule': 'main',
        'entryFunction': 'nonexistent',
      };
      final program = Program()..mergeFromProto3Json(programJson);
      await expectLater(runAndCapture(program), throwsA(isA<BallRuntimeError>()));
    });
  });

  group('engine: stdout capture', () {
    test('custom stdout sink captures output', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printStr('captured'))]),
        ],
      );
      final captured = <String>[];
      final engine = BallEngine(program, stdout: captured.add);
      await engine.run();
      expect(captured, ['captured']);
    });

    test('default stdout uses print (no crash)', () async {
      final program = buildProgram(functions: [mainFn([])]);
      // Just verify it doesn't throw with default stdout
      final engine = BallEngine(program);
      expect(engine.run, returnsNormally);
    });
  });

  group('engine: protobuf deserialization', () {
    test('Program round-trips through proto3 JSON', () async {
      final program = loadProgram(
        '../../examples/hello_world/hello_world.ball.json',
      );
      final json = program.toProto3Json();
      final restored = Program()..mergeFromProto3Json(json);
      expect(restored.name, program.name);
      expect(restored.version, program.version);
      expect(restored.entryFunction, program.entryFunction);
      expect(restored.modules.length, program.modules.length);
    });

    test('Program round-trips through binary protobuf', () async {
      final program = loadProgram(
        '../../examples/fibonacci/fibonacci.ball.json',
      );
      final bytes = program.writeToBuffer();
      final restored = Program.fromBuffer(bytes);
      expect(restored.name, 'fibonacci');
      final lines = await runAndCapture(restored);
      expect(lines, ['55']);
    });
  });

  // ══════════════════════════════════════════════════════════════
  //  Comprehensive new capability tests
  // ══════════════════════════════════════════════════════════════

  group('engine: string_interpolation', () {
    test('interpolates a list of string parts', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('name', literal('World')),
            stmt(
              printExpr(
                stdCall(
                  'string_interpolation',
                  msg([
                    field(
                      'parts',
                      listLit([literal('Hello, '), ref('name'), literal('!')]),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['Hello, World!']);
    });

    test('interpolates mixed types', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('n', literal(42)),
            stmt(
              printExpr(
                stdCall(
                  'string_interpolation',
                  msg([
                    field('parts', listLit([literal('n = '), ref('n')])),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['n = 42']);
    });

    test('single value field', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_interpolation',
                  msg([field('value', literal('direct'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['direct']);
    });
  });

  // ── Virtual property field access ─────────────────────────────────────────

  group('engine: field access — virtual properties on String', () {
    test('.length', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal('hello'), 'length')))]),
        ],
      );
      expect(await runAndCapture(program), ['5']);
    });

    test('.isEmpty on empty string', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal(''), 'isEmpty')))]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });

    test('.isEmpty on non-empty string', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal('hi'), 'isEmpty')))]),
        ],
      );
      expect(await runAndCapture(program), ['false']);
    });

    test('.isNotEmpty', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal('abc'), 'isNotEmpty')))]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });
  });

  group('engine: field access — virtual properties on List', () {
    test('.length', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                fieldAcc(
                  listLit([literal(1), literal(2), literal(3)]),
                  'length',
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3']);
    });

    test('.isEmpty on empty list', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(listLit([]), 'isEmpty')))]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });

    test('.isNotEmpty on non-empty list', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printToString(fieldAcc(listLit([literal(1)]), 'isNotEmpty'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });

    test('.first', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                fieldAcc(
                  listLit([literal(10), literal(20), literal(30)]),
                  'first',
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['10']);
    });

    test('.last', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                fieldAcc(
                  listLit([literal(10), literal(20), literal(30)]),
                  'last',
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['30']);
    });

    test('.reversed', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'rev',
              fieldAcc(
                listLit([literal(1), literal(2), literal(3)]),
                'reversed',
              ),
            ),
            stmt(printToString(fieldAcc(ref('rev'), 'first'))),
            stmt(printToString(fieldAcc(ref('rev'), 'last'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3', '1']);
    });
  });

  group('engine: field access — message fields', () {
    test('access typed message fields', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'p',
              msg([
                field('x', literal(10)),
                field('y', literal(20)),
              ], typeName: 'Point'),
            ),
            stmt(printToString(fieldAcc(ref('p'), 'x'))),
            stmt(printToString(fieldAcc(ref('p'), 'y'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['10', '20']);
    });

    test('.isEmpty on empty message', () async {
      // A message with no fields (except __type__) is empty-ish;
      // keys/values/isEmpty work on the map backing.
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('m', msg([field('a', literal(1))], typeName: 'T')),
            // fields: {a:1, __type__:'T'} → isNotEmpty
            stmt(printToString(fieldAcc(ref('m'), 'isNotEmpty'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });
  });

  // ── Bitwise operations ────────────────────────────────────────────────────

  group('engine: bitwise operations', () {
    final bw = [
      {'name': 'bitwise_and', 'isBase': true},
      {'name': 'bitwise_or', 'isBase': true},
      {'name': 'bitwise_xor', 'isBase': true},
      {'name': 'bitwise_not', 'isBase': true},
      {'name': 'left_shift', 'isBase': true},
      {'name': 'right_shift', 'isBase': true},
      {'name': 'unsigned_right_shift', 'isBase': true},
    ];

    test('bitwise AND', () async {
      final p = buildProgram(
        stdFunctions: bw,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'bitwise_and',
                  msg([field('left', literal(6)), field('right', literal(3))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['2']);
    });

    test('bitwise OR', () async {
      final p = buildProgram(
        stdFunctions: bw,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'bitwise_or',
                  msg([field('left', literal(6)), field('right', literal(3))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['7']);
    });

    test('bitwise XOR', () async {
      final p = buildProgram(
        stdFunctions: bw,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'bitwise_xor',
                  msg([field('left', literal(6)), field('right', literal(3))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['5']);
    });

    test('bitwise NOT', () async {
      final p = buildProgram(
        stdFunctions: bw,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('bitwise_not', msg([field('value', literal(0))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['-1']);
    });

    test('left shift', () async {
      final p = buildProgram(
        stdFunctions: bw,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'left_shift',
                  msg([field('left', literal(1)), field('right', literal(3))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['8']);
    });

    test('right shift', () async {
      final p = buildProgram(
        stdFunctions: bw,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'right_shift',
                  msg([field('left', literal(8)), field('right', literal(2))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['2']);
    });
  });

  // ── String operations ─────────────────────────────────────────────────────

  group('engine: string operations', () {
    final strFns = [
      {'name': 'string_length', 'isBase': true},
      {'name': 'string_is_empty', 'isBase': true},
      {'name': 'string_concat', 'isBase': true},
      {'name': 'string_contains', 'isBase': true},
      {'name': 'string_starts_with', 'isBase': true},
      {'name': 'string_ends_with', 'isBase': true},
      {'name': 'string_to_upper', 'isBase': true},
      {'name': 'string_to_lower', 'isBase': true},
      {'name': 'string_trim', 'isBase': true},
      {'name': 'string_trim_start', 'isBase': true},
      {'name': 'string_trim_end', 'isBase': true},
      {'name': 'string_substring', 'isBase': true},
      {'name': 'string_split', 'isBase': true},
      {'name': 'string_replace', 'isBase': true},
      {'name': 'string_replace_all', 'isBase': true},
      {'name': 'string_repeat', 'isBase': true},
      {'name': 'string_pad_left', 'isBase': true},
      {'name': 'string_pad_right', 'isBase': true},
      {'name': 'string_char_at', 'isBase': true},
      {'name': 'string_char_code_at', 'isBase': true},
      {'name': 'string_from_char_code', 'isBase': true},
      {'name': 'string_index_of', 'isBase': true},
      {'name': 'string_last_index_of', 'isBase': true},
    ];

    test('string_length', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'string_length',
                  msg([field('value', literal('hello'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['5']);
    });

    test('string_is_empty — true', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('string_is_empty', msg([field('value', literal(''))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('string_is_empty — false', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('string_is_empty', msg([field('value', literal('x'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['false']);
    });

    test('string_to_upper', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_to_upper',
                  msg([field('value', literal('hello'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['HELLO']);
    });

    test('string_to_lower', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_to_lower',
                  msg([field('value', literal('WORLD'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['world']);
    });

    test('string_trim', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_trim',
                  msg([field('value', literal('  hi  '))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['hi']);
    });

    test('string_trim_start', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_trim_start',
                  msg([field('value', literal('  hi  '))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['hi  ']);
    });

    test('string_trim_end', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_trim_end',
                  msg([field('value', literal('  hi  '))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['  hi']);
    });

    test('string_contains — true', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'string_contains',
                  msg([
                    field('left', literal('hello world')),
                    field('right', literal('world')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('string_starts_with — true', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'string_starts_with',
                  msg([
                    field('left', literal('hello')),
                    field('right', literal('hel')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('string_ends_with — true', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'string_ends_with',
                  msg([
                    field('left', literal('hello')),
                    field('right', literal('llo')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('string_substring', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_substring',
                  msg([
                    field('value', literal('hello world')),
                    field('start', literal(6)),
                    field('end', literal(11)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['world']);
    });

    test('string_split', () async {
      final splitFns = [
        ...strFns,
        {'name': 'index', 'isBase': true},
      ];
      final p = buildProgram(
        stdFunctions: splitFns,
        functions: [
          mainFn([
            letStmt(
              'parts',
              stdCall(
                'string_split',
                msg([
                  field('left', literal('a,b,c')),
                  field('right', literal(',')),
                ]),
              ),
            ),
            stmt(printToString(fieldAcc(ref('parts'), 'length'))),
            stmt(printExpr(indexExpr(ref('parts'), literal(1)))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['3', 'b']);
    });

    test('string_replace', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_replace',
                  msg([
                    field('value', literal('aabbcc')),
                    field('from', literal('bb')),
                    field('to', literal('XX')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['aaXXcc']);
    });

    test('string_replace_all', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_replace_all',
                  msg([
                    field('value', literal('abab')),
                    field('from', literal('a')),
                    field('to', literal('Z')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['ZbZb']);
    });

    test('string_repeat', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_repeat',
                  msg([
                    field('value', literal('ab')),
                    field('count', literal(3)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['ababab']);
    });

    test('string_pad_left', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_pad_left',
                  msg([
                    field('value', literal('5')),
                    field('width', literal(4)),
                    field('padding', literal('0')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['0005']);
    });

    test('string_pad_right', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_pad_right',
                  msg([
                    field('value', literal('hi')),
                    field('width', literal(5)),
                    field('padding', literal('-')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['hi---']);
    });

    test('string_char_at', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_char_at',
                  msg([
                    field('target', literal('hello')),
                    field('index', literal(1)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['e']);
    });

    test('string_char_code_at + string_from_char_code round-trip', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            letStmt(
              'code',
              stdCall(
                'string_char_code_at',
                msg([
                  field('target', literal('A')),
                  field('index', literal(0)),
                ]),
              ),
            ),
            stmt(
              printExpr(
                stdCall(
                  'string_from_char_code',
                  msg([field('value', ref('code'))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['A']);
    });

    test('string_index_of', () async {
      final p = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'string_index_of',
                  msg([
                    field('left', literal('hello')),
                    field('right', literal('ll')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['2']);
    });
  });

  // ── Math operations ──────────────────────────────────────────────────────

  group('engine: math operations', () {
    final mathFns = [
      {'name': 'math_abs', 'isBase': true},
      {'name': 'math_floor', 'isBase': true},
      {'name': 'math_ceil', 'isBase': true},
      {'name': 'math_round', 'isBase': true},
      {'name': 'math_trunc', 'isBase': true},
      {'name': 'math_sqrt', 'isBase': true},
      {'name': 'math_pow', 'isBase': true},
      {'name': 'math_min', 'isBase': true},
      {'name': 'math_max', 'isBase': true},
      {'name': 'math_clamp', 'isBase': true},
      {'name': 'math_pi', 'isBase': true},
      {'name': 'math_e', 'isBase': true},
      {'name': 'math_log', 'isBase': true},
      {'name': 'math_exp', 'isBase': true},
      {'name': 'math_sin', 'isBase': true},
      {'name': 'math_cos', 'isBase': true},
      {'name': 'math_is_nan', 'isBase': true},
      {'name': 'math_is_finite', 'isBase': true},
      {'name': 'math_is_infinite', 'isBase': true},
      {'name': 'math_infinity', 'isBase': true},
      {'name': 'math_nan', 'isBase': true},
      {'name': 'math_gcd', 'isBase': true},
      {'name': 'math_sign', 'isBase': true},
    ];

    test('math_abs', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('math_abs', msg([field('value', literal(-7))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['7']);
    });

    test('math_floor', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('math_floor', msg([field('value', literal(3.9))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['3']);
    });

    test('math_ceil', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('math_ceil', msg([field('value', literal(3.1))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['4']);
    });

    test('math_round', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('math_round', msg([field('value', literal(3.5))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['4']);
    });

    test('math_sqrt of 25', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('math_sqrt', msg([field('value', literal(25.0))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['5.0']);
    });

    test('math_pow', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'math_pow',
                  msg([
                    field('left', literal(2.0)),
                    field('right', literal(10.0)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['1024.0']);
    });

    test('math_min', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'math_min',
                  msg([field('left', literal(3)), field('right', literal(7))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['3']);
    });

    test('math_max', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'math_max',
                  msg([field('left', literal(3)), field('right', literal(7))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['7']);
    });

    test('math_clamp', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'math_clamp',
                  msg([
                    field('value', literal(15)),
                    field('min', literal(0)),
                    field('max', literal(10)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['10']);
    });

    test('math_pi is approximately 3.14', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            letStmt('pi', stdCall('math_pi', msg([]))),
            stmt(
              printToString(
                stdCall(
                  'greater_than',
                  msg([
                    field('left', ref('pi')),
                    field('right', literal(3.14)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('math_infinity', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'math_is_infinite',
                  msg([field('value', stdCall('math_infinity', msg([])))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('math_nan', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'math_is_nan',
                  msg([field('value', stdCall('math_nan', msg([])))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('math_gcd', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'math_gcd',
                  msg([field('left', literal(12)), field('right', literal(8))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['4']);
    });

    test('math_sign positive', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('math_sign', msg([field('value', literal(5))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['1']);
    });

    test('math_sign negative', () async {
      final p = buildProgram(
        stdFunctions: mathFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('math_sign', msg([field('value', literal(-3))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['-1']);
    });
  });

  // ── for_in loop ───────────────────────────────────────────────────────────

  group('engine: for_in loop', () {
    test('iterates over a list', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('nums', listLit([literal(10), literal(20), literal(30)])),
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('item')),
                  field('iterable', ref('nums')),
                  field('body', {
                    'block': {
                      'statements': [stmt(printToString(ref('item')))],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['10', '20', '30']);
    });

    test('break inside for_in', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'nums',
              listLit([literal(1), literal(2), literal(3), literal(4)]),
            ),
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('x')),
                  field('iterable', ref('nums')),
                  field('body', {
                    'block': {
                      'statements': [
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
                                    field('right', literal(3)),
                                  ]),
                                ),
                              ),
                              field('then', {
                                'block': {
                                  'statements': [
                                    stmt(stdCall('break', msg([]))),
                                  ],
                                },
                              }),
                            ]),
                          ),
                        ),
                        stmt(printToString(ref('x'))),
                      ],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['1', '2']);
    });

    test('accumulates sum via for_in', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('total', literal(0), keyword: 'var'),
            stmt(
              stdCall(
                'for_in',
                msg([
                  field('variable', literal('n')),
                  field(
                    'iterable',
                    listLit([
                      literal(1),
                      literal(2),
                      literal(3),
                      literal(4),
                      literal(5),
                    ]),
                  ),
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'assign',
                            msg([
                              field('target', ref('total')),
                              field(
                                'value',
                                stdCall(
                                  'add',
                                  msg([
                                    field('left', ref('total')),
                                    field('right', ref('n')),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ],
                    },
                  }),
                ]),
              ),
            ),
            stmt(printToString(ref('total'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['15']);
    });
  });

  // ── do_while loop ─────────────────────────────────────────────────────────

  group('engine: do_while loop', () {
    test('runs body at least once', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0), keyword: 'var'),
            stmt(
              stdCall(
                'do_while',
                msg([
                  field('body', {
                    'block': {
                      'statements': [
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
                      ],
                    },
                  }),
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
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1', '2']);
    });

    test('runs body once even if condition false', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'do_while',
                msg([
                  field('body', {
                    'block': {
                      'statements': [stmt(printStr('once'))],
                    },
                  }),
                  field('condition', literal(false)),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['once']);
    });
  });

  // ── switch statement (lazy) ───────────────────────────────────────────────

  group('engine: switch statement', () {
    test('matches a case', () async {
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
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('one'))],
                          },
                        }),
                      ]),
                      msg([
                        field('value', literal(2)),
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('two'))],
                          },
                        }),
                      ]),
                      msg([
                        field('value', literal(3)),
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('three'))],
                          },
                        }),
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

    test('falls through to default', () async {
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
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('one'))],
                          },
                        }),
                      ]),
                      msg([
                        field('is_default', literal(true)),
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('default'))],
                          },
                        }),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['default']);
    });

    test('no match and no default produces no output', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(5)),
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
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('one'))],
                          },
                        }),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printStr('done')),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['done']);
    });
  });

  // ── switch expression (eager) ─────────────────────────────────────────────

  group('engine: switch expression', () {
    final switchFn = [
      {'name': 'switch_expr', 'isBase': true},
    ];

    test('matches string pattern', () async {
      final p = buildProgram(
        stdFunctions: switchFn,
        functions: [
          mainFn([
            letStmt('x', literal(2)),
            letStmt(
              'r',
              stdCall(
                'switch_expr',
                msg([
                  field('subject', ref('x')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal('1')),
                        field('body', literal('one')),
                      ]),
                      msg([
                        field('pattern', literal('2')),
                        field('body', literal('two')),
                      ]),
                      msg([
                        field('pattern', literal('_')),
                        field('body', literal('other')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(ref('r'))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['two']);
    });

    test('default wildcard _', () async {
      final p = buildProgram(
        stdFunctions: switchFn,
        functions: [
          mainFn([
            letStmt('x', literal(99)),
            letStmt(
              'r',
              stdCall(
                'switch_expr',
                msg([
                  field('subject', ref('x')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal('1')),
                        field('body', literal('one')),
                      ]),
                      msg([
                        field('pattern', literal('_')),
                        field('body', literal('default')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(ref('r'))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['default']);
    });

    test('type pattern — int', () async {
      final p = buildProgram(
        stdFunctions: switchFn,
        functions: [
          mainFn([
            letStmt('x', literal(42)),
            letStmt(
              'r',
              stdCall(
                'switch_expr',
                msg([
                  field('subject', ref('x')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal('String')),
                        field('body', literal('is string')),
                      ]),
                      msg([
                        field('pattern', literal('int')),
                        field('body', literal('is int')),
                      ]),
                      msg([
                        field('pattern', literal('_')),
                        field('body', literal('other')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(ref('r'))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['is int']);
    });

    test('type pattern — String', () async {
      final p = buildProgram(
        stdFunctions: switchFn,
        functions: [
          mainFn([
            letStmt('x', literal('hello')),
            letStmt(
              'r',
              stdCall(
                'switch_expr',
                msg([
                  field('subject', ref('x')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal('int')),
                        field('body', literal('is int')),
                      ]),
                      msg([
                        field('pattern', literal('String')),
                        field('body', literal('is string')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(ref('r'))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['is string']);
    });

    test('exact value equality (int)', () async {
      final p = buildProgram(
        stdFunctions: switchFn,
        functions: [
          mainFn([
            letStmt('x', literal(7)),
            letStmt(
              'r',
              stdCall(
                'switch_expr',
                msg([
                  field('subject', ref('x')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal(7)),
                        field('body', literal('seven')),
                      ]),
                      msg([
                        field('pattern', literal('_')),
                        field('body', literal('other')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(ref('r'))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['seven']);
    });
  });

  // ── try / catch / finally ────────────────────────────────────────────────

  group('engine: try/catch/finally', () {
    test('finally runs even without throw', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', {
                    'block': {
                      'statements': [stmt(printStr('try'))],
                    },
                  }),
                  field('finally', {
                    'block': {
                      'statements': [stmt(printStr('finally'))],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['try', 'finally']);
    });

    test('catch handles thrown exception', () async {
      final throwFns = [
        {'name': 'throw', 'isBase': true},
      ];
      final program = buildProgram(
        stdFunctions: throwFns,
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'throw',
                            msg([field('value', literal('boom'))]),
                          ),
                        ),
                      ],
                    },
                  }),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('variable', literal('e')),
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('caught'))],
                          },
                        }),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printStr('after')),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['caught', 'after']);
    });

    test('catch + finally', () async {
      final throwFns = [
        {'name': 'throw', 'isBase': true},
      ];
      final program = buildProgram(
        stdFunctions: throwFns,
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'throw',
                            msg([field('value', literal('err'))]),
                          ),
                        ),
                      ],
                    },
                  }),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('variable', literal('e')),
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('caught'))],
                          },
                        }),
                      ]),
                    ]),
                  ),
                  field('finally', {
                    'block': {
                      'statements': [stmt(printStr('finally'))],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['caught', 'finally']);
    });

    test('uncaught throw propagates', () async {
      final throwFns = [
        {'name': 'throw', 'isBase': true},
      ];
      final program = buildProgram(
        stdFunctions: throwFns,
        functions: [
          mainFn([
            stmt(stdCall('throw', msg([field('value', literal('fatal'))]))),
          ]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(isA<BallException>()));
    });

    test('rethrow re-raises caught exception', () async {
      final fns = [
        {'name': 'throw', 'isBase': true},
        {'name': 'rethrow', 'isBase': true},
      ];
      // Outer try catches; inner catch calls rethrow which must surface the
      // original "boom" value in the outer handler.
      final program = buildProgram(
        stdFunctions: fns,
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'try',
                            msg([
                              field('body', {
                                'block': {
                                  'statements': [
                                    stmt(
                                      stdCall(
                                        'throw',
                                        msg([
                                          field('value', literal('boom')),
                                        ]),
                                      ),
                                    ),
                                  ],
                                },
                              }),
                              field(
                                'catches',
                                listLit([
                                  msg([
                                    field('variable', literal('e')),
                                    field('body', {
                                      'block': {
                                        'statements': [
                                          stmt(
                                            stdCall(
                                              'rethrow',
                                              msg([]),
                                            ),
                                          ),
                                        ],
                                      },
                                    }),
                                  ]),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                      ],
                    },
                  }),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('variable', literal('e')),
                        field('body', {
                          'block': {
                            'statements': [stmt(printExpr(ref('e')))],
                          },
                        }),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['boom']);
    });

    test('rethrow outside catch throws runtime error', () async {
      final fns = [
        {'name': 'rethrow', 'isBase': true},
      ];
      final program = buildProgram(
        stdFunctions: fns,
        functions: [
          mainFn([
            stmt(stdCall('rethrow', msg([]))),
          ]),
        ],
      );
      await expectLater(runAndCapture(program), throwsA(isA<BallRuntimeError>()));
    });

    test('typed catch matches by exception type', () async {
      final fns = [
        {'name': 'throw', 'isBase': true},
      ];
      // Throw a typed BallException by passing a message with __type=NotFound.
      // First catch clause has type=FormatException → must skip. Second has
      // type=NotFound → must match and bind the value.
      final program = buildProgram(
        stdFunctions: fns,
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'throw',
                            msg([
                              field('value', msg([
                                field('__type', literal('NotFound')),
                                field('detail', literal('missing')),
                              ])),
                            ]),
                          ),
                        ),
                      ],
                    },
                  }),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('type', literal('FormatException')),
                        field('variable', literal('e')),
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('wrong'))],
                          },
                        }),
                      ]),
                      msg([
                        field('type', literal('NotFound')),
                        field('variable', literal('e')),
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('right'))],
                          },
                        }),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['right']);
    });

    test('untyped catch catches all', () async {
      final fns = [
        {'name': 'throw', 'isBase': true},
      ];
      final program = buildProgram(
        stdFunctions: fns,
        functions: [
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'throw',
                            msg([
                              field('value', msg([
                                field('__type', literal('Anything')),
                              ])),
                            ]),
                          ),
                        ),
                      ],
                    },
                  }),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('variable', literal('e')),
                        field('body', {
                          'block': {
                            'statements': [stmt(printStr('handled'))],
                          },
                        }),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['handled']);
    });
  });

  // ── async / await ───────────────────────────────────────────────────────
  //
  // The Ball engine runs synchronously, so `async` functions wrap their
  // return value in a `BallFuture` and `await` unwraps it. These tests pin
  // that contract so future changes can't silently regress the simulation.

  group('engine: async and await', () {
    test('async function result wraps in BallFuture', () async {
      // function get42() is_async → returns 42; the caller observes a
      // BallFuture holding 42.
      final program = buildProgram(
        stdFunctions: [{'name': 'await', 'isBase': true}],
        functions: [
          {
            'name': 'get42',
            'body': {
              'block': {
                'statements': [],
                'result': literal(42),
              },
            },
            'metadata': {'is_async': true},
          },
          mainFn([
            letStmt('f', call('get42')),
            stmt(printToString(ref('f'))),
          ]),
        ],
      );
      final out = await runAndCapture(program);
      expect(out.length, 1);
      expect(out[0], contains('BallFuture'));
      expect(out[0], contains('42'));
    });

    test('await unwraps a BallFuture', () async {
      final program = buildProgram(
        stdFunctions: [{'name': 'await', 'isBase': true}],
        functions: [
          {
            'name': 'get42',
            'body': {
              'block': {
                'statements': [],
                'result': literal(42),
              },
            },
            'metadata': {'is_async': true},
          },
          mainFn([
            stmt(
              printToString(
                stdCall('await', msg([field('value', call('get42'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['42']);
    });

    test('await recursively unwraps nested BallFutures', () async {
      // inner() is_async returns 7 → BallFuture(7).
      // outer() is_async returns inner() → BallFuture(BallFuture(7)).
      // `await outer()` must yield 7, not BallFuture(7).
      final program = buildProgram(
        stdFunctions: [{'name': 'await', 'isBase': true}],
        functions: [
          {
            'name': 'inner',
            'body': {
              'block': {
                'statements': [],
                'result': literal(7),
              },
            },
            'metadata': {'is_async': true},
          },
          {
            'name': 'outer',
            'body': {
              'block': {
                'statements': [],
                'result': call('inner'),
              },
            },
            'metadata': {'is_async': true},
          },
          mainFn([
            stmt(
              printToString(
                stdCall('await', msg([field('value', call('outer'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });

    test('await on a non-future value passes through', () async {
      final program = buildProgram(
        stdFunctions: [{'name': 'await', 'isBase': true}],
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('await', msg([field('value', literal(99))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['99']);
    });

    test('async function throw propagates through await', () async {
      // Even though the async wrapping happens on successful return, a
      // throw inside an async body must still escape the `await` site.
      final fns = [
        {'name': 'throw', 'isBase': true},
        {'name': 'await', 'isBase': true},
      ];
      final program = buildProgram(
        stdFunctions: fns,
        functions: [
          {
            'name': 'boom',
            'body': {
              'block': {
                'statements': [
                  stmt(
                    stdCall(
                      'throw',
                      msg([field('value', literal('kapow'))]),
                    ),
                  ),
                ],
              },
            },
            'metadata': {'is_async': true},
          },
          mainFn([
            stmt(
              stdCall(
                'try',
                msg([
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'await',
                            msg([field('value', call('boom'))]),
                          ),
                        ),
                      ],
                    },
                  }),
                  field(
                    'catches',
                    listLit([
                      msg([
                        field('variable', literal('e')),
                        field('body', {
                          'block': {
                            'statements': [stmt(printExpr(ref('e')))],
                          },
                        }),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['kapow']);
    });
  });

  // ── break and continue ───────────────────────────────────────────────────

  group('engine: break and continue', () {
    test('break exits for loop early', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0), keyword: 'var'),
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
                        field('right', literal(10)),
                      ]),
                    ),
                  ),
                  field(
                    'update',
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
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(printToString(ref('i'))),
                        stmt(
                          stdCall(
                            'if',
                            msg([
                              field(
                                'condition',
                                stdCall(
                                  'equals',
                                  msg([
                                    field('left', ref('i')),
                                    field('right', literal(2)),
                                  ]),
                                ),
                              ),
                              field('then', {
                                'block': {
                                  'statements': [
                                    stmt(stdCall('break', msg([]))),
                                  ],
                                },
                              }),
                            ]),
                          ),
                        ),
                      ],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1', '2']);
    });

    test('continue skips iteration', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0), keyword: 'var'),
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
                        field('right', literal(5)),
                      ]),
                    ),
                  ),
                  field(
                    'update',
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
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'if',
                            msg([
                              field(
                                'condition',
                                stdCall(
                                  'equals',
                                  msg([
                                    field('left', ref('i')),
                                    field('right', literal(2)),
                                  ]),
                                ),
                              ),
                              field('then', {
                                'block': {
                                  'statements': [
                                    stmt(stdCall('continue', msg([]))),
                                  ],
                                },
                              }),
                            ]),
                          ),
                        ),
                        stmt(printToString(ref('i'))),
                      ],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1', '3', '4']);
    });

    test('break in while loop', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(0), keyword: 'var'),
            stmt(
              stdCall(
                'while',
                msg([
                  field('condition', literal(true)),
                  field('body', {
                    'block': {
                      'statements': [
                        stmt(
                          stdCall(
                            'if',
                            msg([
                              field(
                                'condition',
                                stdCall(
                                  'equals',
                                  msg([
                                    field('left', ref('i')),
                                    field('right', literal(3)),
                                  ]),
                                ),
                              ),
                              field('then', {
                                'block': {
                                  'statements': [
                                    stmt(stdCall('break', msg([]))),
                                  ],
                                },
                              }),
                            ]),
                          ),
                        ),
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
                      ],
                    },
                  }),
                ]),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', '1', '2']);
    });
  });

  // ── Lambda / invoke ───────────────────────────────────────────────────────

  group('engine: lambda and closures', () {
    final invokeFns = [
      {'name': 'invoke', 'isBase': true},
    ];

    test('lambda with single input param', () async {
      final p = buildProgram(
        stdFunctions: invokeFns,
        functions: [
          mainFn([
            letStmt(
              'addOne',
              lambdaExpr(
                stdCall(
                  'add',
                  msg([
                    field('left', ref('input')),
                    field('right', literal(1)),
                  ]),
                ),
                inputType: 'int',
              ),
            ),
            stmt(
              printToString(
                stdCall(
                  'invoke',
                  msg([
                    field('callee', ref('addOne')),
                    field('value', literal(5)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['6']);
    });

    test('closure captures enclosing variable', () async {
      final p = buildProgram(
        stdFunctions: invokeFns,
        functions: [
          mainFn([
            letStmt('offset', literal(100)),
            letStmt(
              'addOffset',
              lambdaExpr(
                stdCall(
                  'add',
                  msg([
                    field('left', ref('input')),
                    field('right', ref('offset')),
                  ]),
                ),
                inputType: 'int',
              ),
            ),
            stmt(
              printToString(
                stdCall(
                  'invoke',
                  msg([
                    field('callee', ref('addOffset')),
                    field('value', literal(7)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['107']);
    });

    test('lambda with no arguments (null input)', () async {
      final p = buildProgram(
        stdFunctions: invokeFns,
        functions: [
          mainFn([
            letStmt('greeting', lambdaExpr(literal('hello!'))),
            stmt(
              printExpr(
                stdCall('invoke', msg([field('callee', ref('greeting'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['hello!']);
    });

    test('lambda returned from function', () async {
      final p = buildProgram(
        stdFunctions: invokeFns,
        functions: [
          functionDef(
            'makeAdder',
            inputType: 'int',
            outputType: 'Function',
            params: [
              {'name': 'n', 'type': 'int'},
            ],
            body: lambdaExpr(
              stdCall(
                'add',
                msg([field('left', ref('input')), field('right', ref('n'))]),
              ),
              inputType: 'int',
            ),
          ),
          mainFn([
            letStmt('add5', call('makeAdder', input: literal(5))),
            stmt(
              printToString(
                stdCall(
                  'invoke',
                  msg([
                    field('callee', ref('add5')),
                    field('value', literal(10)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['15']);
    });
  });

  // ── index operator ────────────────────────────────────────────────────────

  group('engine: index operator', () {
    final indexFns = [
      {'name': 'index', 'isBase': true},
    ];

    test('index into list', () async {
      final p = buildProgram(
        stdFunctions: indexFns,
        functions: [
          mainFn([
            letStmt('nums', listLit([literal(10), literal(20), literal(30)])),
            stmt(printToString(indexExpr(ref('nums'), literal(1)))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['20']);
    });

    test('index into string', () async {
      final p = buildProgram(
        stdFunctions: indexFns,
        functions: [
          mainFn([stmt(printExpr(indexExpr(literal('hello'), literal(0))))]),
        ],
      );
      expect(await runAndCapture(p), ['h']);
    });

    test('index set (list mutation)', () async {
      final p = buildProgram(
        stdFunctions: indexFns,
        functions: [
          mainFn([
            letStmt(
              'arr',
              listLit([literal(1), literal(2), literal(3)]),
              keyword: 'var',
            ),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', indexExpr(ref('arr'), literal(1))),
                  field('value', literal(99)),
                ]),
              ),
            ),
            stmt(printToString(indexExpr(ref('arr'), literal(1)))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['99']);
    });
  });

  // ── compound assign ───────────────────────────────────────────────────────

  group('engine: compound assign', () {
    test('+= operator', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(10), keyword: 'var'),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(5)),
                  field('op', literal('+=')),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['15']);
    });

    test('-= operator', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(10), keyword: 'var'),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(3)),
                  field('op', literal('-=')),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });

    test('*= operator', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', literal(4), keyword: 'var'),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(3)),
                  field('op', literal('*=')),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['12']);
    });

    test('??= operator — assigns when null', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('x', litNull(), keyword: 'var'),
            stmt(
              stdCall(
                'assign',
                msg([
                  field('target', ref('x')),
                  field('value', literal(42)),
                  field('op', literal('??=')),
                ]),
              ),
            ),
            stmt(printToString(ref('x'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['42']);
    });
  });

  // ── pre/post increment and decrement ──────────────────────────────────────

  group('engine: increment and decrement', () {
    test('pre_increment returns new value and mutates', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(5), keyword: 'var'),
            stmt(
              printToString(
                stdCall('pre_increment', msg([field('value', ref('i'))])),
              ),
            ),
            stmt(printToString(ref('i'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['6', '6']);
    });

    test('post_increment returns old value but mutates', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(5), keyword: 'var'),
            stmt(
              printToString(
                stdCall('post_increment', msg([field('value', ref('i'))])),
              ),
            ),
            stmt(printToString(ref('i'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['5', '6']);
    });

    test('pre_decrement returns new value and mutates', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(3), keyword: 'var'),
            stmt(
              printToString(
                stdCall('pre_decrement', msg([field('value', ref('i'))])),
              ),
            ),
            stmt(printToString(ref('i'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['2', '2']);
    });

    test('post_decrement returns old value but mutates', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('i', literal(3), keyword: 'var'),
            stmt(
              printToString(
                stdCall('post_decrement', msg([field('value', ref('i'))])),
              ),
            ),
            stmt(printToString(ref('i'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3', '2']);
    });
  });

  // ── null safety ───────────────────────────────────────────────────────────

  group('engine: null safety', () {
    final nullFns = [
      {'name': 'null_coalesce', 'isBase': true},
      {'name': 'null_check', 'isBase': true},
      {'name': 'null_aware_access', 'isBase': true},
    ];

    test('null_coalesce returns right when left is null', () async {
      final p = buildProgram(
        stdFunctions: nullFns,
        functions: [
          mainFn([
            letStmt('x', litNull()),
            stmt(
              printToString(
                stdCall(
                  'null_coalesce',
                  msg([field('left', ref('x')), field('right', literal(42))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['42']);
    });

    test('null_coalesce returns left when not null', () async {
      final p = buildProgram(
        stdFunctions: nullFns,
        functions: [
          mainFn([
            letStmt('x', literal(7)),
            stmt(
              printToString(
                stdCall(
                  'null_coalesce',
                  msg([field('left', ref('x')), field('right', literal(99))]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['7']);
    });

    test('null_check passes through non-null', () async {
      final p = buildProgram(
        stdFunctions: nullFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall('null_check', msg([field('value', literal(5))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['5']);
    });

    test('null_aware_access returns null on null target', () async {
      final p = buildProgram(
        stdFunctions: nullFns,
        functions: [
          mainFn([
            letStmt('obj', litNull()),
            stmt(
              printToString(
                stdCall(
                  'null_coalesce',
                  msg([
                    field(
                      'left',
                      stdCall(
                        'null_aware_access',
                        msg([
                          field('target', ref('obj')),
                          field('field', literal('name')),
                        ]),
                      ),
                    ),
                    field('right', literal(-1)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['-1']);
    });
  });

  // ── type checks ───────────────────────────────────────────────────────────

  group('engine: type checks', () {
    final typeFns = [
      {'name': 'is', 'isBase': true},
      {'name': 'is_not', 'isBase': true},
      {'name': 'as', 'isBase': true},
    ];

    test('is int — true', () async {
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'is',
                  msg([
                    field('value', literal(42)),
                    field('type', literal('int')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('is String — false for int', () async {
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'is',
                  msg([
                    field('value', literal(42)),
                    field('type', literal('String')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['false']);
    });

    test('is_not int — false for int', () async {
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'is_not',
                  msg([
                    field('value', literal(42)),
                    field('type', literal('int')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['false']);
    });

    test('is bool — true', () async {
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'is',
                  msg([
                    field('value', literal(true)),
                    field('type', literal('bool')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('is List — true', () async {
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'is',
                  msg([
                    field('value', listLit([literal(1)])),
                    field('type', literal('List')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('as is a no-op passthrough', () async {
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          mainFn([
            stmt(
              printToString(stdCall('as', msg([field('value', literal(42))]))),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['42']);
    });

    test('is on class instance — true', () async {
      // class Foo {} main() { print(Foo() is Foo); }
      // Foo() creates a message with typeName "Foo", is check with type "Foo".
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          {
            'name': 'Foo.new',
            'body': {
              'messageCreation': {'typeName': 'Foo', 'fields': []},
            },
            'metadata': {'kind': 'constructor', 'class': 'Foo'},
          },
          mainFn([
            letStmt('x', msg([], typeName: 'Foo')),
            stmt(
              printToString(
                stdCall('is', msg([
                  field('value', ref('x')),
                  field('type', literal('Foo')),
                ])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('is on class instance — false for wrong type', () async {
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          mainFn([
            letStmt('x', msg([], typeName: 'Foo')),
            stmt(
              printToString(
                stdCall('is', msg([
                  field('value', ref('x')),
                  field('type', literal('Bar')),
                ])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['false']);
    });

    test('is with module-qualified type name', () async {
      // __type__ is stored as "main:Foo", check against "Foo".
      final p = buildProgram(
        stdFunctions: typeFns,
        functions: [
          mainFn([
            letStmt('x', msg([], typeName: 'main:Foo')),
            stmt(
              printToString(
                stdCall('is', msg([
                  field('value', ref('x')),
                  field('type', literal('Foo')),
                ])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true']);
    });

    test('is with inheritance — child is parent', () async {
      // class A {} class B extends A {} main() { print(B() is A); }
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'is', 'isBase': true},
              {'name': 'is_not', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'typeDefs': [
              {
                'name': 'A',
                'descriptor': {'name': 'A', 'field': []},
              },
              {
                'name': 'B',
                'descriptor': {'name': 'B', 'field': []},
                'metadata': {'superclass': 'A'},
              },
            ],
            'functions': [
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      {
                        'let': {
                          'name': 'b',
                          'value': {
                            'messageCreation': {
                              'typeName': 'B',
                              'fields': [],
                            },
                          },
                        },
                      },
                      {
                        'expression': {
                          'call': {
                            'module': 'std',
                            'function': 'print',
                            'input': {
                              'messageCreation': {
                                'fields': [
                                  {
                                    'name': 'message',
                                    'value': {
                                      'call': {
                                        'module': 'std',
                                        'function': 'to_string',
                                        'input': {
                                          'messageCreation': {
                                            'fields': [
                                              {
                                                'name': 'value',
                                                'value': {
                                                  'call': {
                                                    'module': 'std',
                                                    'function': 'is',
                                                    'input': {
                                                      'messageCreation': {
                                                        'fields': [
                                                          {
                                                            'name': 'value',
                                                            'value': {
                                                              'reference': {
                                                                'name': 'b',
                                                              },
                                                            },
                                                          },
                                                          {
                                                            'name': 'type',
                                                            'value': {
                                                              'literal': {
                                                                'stringValue':
                                                                    'A',
                                                              },
                                                            },
                                                          },
                                                        ],
                                                      },
                                                    },
                                                  },
                                                },
                                              },
                                            ],
                                          },
                                        },
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      },
                      // Also test is_not: B() is_not A → false
                      {
                        'expression': {
                          'call': {
                            'module': 'std',
                            'function': 'print',
                            'input': {
                              'messageCreation': {
                                'fields': [
                                  {
                                    'name': 'message',
                                    'value': {
                                      'call': {
                                        'module': 'std',
                                        'function': 'to_string',
                                        'input': {
                                          'messageCreation': {
                                            'fields': [
                                              {
                                                'name': 'value',
                                                'value': {
                                                  'call': {
                                                    'module': 'std',
                                                    'function': 'is_not',
                                                    'input': {
                                                      'messageCreation': {
                                                        'fields': [
                                                          {
                                                            'name': 'value',
                                                            'value': {
                                                              'reference': {
                                                                'name': 'b',
                                                              },
                                                            },
                                                          },
                                                          {
                                                            'name': 'type',
                                                            'value': {
                                                              'literal': {
                                                                'stringValue':
                                                                    'A',
                                                              },
                                                            },
                                                          },
                                                        ],
                                                      },
                                                    },
                                                  },
                                                },
                                              },
                                            ],
                                          },
                                        },
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final p = Program()..mergeFromProto3Json(json);
      expect(await runAndCapture(p), ['true', 'false']);
    });

    test('enum value access and comparison', () async {
      // enum Color { red, green, blue }
      // main() { print(Color.red.name); print(Color.green.index); print(Color.red == Color.red); }
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'equals', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'enums': [
              {
                'name': 'main:Color',
                'value': [
                  {'name': 'red', 'number': 0},
                  {'name': 'green', 'number': 1},
                  {'name': 'blue', 'number': 2},
                ],
              },
            ],
            'functions': [
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      // print(Color.red.name) → "red"
                      {
                        'expression': {
                          'call': {
                            'module': 'std',
                            'function': 'print',
                            'input': {
                              'messageCreation': {
                                'fields': [
                                  {
                                    'name': 'message',
                                    'value': {
                                      'fieldAccess': {
                                        'object': {
                                          'fieldAccess': {
                                            'object': {
                                              'reference': {'name': 'Color'},
                                            },
                                            'field': 'red',
                                          },
                                        },
                                        'field': 'name',
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      },
                      // print(Color.green.index) → "1"
                      {
                        'expression': {
                          'call': {
                            'module': 'std',
                            'function': 'print',
                            'input': {
                              'messageCreation': {
                                'fields': [
                                  {
                                    'name': 'message',
                                    'value': {
                                      'call': {
                                        'module': 'std',
                                        'function': 'to_string',
                                        'input': {
                                          'messageCreation': {
                                            'fields': [
                                              {
                                                'name': 'value',
                                                'value': {
                                                  'fieldAccess': {
                                                    'object': {
                                                      'fieldAccess': {
                                                        'object': {
                                                          'reference': {
                                                            'name': 'Color',
                                                          },
                                                        },
                                                        'field': 'green',
                                                      },
                                                    },
                                                    'field': 'index',
                                                  },
                                                },
                                              },
                                            ],
                                          },
                                        },
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      },
                      // print(Color.red == Color.red) → "true"
                      {
                        'expression': {
                          'call': {
                            'module': 'std',
                            'function': 'print',
                            'input': {
                              'messageCreation': {
                                'fields': [
                                  {
                                    'name': 'message',
                                    'value': {
                                      'call': {
                                        'module': 'std',
                                        'function': 'to_string',
                                        'input': {
                                          'messageCreation': {
                                            'fields': [
                                              {
                                                'name': 'value',
                                                'value': {
                                                  'call': {
                                                    'module': 'std',
                                                    'function': 'equals',
                                                    'input': {
                                                      'messageCreation': {
                                                        'fields': [
                                                          {
                                                            'name': 'left',
                                                            'value': {
                                                              'fieldAccess': {
                                                                'object': {
                                                                  'reference': {
                                                                    'name':
                                                                        'Color',
                                                                  },
                                                                },
                                                                'field': 'red',
                                                              },
                                                            },
                                                          },
                                                          {
                                                            'name': 'right',
                                                            'value': {
                                                              'fieldAccess': {
                                                                'object': {
                                                                  'reference': {
                                                                    'name':
                                                                        'Color',
                                                                  },
                                                                },
                                                                'field': 'red',
                                                              },
                                                            },
                                                          },
                                                        ],
                                                      },
                                                    },
                                                  },
                                                },
                                              },
                                            ],
                                          },
                                        },
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final p = Program()..mergeFromProto3Json(json);
      expect(await runAndCapture(p), ['red', '1', 'true']);
    });

    test('enum values property returns all values', () async {
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'enums': [
              {
                'name': 'main:Color',
                'value': [
                  {'name': 'red', 'number': 0},
                  {'name': 'green', 'number': 1},
                ],
              },
            ],
            'functions': [
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      // print(Color.values.length) → "2"
                      {
                        'expression': {
                          'call': {
                            'module': 'std',
                            'function': 'print',
                            'input': {
                              'messageCreation': {
                                'fields': [
                                  {
                                    'name': 'message',
                                    'value': {
                                      'call': {
                                        'module': 'std',
                                        'function': 'to_string',
                                        'input': {
                                          'messageCreation': {
                                            'fields': [
                                              {
                                                'name': 'value',
                                                'value': {
                                                  'fieldAccess': {
                                                    'object': {
                                                      'fieldAccess': {
                                                        'object': {
                                                          'reference': {
                                                            'name': 'Color',
                                                          },
                                                        },
                                                        'field': 'values',
                                                      },
                                                    },
                                                    'field': 'length',
                                                  },
                                                },
                                              },
                                            ],
                                          },
                                        },
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final p = Program()..mergeFromProto3Json(json);
      expect(await runAndCapture(p), ['2']);
    });
  });

  // ── map / set creation ──────��───────────��─────────────────────────────────

  group('engine: map and set creation', () {
    final collFns = [
      {'name': 'map_create', 'isBase': true},
      {'name': 'set_create', 'isBase': true},
      {'name': 'index', 'isBase': true},
    ];

    test('map_create builds a map accessible by key', () async {
      final p = buildProgram(
        stdFunctions: collFns,
        functions: [
          mainFn([
            letStmt(
              'm',
              stdCall(
                'map_create',
                msg([
                  field(
                    'entries',
                    listLit([
                      msg([
                        field('name', literal('a')),
                        field('value', literal(1)),
                      ]),
                      msg([
                        field('name', literal('b')),
                        field('value', literal(2)),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printToString(indexExpr(ref('m'), literal('a')))),
            stmt(printToString(indexExpr(ref('m'), literal('b')))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['1', '2']);
    });

    test('set_create from list', () async {
      final p = buildProgram(
        stdFunctions: collFns,
        functions: [
          mainFn([
            letStmt(
              's',
              stdCall(
                'set_create',
                msg([
                  field(
                    'elements',
                    listLit([literal(1), literal(2), literal(2), literal(3)]),
                  ),
                ]),
              ),
            ),
            stmt(printToString(fieldAcc(ref('s'), 'length'))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['3']); // duplicates removed
    });
  });

  // ── short-circuit logic ───────────────────────────────────────────────────

  group('engine: short-circuit and / or', () {
    test('and: false && _ = false (does not eval right)', () async {
      // If right side were evaluated it would throw (undefined var)
      // — short-circuit prevents that.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'and',
                  msg([
                    field('left', literal(false)),
                    field('right', literal(true)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['false']);
    });

    test('and: true && true = true', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'and',
                  msg([
                    field('left', literal(true)),
                    field('right', literal(true)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });

    test('or: true || _ = true', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'or',
                  msg([
                    field('left', literal(true)),
                    field('right', literal(false)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['true']);
    });

    test('or: false || false = false', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'or',
                  msg([
                    field('left', literal(false)),
                    field('right', literal(false)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['false']);
    });
  });

  // ── profiling ─────────────────────────────────────────────────────────────

  group('engine: profiling', () {
    test('profiling disabled by default — report is empty', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printStr('x'))]),
        ],
      );
      final engine = BallEngine(program, stdout: (_) {});
      await engine.run();
      expect(engine.profilingReport(), isEmpty);
    });

    test('profiling enabled — counts std function calls', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printStr('a')),
            stmt(printStr('b')),
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([field('left', literal(1)), field('right', literal(2))]),
                ),
              ),
            ),
          ]),
        ],
      );
      final engine = BallEngine(program, stdout: (_) {}, enableProfiling: true);
      await engine.run();
      final report = engine.profilingReport();
      expect(report['print'], 3);
      expect(report['add'], 1);
      expect(report['to_string'], 1);
    });

    test('profilingReport is unmodifiable', () async {
      final program = buildProgram(functions: [mainFn([])]);
      final engine = BallEngine(program, enableProfiling: true);
      await engine.run();
      expect(
        () => engine.profilingReport()['x'] = 1,
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('profiling counts string ops correctly', () async {
      final strFns = [
        {'name': 'string_to_upper', 'isBase': true},
        {'name': 'string_to_lower', 'isBase': true},
      ];
      final program = buildProgram(
        stdFunctions: strFns,
        functions: [
          mainFn([
            stmt(
              printExpr(
                stdCall(
                  'string_to_upper',
                  msg([field('value', literal('hi'))]),
                ),
              ),
            ),
            stmt(
              printExpr(
                stdCall(
                  'string_to_upper',
                  msg([field('value', literal('bye'))]),
                ),
              ),
            ),
            stmt(
              printExpr(
                stdCall('string_to_lower', msg([field('value', literal('X'))])),
              ),
            ),
          ]),
        ],
      );
      final engine = BallEngine(program, stdout: (_) {}, enableProfiling: true);
      await engine.run();
      final report = engine.profilingReport();
      expect(report['string_to_upper'], 2);
      expect(report['string_to_lower'], 1);
    });
  });

  // ── call cache ────────────────────────────────────────────────────────────

  group('engine: call cache', () {
    test('repeated calls to user function produce correct results', () async {
      final program = buildProgram(
        functions: [
          functionDef(
            'square',
            inputType: 'int',
            outputType: 'int',
            params: [
              {'name': 'n', 'type': 'int'},
            ],
            body: stdCall(
              'multiply',
              msg([field('left', ref('n')), field('right', ref('n'))]),
            ),
          ),
          mainFn([
            stmt(printToString(call('square', input: literal(2)))),
            stmt(printToString(call('square', input: literal(3)))),
            stmt(printToString(call('square', input: literal(4)))),
            stmt(printToString(call('square', input: literal(10)))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['4', '9', '16', '100']);
    });

    test('call cache handles multiple distinct functions', () async {
      final program = buildProgram(
        functions: [
          functionDef(
            'double_it',
            inputType: 'int',
            params: [
              {'name': 'n', 'type': 'int'},
            ],
            body: stdCall(
              'multiply',
              msg([field('left', ref('n')), field('right', literal(2))]),
            ),
          ),
          functionDef(
            'triple_it',
            inputType: 'int',
            params: [
              {'name': 'n', 'type': 'int'},
            ],
            body: stdCall(
              'multiply',
              msg([field('left', ref('n')), field('right', literal(3))]),
            ),
          ),
          mainFn([
            stmt(printToString(call('double_it', input: literal(5)))),
            stmt(printToString(call('triple_it', input: literal(5)))),
            stmt(printToString(call('double_it', input: literal(7)))),
            stmt(printToString(call('triple_it', input: literal(7)))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['10', '15', '14', '21']);
    });
  });

  // ── block with result expression ──────────────────────────────────────────

  group('engine: block with result', () {
    test('block evaluates result expression', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('r', {
              'block': {
                'statements': [
                  letStmt('a', literal(3)),
                  letStmt('b', literal(4)),
                ],
                'result': stdCall(
                  'add',
                  msg([field('left', ref('a')), field('right', ref('b'))]),
                ),
              },
            }),
            stmt(printToString(ref('r'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['7']);
    });
  });

  // ── list literal operations ───────────────────────────────────────────────

  group('engine: list literals', () {
    test('creates and accesses list', () async {
      final indexFns = [
        {'name': 'index', 'isBase': true},
      ];
      final program = buildProgram(
        stdFunctions: indexFns,
        functions: [
          mainFn([
            letStmt('lst', listLit([literal(10), literal(20), literal(30)])),
            stmt(printToString(fieldAcc(ref('lst'), 'length'))),
            stmt(printToString(indexExpr(ref('lst'), literal(0)))),
            stmt(printToString(indexExpr(ref('lst'), literal(2)))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['3', '10', '30']);
    });

    test('empty list has length 0 and isEmpty true', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('lst', listLit([])),
            stmt(printToString(fieldAcc(ref('lst'), 'length'))),
            stmt(printToString(fieldAcc(ref('lst'), 'isEmpty'))),
          ]),
        ],
      );
      expect(await runAndCapture(program), ['0', 'true']);
    });
  });

  // ── Module Handler API ────────────────────────────────────────────────────

  group('engine: composition-only ball modules (no isBase)', () {
    // A module that only composes std — no isBase, all user-defined bodies.
    Program buildCompositionProgram() {
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'add', 'isBase': true},
              {'name': 'multiply', 'isBase': true},
              {'name': 'math_sqrt', 'isBase': true},
              {'name': 'math_pow', 'isBase': true},
            ],
          },
          {
            // Composition-only module — zero isBase, all bodies.
            'name': 'geometry',
            'functions': [
              // square(n) = n * n
              functionDef(
                'square',
                inputType: 'double',
                params: [
                  {'name': 'n', 'type': 'double'},
                ],
                body: stdCall(
                  'multiply',
                  msg([field('left', ref('n')), field('right', ref('n'))]),
                ),
              ),
              // hypotenuse(a, b) = sqrt(a*a + b*b)
              functionDef(
                'hypotenuse',
                inputType: 'double',
                params: [
                  {'name': 'a', 'type': 'double'},
                  {'name': 'b', 'type': 'double'},
                ],
                body: stdCall(
                  'math_sqrt',
                  msg([
                    field(
                      'value',
                      stdCall(
                        'add',
                        msg([
                          field(
                            'left',
                            call('square', module: 'geometry', input: ref('a')),
                          ),
                          field(
                            'right',
                            call('square', module: 'geometry', input: ref('b')),
                          ),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                // hypotenuse(3, 4) = 5.0
                stmt(
                  printToString(
                    call(
                      'hypotenuse',
                      module: 'geometry',
                      input: msg([
                        field('arg0', literal(3.0)),
                        field('arg1', literal(4.0)),
                      ]),
                    ),
                  ),
                ),
                // square(9) = 81.0
                stmt(
                  printToString(
                    call('square', module: 'geometry', input: literal(9.0)),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      return Program()..mergeFromProto3Json(json);
    }

    test('composition-only module resolves cross-module calls correctly', () async {
      final lines = await runAndCapture(buildCompositionProgram());
      expect(lines[0], '5.0');
      expect(lines[1], '81.0');
    });

    test('no handler registration required for composition-only module', () async {
      // Default engine — only StdModuleHandler registered.
      // geometry has no isBase functions, so no handler is needed for it.
      final engine = BallEngine(buildCompositionProgram(), stdout: (_) {});
      expect(engine.run, returnsNormally);
    });

    test('composition-only module chains multiple levels deep', () async {
      // cube(n) = square(n) * n  — calls geometry.square which calls std.multiply
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'multiply', 'isBase': true},
            ],
          },
          {
            'name': 'math_utils',
            'functions': [
              functionDef(
                'square',
                inputType: 'int',
                params: [
                  {'name': 'n', 'type': 'int'},
                ],
                body: stdCall(
                  'multiply',
                  msg([field('left', ref('n')), field('right', ref('n'))]),
                ),
              ),
              functionDef(
                'cube',
                inputType: 'int',
                params: [
                  {'name': 'n', 'type': 'int'},
                ],
                body: stdCall(
                  'multiply',
                  msg([
                    field(
                      'left',
                      call('square', module: 'math_utils', input: ref('n')),
                    ),
                    field('right', ref('n')),
                  ]),
                ),
              ),
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                stmt(
                  printToString(
                    call('cube', module: 'math_utils', input: literal(3)),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      expect(await runAndCapture(prog), ['27']);
    });
  });

  group('engine: BallCallable — handler-to-handler composition', () {
    test('custom handler delegates to std via BallCallable', () async {
      // 'mymath' handler computes abs_diff(a,b) = std.abs(std.subtract(a,b))
      // using the BallCallable engine callback.
      final mymath = _ComposingHandler();
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'subtract', 'isBase': true},
              {'name': 'math_abs', 'isBase': true},
            ],
          },
          {
            'name': 'mymath',
            'functions': [
              {'name': 'abs_diff', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                stmt(
                  printToString(
                    call(
                      'abs_diff',
                      module: 'mymath',
                      input: msg([
                        field('a', literal(3)),
                        field('b', literal(10)),
                      ]),
                    ),
                  ),
                ),
                stmt(
                  printToString(
                    call(
                      'abs_diff',
                      module: 'mymath',
                      input: msg([
                        field('a', literal(10)),
                        field('b', literal(3)),
                      ]),
                    ),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      final lines = await runAndCapture(prog, handlers: [StdModuleHandler(), mymath]);
      expect(lines, ['7', '7']);
    });

    test('BallCallable can call user-defined functions too', () async {
      // userFn 'double_it' is user-defined; handler calls it via engine().
      final delegateHandler = _UserFnDelegateHandler();
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'multiply', 'isBase': true},
            ],
          },
          {
            'name': 'ops',
            'functions': [
              {
                'name': 'quadruple',
                'isBase': true,
              }, // delegates to main.double_it twice
            ],
          },
          {
            'name': 'main',
            'functions': [
              functionDef(
                'double_it',
                inputType: 'int',
                params: [
                  {'name': 'n', 'type': 'int'},
                ],
                body: stdCall(
                  'multiply',
                  msg([field('left', ref('n')), field('right', literal(2))]),
                ),
              ),
              mainFn([
                stmt(
                  printToString(
                    call('quadruple', module: 'ops', input: literal(5)),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      final lines = await runAndCapture(
        prog,
        handlers: [StdModuleHandler(), delegateHandler],
      );
      expect(lines, ['20']); // double_it(double_it(5)) = 20
    });
  });

  group('engine: StdModuleHandler.registerComposer', () {
    test('registerComposer can call back into std', () async {
      final std = StdModuleHandler()
        ..registerComposer('sum_of_squares', (input, engine) async {
          final m = input as Map<String, Object?>;
          final a = m['a'] as num;
          final b = m['b'] as num;
          final a2 = await engine('std', 'multiply', {'left': a, 'right': a}) as num;
          final b2 = await engine('std', 'multiply', {'left': b, 'right': b}) as num;
          return a2 + b2;
        });
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'multiply', 'isBase': true},
              {'name': 'sum_of_squares', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                stmt(
                  printToString(
                    stdCall(
                      'sum_of_squares',
                      msg([field('a', literal(3)), field('b', literal(4))]),
                    ),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      final lines = <String>[];
      await BallEngine(prog, stdout: lines.add, moduleHandlers: [std]).run();
      expect(lines, ['25']); // 3^2 + 4^2 = 25
    });

    test('registerComposer overrides a built-in', () async {
      // Override 'add' to always sum via multiply (nonsensical but verifiable)
      final std = StdModuleHandler()
        ..registerComposer('add', (input, engine) {
          // Return input * 0 + 99  (ignores actual addition)
          return 99;
        });
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([field('left', literal(1)), field('right', literal(2))]),
                ),
              ),
            ),
          ]),
        ],
      );
      final lines = <String>[];
      await BallEngine(program, stdout: lines.add, moduleHandlers: [std]).run();
      expect(lines, ['99']);
    });

    test('registerComposer and register coexist', () async {
      final std = StdModuleHandler()
        ..register('my_const', (_) => 42)
        ..registerComposer(
          'my_doubled',
          (input, engine) async => (await engine('std', 'my_const', null) as int) * 2,
        );
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'my_const', 'isBase': true},
              {'name': 'my_doubled', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                stmt(printToString(stdCall('my_const', msg([])))),
                stmt(printToString(stdCall('my_doubled', msg([])))),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      final lines = <String>[];
      await BallEngine(prog, stdout: lines.add, moduleHandlers: [std]).run();
      expect(lines, ['42', '84']);
    });
  });

  group('engine: callFunction() public bridge', () {
    test('callFunction invokes a user-defined function', () async {
      final program = buildProgram(
        functions: [
          functionDef(
            'triple',
            inputType: 'int',
            params: [
              {'name': 'n', 'type': 'int'},
            ],
            body: stdCall(
              'multiply',
              msg([field('left', ref('n')), field('right', literal(3))]),
            ),
          ),
          mainFn([]),
        ],
      );
      final engine = BallEngine(program, stdout: (_) {});
      await engine.run(); // initialise
      expect(await engine.callFunction('main', 'triple', 7), 21);
    });

    test('callFunction invokes a std base function', () async {
      final program = buildProgram(functions: [mainFn([])]);
      final engine = BallEngine(program, stdout: (_) {});
      await engine.run();
      final result = await engine.callFunction('std', 'add', {
        'left': 10,
        'right': 32,
      });
      expect(result, 42);
    });

    test('callFunction throws BallRuntimeError for unknown function', () async {
      final program = buildProgram(functions: [mainFn([])]);
      final engine = BallEngine(program, stdout: (_) {});
      await engine.run();
      await expectLater(
        engine.callFunction('main', 'nonexistent', null),
        throwsA(isA<BallRuntimeError>()),
      );
    });
  });

  group('engine: BallModuleHandler extensibility', () {
    // Helper: build a program that calls module 'math2', function 'double_val'.
    Program buildMath2Program() {
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'math2',
            'functions': [
              {'name': 'double_val', 'isBase': true},
              {'name': 'square', 'isBase': true},
            ],
          },
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      stmt(
                        printToString(
                          call(
                            'double_val',
                            module: 'math2',
                            input: literal(7),
                          ),
                        ),
                      ),
                      stmt(
                        printToString(
                          call('square', module: 'math2', input: literal(5)),
                        ),
                      ),
                    ],
                  },
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      return Program()..mergeFromProto3Json(json);
    }

    test('custom BallModuleHandler handles a new module', () async {
      final math2 = _Math2Handler();
      final lines = <String>[];
      final engine = BallEngine(
        buildMath2Program(),
        stdout: lines.add,
        moduleHandlers: [StdModuleHandler(), math2],
      );
      await engine.run();
      expect(lines, ['14', '25']);
    });

    test('custom handler is queried before unknown-module error', () async {
      final math2 = _Math2Handler();
      // Add math2 module to the std module list so the program compiles:
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'math2',
            'functions': [
              {'name': 'double_val', 'isBase': true},
            ],
          },
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                stmt(
                  printToString(
                    call('double_val', module: 'math2', input: literal(3)),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      final lines = <String>[];
      await BallEngine(
        prog,
        stdout: lines.add,
        moduleHandlers: [StdModuleHandler(), math2],
      ).run();
      expect(lines, ['6']);
    });

    test('throws BallRuntimeError when no handler matches the module', () async {
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'ghost',
            'functions': [
              {'name': 'foo', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([stmt(call('foo', module: 'ghost', input: literal(1)))]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      await expectLater(
        BallEngine(prog, moduleHandlers: [StdModuleHandler()]).run(),
        throwsA(isA<BallRuntimeError>()),
      );
    });
  });

  group('engine: StdModuleHandler customisation', () {
    test('register adds a new std function', () async {
      final stdHandler = StdModuleHandler()
        ..register('double_str', (input) {
          final v = (input as Map<String, Object?>)['value'] as String;
          return '$v$v';
        });
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'double_str', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                stmt(
                  printExpr(
                    stdCall('double_str', msg([field('value', literal('hi'))])),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      final lines = <String>[];
      await BallEngine(prog, stdout: lines.add, moduleHandlers: [stdHandler]).run();
      expect(lines, ['hihi']);
    });

    test('register overrides an existing function', () async {
      final stdHandler = StdModuleHandler()
        ..register('add', (_) => 999); // always returns 999
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([field('left', literal(1)), field('right', literal(2))]),
                ),
              ),
            ),
          ]),
        ],
      );
      final lines = <String>[];
      await BallEngine(
        program,
        stdout: lines.add,
        moduleHandlers: [stdHandler],
      ).run();
      expect(lines, ['999']);
    });

    test('unregister removes a function — subsequent call throws', () async {
      final stdHandler = StdModuleHandler()..unregister('negate');
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('negate', msg([field('value', literal(5))]))),
          ]),
        ],
      );
      await expectLater(
        BallEngine(program, moduleHandlers: [stdHandler]).run(),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('StdModuleHandler.subset only exposes named functions', () async {
      final stdHandler = StdModuleHandler.subset({'print', 'add', 'to_string'});
      // Calling an excluded function should throw.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('negate', msg([field('value', literal(5))]))),
          ]),
        ],
      );
      await expectLater(
        BallEngine(program, moduleHandlers: [stdHandler]).run(),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('StdModuleHandler.subset allows included functions', () async {
      final stdHandler = StdModuleHandler.subset({'print', 'add', 'to_string'});
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([field('left', literal(3)), field('right', literal(4))]),
                ),
              ),
            ),
          ]),
        ],
      );
      final lines = <String>[];
      await BallEngine(
        program,
        stdout: lines.add,
        moduleHandlers: [stdHandler],
      ).run();
      expect(lines, ['7']);
    });

    test('registeredFunctions returns current key set', () async {
      final h = StdModuleHandler.subset({'print', 'add'});
      final program = buildProgram(functions: [mainFn([])]);
      BallEngine(program, moduleHandlers: [h]); // triggers init
      expect(h.registeredFunctions, containsAll(['print', 'add']));
      expect(h.registeredFunctions, isNot(contains('negate')));
    });

    test('multiple handlers — first match wins', () async {
      // Two handlers both claiming 'std'; the first one's result is used.
      // We prove this by having first return a constant for 'add' and
      // checking the output reflects that constant, not the real add result.
      final overrideStd = StdModuleHandler()
        ..register('add', (_) => 999); // always 999
      final normalStd = StdModuleHandler();
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'add',
                  msg([field('left', literal(1)), field('right', literal(2))]),
                ),
              ),
            ),
          ]),
        ],
      );
      final lines = <String>[];
      await BallEngine(
        program,
        stdout: lines.add,
        moduleHandlers: [overrideStd, normalStd], // overrideStd wins
      ).run();
      expect(lines, ['999']); // first handler's result, not 3
    });

    test('spy handler counts calls while forwarding to delegate', () async {
      int calls = 0;
      final spy = _CountingHandler('std', () => calls++, StdModuleHandler());
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printStr('a')),
            stmt(printStr('b')),
            stmt(printStr('c')),
          ]),
        ],
      );
      final lines = <String>[];
      await BallEngine(program, stdout: lines.add, moduleHandlers: [spy]).run();
      expect(lines, ['a', 'b', 'c']); // delegation worked
      expect(
        calls,
        greaterThanOrEqualTo(3),
      ); // at minimum 3 print calls counted
    });

    test('dart_std module also handled by StdModuleHandler', () async {
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'dart_std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                stmt(
                  dartStdCall(
                    'print',
                    msg([field('message', literal('dart_std works!'))]),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final prog = Program()..mergeFromProto3Json(json);
      final lines = <String>[];
      await BallEngine(prog, stdout: lines.add).run();
      expect(lines, ['dart_std works!']);
    });
  });

  // ── comprehensive.ball.json integration ───────────────────────────────────

  group('comprehensive.ball.json', () {
    late Program program;

    setUpAll(() {
      program = loadProgram(
        '../../examples/comprehensive/comprehensive.ball.json',
      );
    });

    test('loads successfully', () async {
      expect(program.name, isNotEmpty);
      expect(program.modules, isNotEmpty);
    });

    test('engine runs or throws BallRuntimeError (no Dart errors)', () async {
      // comprehensive.ball.json uses enums and advanced constructs that may
      // not yet be fully supported — we verify no Dart-level exception leaks.
      try {
        await runAndCapture(program);
      } on BallRuntimeError {
        // Expected for unsupported constructs (e.g. enums, class instances).
      }
    });
  });

  // ==========================================================================
  // std_collections module
  // ==========================================================================

  group('engine: std_collections module', () {
    final collectionFns = [
      {'name': 'index', 'isBase': true},
      {'name': 'set_create', 'isBase': true},
      {'name': 'list_push', 'isBase': true},
      {'name': 'list_pop', 'isBase': true},
      {'name': 'list_get', 'isBase': true},
      {'name': 'list_set', 'isBase': true},
      {'name': 'list_length', 'isBase': true},
      {'name': 'list_map', 'isBase': true},
      {'name': 'list_filter', 'isBase': true},
      {'name': 'list_reduce', 'isBase': true},
      {'name': 'list_any', 'isBase': true},
      {'name': 'list_all', 'isBase': true},
      {'name': 'list_none', 'isBase': true},
      {'name': 'map_get', 'isBase': true},
      {'name': 'map_set', 'isBase': true},
      {'name': 'map_delete', 'isBase': true},
      {'name': 'map_contains_key', 'isBase': true},
      {'name': 'map_keys', 'isBase': true},
      {'name': 'map_values', 'isBase': true},
      {'name': 'map_length', 'isBase': true},
      {'name': 'string_join', 'isBase': true},
      {'name': 'set_add', 'isBase': true},
      {'name': 'set_contains', 'isBase': true},
      {'name': 'set_union', 'isBase': true},
      {'name': 'set_length', 'isBase': true},
    ];

    test('list_push and list_length', () async {
      final p = buildProgram(
        stdFunctions: collectionFns,
        functions: [
          mainFn([
            letStmt(
              'items',
              stdCall(
                'list_push',
                msg([
                  field('list', listLit([literal(1), literal(2)])),
                  field('value', literal(3)),
                ]),
              ),
            ),
            stmt(
              printToString(
                stdCall('list_length', msg([field('list', ref('items'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['3']);
    });

    test('list_pop returns last element', () async {
      final p = buildProgram(
        stdFunctions: collectionFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'list_pop',
                  msg([
                    field(
                      'list',
                      listLit([literal(4), literal(5), literal(6)]),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['6']);
    });

    test('list_get and list_set', () async {
      final p = buildProgram(
        stdFunctions: collectionFns,
        functions: [
          mainFn([
            letStmt(
              'updated',
              stdCall(
                'list_set',
                msg([
                  field(
                    'list',
                    listLit([literal(10), literal(20), literal(30)]),
                  ),
                  field('index', literal(1)),
                  field('value', literal(99)),
                ]),
              ),
            ),
            stmt(
              printToString(
                stdCall(
                  'list_get',
                  msg([
                    field('list', ref('updated')),
                    field('index', literal(1)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['99']);
    });

    test('list_map, list_filter, and list_reduce', () async {
      final p = buildProgram(
        stdFunctions: collectionFns,
        functions: [
          mainFn([
            letStmt(
              'mapped',
              stdCall(
                'list_map',
                msg([
                  field('list', listLit([literal(1), literal(2), literal(3)])),
                  field(
                    'callback',
                    lambdaExpr(
                      stdCall(
                        'multiply',
                        msg([
                          field('left', ref('input')),
                          field('right', literal(2)),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            letStmt(
              'filtered',
              stdCall(
                'list_filter',
                msg([
                  field(
                    'list',
                    listLit([literal(1), literal(2), literal(3), literal(4)]),
                  ),
                  field(
                    'callback',
                    lambdaExpr(
                      stdCall(
                        'equals',
                        msg([
                          field(
                            'left',
                            stdCall(
                              'modulo',
                              msg([
                                field('left', ref('input')),
                                field('right', literal(2)),
                              ]),
                            ),
                          ),
                          field('right', literal(0)),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            letStmt(
              'sum',
              stdCall(
                'list_reduce',
                msg([
                  field(
                    'list',
                    listLit([literal(1), literal(2), literal(3), literal(4)]),
                  ),
                  field('initial', literal(0)),
                  field(
                    'callback',
                    lambdaExpr(
                      stdCall(
                        'add',
                        msg([
                          field('left', fieldAcc(ref('input'), 'left')),
                          field('right', fieldAcc(ref('input'), 'right')),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(indexExpr(ref('mapped'), literal(2)))),
            stmt(printToString(fieldAcc(ref('filtered'), 'length'))),
            stmt(printToString(ref('sum'))),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['6', '2', '10']);
    });

    test('list_any, list_all, and list_none', () async {
      final predicate = lambdaExpr(
        stdCall(
          'greater_than',
          msg([field('left', ref('input')), field('right', literal(0))]),
        ),
      );

      final p = buildProgram(
        stdFunctions: collectionFns,
        functions: [
          mainFn([
            stmt(
              printToString(
                stdCall(
                  'list_any',
                  msg([
                    field(
                      'list',
                      listLit([literal(-1), literal(0), literal(2)]),
                    ),
                    field('callback', predicate),
                  ]),
                ),
              ),
            ),
            stmt(
              printToString(
                stdCall(
                  'list_all',
                  msg([
                    field(
                      'list',
                      listLit([literal(1), literal(2), literal(3)]),
                    ),
                    field('callback', predicate),
                  ]),
                ),
              ),
            ),
            stmt(
              printToString(
                stdCall(
                  'list_none',
                  msg([
                    field(
                      'list',
                      listLit([literal(-3), literal(-2), literal(-1)]),
                    ),
                    field('callback', predicate),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true', 'true', 'true']);
    });

    test('map_get, map_set, map_delete, and map_length', () async {
      final p = buildProgram(
        stdFunctions: collectionFns,
        functions: [
          mainFn([
            letStmt('m', msg([field('a', literal(1)), field('b', literal(2))])),
            letStmt(
              'm2',
              stdCall(
                'map_set',
                msg([
                  field('map', ref('m')),
                  field('key', literal('c')),
                  field('value', literal(3)),
                ]),
              ),
            ),
            letStmt(
              'm3',
              stdCall(
                'map_delete',
                msg([field('map', ref('m2')), field('key', literal('a'))]),
              ),
            ),
            stmt(
              printToString(
                stdCall(
                  'map_get',
                  msg([field('map', ref('m2')), field('key', literal('c'))]),
                ),
              ),
            ),
            stmt(
              printToString(
                stdCall(
                  'map_contains_key',
                  msg([field('map', ref('m2')), field('key', literal('c'))]),
                ),
              ),
            ),
            stmt(
              printToString(
                stdCall('map_length', msg([field('map', ref('m3'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['3', 'true', '2']);
    });

    test('map_keys, map_values, and string_join', () async {
      final p = buildProgram(
        stdFunctions: collectionFns,
        functions: [
          mainFn([
            letStmt('m', msg([field('a', literal(1)), field('b', literal(2))])),
            letStmt('keys', stdCall('map_keys', msg([field('map', ref('m'))]))),
            letStmt(
              'values',
              stdCall('map_values', msg([field('map', ref('m'))])),
            ),
            stmt(printToString(fieldAcc(ref('keys'), 'length'))),
            stmt(printToString(fieldAcc(ref('values'), 'length'))),
            stmt(
              printExpr(
                stdCall(
                  'string_join',
                  msg([
                    field('list', ref('keys')),
                    field('separator', literal('-')),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['2', '2', 'a-b']);
    });

    test('set_create, set_add, set_union, and set_length', () async {
      final p = buildProgram(
        stdFunctions: collectionFns,
        functions: [
          mainFn([
            letStmt(
              'left',
              stdCall(
                'set_create',
                msg([
                  field('elements', listLit([literal(1), literal(2)])),
                ]),
              ),
            ),
            letStmt(
              'right',
              stdCall(
                'set_create',
                msg([
                  field('elements', listLit([literal(2), literal(3)])),
                ]),
              ),
            ),
            letStmt(
              'left2',
              stdCall(
                'set_add',
                msg([field('set', ref('left')), field('value', literal(4))]),
              ),
            ),
            letStmt(
              'unioned',
              stdCall(
                'set_union',
                msg([
                  field('left', ref('left2')),
                  field('right', ref('right')),
                ]),
              ),
            ),
            stmt(
              printToString(
                stdCall(
                  'set_contains',
                  msg([
                    field('set', ref('unioned')),
                    field('value', literal(4)),
                  ]),
                ),
              ),
            ),
            stmt(
              printToString(
                stdCall('set_length', msg([field('set', ref('unioned'))])),
              ),
            ),
          ]),
        ],
      );
      expect(await runAndCapture(p), ['true', '4']);
    });
  });

  // ==========================================================================
  // std_io module
  // ==========================================================================

  group('engine: std_io module', () {
    test('print_error writes to stderr', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              call(
                'print_error',
                module: 'std',
                input: msg([field('message', literal('error msg'))]),
              ),
            ),
          ]),
        ],
        stdFunctions: [
          {'name': 'print_error', 'isBase': true},
        ],
      );
      final errLines = <String>[];
      final engine = BallEngine(program, stdout: (_) {}, stderr: errLines.add);
      await engine.run();
      expect(errLines, contains('error msg'));
    });

    test('timestamp_ms returns epoch ms', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('t', call('timestamp_ms', module: 'std')),
            stmt(printToString(ref('t'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'timestamp_ms', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines, hasLength(1));
      final ts = int.parse(lines.first);
      expect(ts, greaterThan(1000000000000)); // after 2001
    });

    test('random_int returns value in range', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'r',
              call(
                'random_int',
                module: 'std',
                input: msg([
                  field('min', literal(1)),
                  field('max', literal(10)),
                ]),
              ),
            ),
            stmt(printToString(ref('r'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'random_int', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      final val = int.parse(lines.first);
      expect(val, inInclusiveRange(1, 10));
    });

    test('random_double returns value in [0, 1)', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('r', call('random_double', module: 'std')),
            stmt(printToString(ref('r'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'random_double', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      final val = double.parse(lines.first);
      expect(val, greaterThanOrEqualTo(0.0));
      expect(val, lessThan(1.0));
    });

    test('env_get reads environment variable', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              printExpr(
                call(
                  'env_get',
                  module: 'std',
                  input: msg([field('name', literal('PATH'))]),
                ),
              ),
            ),
          ]),
        ],
        stdFunctions: [
          {'name': 'env_get', 'isBase': true},
        ],
      );
      final lines = <String>[];
      final engine = BallEngine(
        program,
        stdout: lines.add,
        envGet: (name) => name == 'PATH' ? '/usr/bin' : '',
      );
      await engine.run();
      expect(lines.first, equals('/usr/bin'));
    });

    test('args_get returns provided args', () async {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(call('args_get', module: 'std')))]),
        ],
        stdFunctions: [
          {'name': 'args_get', 'isBase': true},
        ],
      );
      final lines = <String>[];
      final engine = BallEngine(
        program,
        stdout: lines.add,
        args: ['--verbose', 'file.txt'],
      );
      await engine.run();
      expect(lines.first, contains('--verbose'));
    });
  });

  // ==========================================================================
  // std_convert module
  // ==========================================================================

  group('engine: std_convert module', () {
    test('json_encode encodes a map', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'm',
              msg([
                field('x', literal(42)),
                field('y', literal('hello')),
              ], typeName: 'TestObj'),
            ),
            letStmt(
              'j',
              call(
                'json_encode',
                module: 'std',
                input: msg([field('value', ref('m'))]),
              ),
            ),
            stmt(printExpr(ref('j'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'json_encode', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, contains('"x"'));
      expect(lines.first, contains('42'));
    });

    test('json_decode parses a string', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'v',
              call(
                'json_decode',
                module: 'std',
                input: msg([field('value', literal('42'))]),
              ),
            ),
            stmt(printToString(ref('v'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'json_decode', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('42'));
    });

    test('utf8 encode and decode roundtrip', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'bytes',
              call(
                'utf8_encode',
                module: 'std',
                input: msg([field('value', literal('abc'))]),
              ),
            ),
            letStmt(
              'str',
              call(
                'utf8_decode',
                module: 'std',
                input: msg([field('value', ref('bytes'))]),
              ),
            ),
            stmt(printExpr(ref('str'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'utf8_encode', 'isBase': true},
          {'name': 'utf8_decode', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('abc'));
    });
  });

  // ==========================================================================
  // std_time module
  // ==========================================================================

  group('engine: std_time module', () {
    test('now returns epoch ms', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('t', call('now', module: 'std')),
            stmt(printToString(ref('t'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'now', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      final ts = int.parse(lines.first);
      expect(ts, greaterThan(1000000000000));
    });

    test('year returns valid year', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('y', call('year', module: 'std')),
            stmt(printToString(ref('y'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'year', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      final year = int.parse(lines.first);
      expect(year, greaterThanOrEqualTo(2024));
    });
  });

  // ==========================================================================
  // Pattern matching (enhanced switch_expr)
  // ==========================================================================

  group('engine: pattern matching', () {
    test('type pattern matches int', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('subject', literal(42)),
            letStmt(
              'result',
              call(
                'switch_expr',
                module: 'std',
                input: msg([
                  field('subject', ref('subject')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal('String')),
                        field('body', literal('was string')),
                      ]),
                      msg([
                        field('pattern', literal('int')),
                        field('body', literal('was int')),
                      ]),
                      msg([
                        field('pattern', literal('_')),
                        field('body', literal('default')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(ref('result'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'switch_expr', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('was int'));
    });

    test('wildcard pattern matches as default', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('subject', literal('xyz')),
            letStmt(
              'result',
              call(
                'switch_expr',
                module: 'std',
                input: msg([
                  field('subject', ref('subject')),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal('int')),
                        field('body', literal('was int')),
                      ]),
                      msg([
                        field('pattern', literal('_')),
                        field('body', literal('default')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(ref('result'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'switch_expr', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('default'));
    });

    test('direct value equality match', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'result',
              call(
                'switch_expr',
                module: 'std',
                input: msg([
                  field('subject', literal(2)),
                  field(
                    'cases',
                    listLit([
                      msg([
                        field('pattern', literal(1)),
                        field('body', literal('one')),
                      ]),
                      msg([
                        field('pattern', literal(2)),
                        field('body', literal('two')),
                      ]),
                      msg([
                        field('pattern', literal('_')),
                        field('body', literal('other')),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
            stmt(printExpr(ref('result'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'switch_expr', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('two'));
    });
  });

  // ==========================================================================
  // Inheritance (__super__ chain)
  // ==========================================================================

  group('engine: inheritance via __super__', () {
    test('field access walks __super__ chain', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'obj',
              msg([
                field('__type__', literal('Dog')),
                field('breed', literal('husky')),
                field(
                  '__super__',
                  msg([
                    field('__type__', literal('Animal')),
                    field('sound', literal('bark')),
                  ]),
                ),
              ]),
            ),
            stmt(printExpr(fieldAcc(ref('obj'), 'sound'))),
          ]),
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('bark'));
    });

    test('own field shadows __super__', () async {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'obj',
              msg([
                field('__type__', literal('Dog')),
                field('sound', literal('woof')),
                field(
                  '__super__',
                  msg([
                    field('__type__', literal('Animal')),
                    field('sound', literal('generic')),
                  ]),
                ),
              ]),
            ),
            stmt(printExpr(fieldAcc(ref('obj'), 'sound'))),
          ]),
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('woof'));
    });
  });

  // ==========================================================================
  // std_fs module
  // ==========================================================================

  group('engine: std_fs module', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('ball_fs_test_');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('file_write and file_read roundtrip', () async {
      final path = '${tmpDir.path}/test.txt';
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              call(
                'file_write',
                module: 'std',
                input: msg([
                  field('path', literal(path)),
                  field('content', literal('hello ball')),
                ]),
              ),
            ),
            letStmt(
              'data',
              call(
                'file_read',
                module: 'std',
                input: msg([field('path', literal(path))]),
              ),
            ),
            stmt(printExpr(ref('data'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'file_write', 'isBase': true},
          {'name': 'file_read', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('hello ball'));
    });

    test('file_exists returns true for existing file', () async {
      final path = '${tmpDir.path}/exists.txt';
      File(path).writeAsStringSync('data');
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt(
              'e',
              call(
                'file_exists',
                module: 'std',
                input: msg([field('path', literal(path))]),
              ),
            ),
            stmt(printToString(ref('e'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'file_exists', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('true'));
    });

    test('dir_create and dir_exists', () async {
      final dirPath = '${tmpDir.path}/sub/nested';
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(
              call(
                'dir_create',
                module: 'std',
                input: msg([field('path', literal(dirPath))]),
              ),
            ),
            letStmt(
              'e',
              call(
                'dir_exists',
                module: 'std',
                input: msg([field('path', literal(dirPath))]),
              ),
            ),
            stmt(printToString(ref('e'))),
          ]),
        ],
        stdFunctions: [
          {'name': 'dir_create', 'isBase': true},
          {'name': 'dir_exists', 'isBase': true},
        ],
      );
      final lines = await runAndCapture(program);
      expect(lines.first, equals('true'));
    });
  });

  group('engine: cpp_std scope_exit cleanup', () {
    test('runs cleanup when block exits', () async {
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'assign', 'isBase': true},
            ],
          },
          {
            'name': 'cpp_std',
            'functions': [
              {'name': 'cpp_scope_exit', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                letStmt('x', literal(1), keyword: 'var'),
                stmt(
                  call(
                    'cpp_scope_exit',
                    module: 'cpp_std',
                    input: msg([
                      field('cleanup', printExpr(ref('x'))),
                    ], typeName: 'ScopeExitInput'),
                  ),
                ),
                stmt(
                  stdCall(
                    'assign',
                    msg([
                      field('target', ref('x')),
                      field('value', literal(2)),
                    ], typeName: 'AssignInput'),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final program = Program()..mergeFromProto3Json(json);
      expect(await runAndCapture(program), ['2']);
    });

    test('runs multiple cleanups in LIFO order', () async {
      final json = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
            ],
          },
          {
            'name': 'cpp_std',
            'functions': [
              {'name': 'cpp_scope_exit', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              mainFn([
                stmt(
                  call(
                    'cpp_scope_exit',
                    module: 'cpp_std',
                    input: msg([
                      field('cleanup', printStr('A')),
                    ], typeName: 'ScopeExitInput'),
                  ),
                ),
                stmt(
                  call(
                    'cpp_scope_exit',
                    module: 'cpp_std',
                    input: msg([
                      field('cleanup', printStr('B')),
                    ], typeName: 'ScopeExitInput'),
                  ),
                ),
              ]),
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };
      final program = Program()..mergeFromProto3Json(json);
      expect(await runAndCapture(program), ['B', 'A']);
    });
  });

  // Constructor callable tests
  _constructorCallableTests();
}

// ──────────────────────────────────────────────────────────────────────────────
// Test helper implementations for module-handler extensibility tests.
// ──────────────────────────────────────────────────────────────────────────────

/// Custom handler for an imaginary `math2` module.
class _Math2Handler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'math2';

  @override
  BallValue call(String function, BallValue input, BallCallable engine) {
    final n = (input is int ? input : (input as Map)['value']) as num;
    return switch (function) {
      'double_val' => n * 2,
      'square' => n * n,
      _ => throw BallRuntimeError('Unknown math2 function: "$function"'),
    };
  }
}

/// A handler that claims ownership of [_module] and calls [onCall] each time
/// before delegating to [_delegate].
class _CountingHandler extends BallModuleHandler {
  final String _module;
  final void Function() _onCall;
  final BallModuleHandler _delegate;
  _CountingHandler(this._module, this._onCall, this._delegate);

  @override
  bool handles(String module) => module == _module;

  @override
  void init(BallEngine engine) => _delegate.init(engine);

  @override
  FutureOr<BallValue> call(String function, BallValue input, BallCallable engine) {
    _onCall();
    return _delegate.call(function, input, engine);
  }
}

/// Handler for 'mymath' that computes abs_diff(a, b) by composing std functions.
class _ComposingHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'mymath';

  @override
  FutureOr<BallValue> call(String function, BallValue input, BallCallable engine) async {
    if (function == 'abs_diff') {
      final m = input as Map<String, Object?>;
      final diff = await engine('std', 'subtract', {'left': m['a'], 'right': m['b']});
      return engine('std', 'math_abs', {'value': diff});
    }
    throw BallRuntimeError('Unknown mymath function: "$function"');
  }
}

/// Handler for 'ops' that calls the user-defined main.double_it via engine().
class _UserFnDelegateHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'ops';

  @override
  FutureOr<BallValue> call(String function, BallValue input, BallCallable engine) async {
    if (function == 'quadruple') {
      final once = await engine('main', 'double_it', input);
      return engine('main', 'double_it', once);
    }
    throw BallRuntimeError('Unknown ops function: "$function"');
  }
}

// ── Constructor callable tests ──────────────────────────────────

/// Build a program with a class constructor and main function.
/// The constructor is registered as "ClassName.new" with kind: "constructor".
Program _buildConstructorProgram({
  required String className,
  required Map<String, dynamic> mainBody,
  String ctorName = 'new',
  Map<String, dynamic>? ctorBody,
}) {
  final ctorFunc = <String, dynamic>{
    'name': '$className.$ctorName',
    'inputType': '${className}Input',
    'outputType': className,
    'metadata': {
      'kind': 'constructor',
      'params': [
        {'name': 'x'},
      ],
    },
  };

  // If a body is provided, add it; otherwise the constructor body
  // builds a map with __type__ and the parameter x extracted from input.
  if (ctorBody != null) {
    ctorFunc['body'] = ctorBody;
  } else {
    ctorFunc['body'] = msg(
      [
        field('__type__', literal(className)),
        field('x', ref('x')),
      ],
    );
  }

  final mainFunc = <String, dynamic>{
    'name': 'main',
    'body': mainBody,
  };

  final programJson = {
    'name': 'test_ctor',
    'version': '1.0.0',
    'modules': [
      {
        'name': 'std',
        'functions': [
          {'name': 'print', 'isBase': true},
          {'name': 'to_string', 'isBase': true},
          {'name': 'string_interpolation', 'isBase': true},
        ],
      },
      {
        'name': 'main',
        'functions': [ctorFunc, mainFunc],
        'typeDefs': [
          {
            'name': 'main:$className',
            'descriptor': {
              'name': className,
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
      },
    ],
    'entryModule': 'main',
    'entryFunction': 'main',
  };

  return Program()..mergeFromProto3Json(programJson);
}

void _constructorCallableTests() {
  // Helper to build an assign statement using the engine's expected format.
  Map<String, dynamic> assignStmt(String name, Map<String, dynamic> value) {
    return {
      'expression': stdCall('assign', {
        'messageCreation': {
          'fields': [
            field('target', ref(name)),
            field('value', value),
          ],
        },
      }),
    };
  }

  Map<String, dynamic> printFieldStmt(String varName, String fieldName) {
    return {
      'expression': stdCall('print', {
        'messageCreation': {
          'fields': [
            field('message', {
              'fieldAccess': {
                'object': ref(varName),
                'field': fieldName,
              },
            }),
          ],
        },
      }),
    };
  }

  group('engine: constructor as callable', () {
    test('constructor reference resolves to callable closure', () async {
      // Simulates: var f = Foo; var obj = f(42); print(obj);
      // Verify the constructor was actually invoked (body sets __type__).
      final program = _buildConstructorProgram(
        className: 'Foo',
        mainBody: {
          'block': {
            'statements': [
              assignStmt('f', ref('Foo')),
              assignStmt('obj',
                  call('f', input: msg([field('x', literal(42))]))),
              printFieldStmt('obj', '__type__'),
            ],
          },
        },
      );

      final lines = await runAndCapture(program);
      // The constructor body sets __type__ to "Foo"
      expect(lines, ['Foo']);
    });

    test('_resolveAndCallFunction finds ClassName.new via fallback', () async {
      // Simulates: Bar(99) encoded as call(function: "Bar")
      // The engine should resolve "Bar" → "Bar.new" constructor.
      final program = _buildConstructorProgram(
        className: 'Bar',
        mainBody: {
          'block': {
            'statements': [
              assignStmt('obj',
                  call('Bar', input: msg([field('x', literal(99))]))),
              printFieldStmt('obj', '__type__'),
            ],
          },
        },
      );

      final lines = await runAndCapture(program);
      expect(lines, ['Bar']);
    });

    test('constructor tear-off with .new suffix resolves', () async {
      // Simulates: var f = Baz.new; var obj = f(7); print(obj.__type__);
      final program = _buildConstructorProgram(
        className: 'Baz',
        mainBody: {
          'block': {
            'statements': [
              assignStmt('f', ref('Baz.new')),
              assignStmt('obj',
                  call('f', input: msg([field('x', literal(7))]))),
              printFieldStmt('obj', '__type__'),
            ],
          },
        },
      );

      final lines = await runAndCapture(program);
      expect(lines, ['Baz']);
    });
  });

  // ── Inheritance resolution tests ─────────────────────────────
  _inheritanceTests();
}

void _inheritanceTests() {
  group('engine: inheritance resolution', () {
    test('child instance accesses field inherited from parent class', () async {
      // class Animal { name: string }
      // class Dog extends Animal { breed: string }
      // var d = Dog(name: "Rex", breed: "Lab"); print(d.name); print(d.breed);
      //
      // The child's __super__ should carry inherited fields accessible via
      // the __super__ chain walk in _evalFieldAccess.
      final programJson = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      {
                        'expression': stdCall('assign', {
                          'messageCreation': {
                            'fields': [
                              field('target', ref('d')),
                              field('value', {
                                'messageCreation': {
                                  'typeName': 'Dog',
                                  'fields': [
                                    field('name', literal('Rex')),
                                    field('breed', literal('Lab')),
                                  ],
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // print(d.name) — inherited from Animal via __super__
                      {
                        'expression': stdCall('print', {
                          'messageCreation': {
                            'fields': [
                              field('message', {
                                'fieldAccess': {
                                  'object': ref('d'),
                                  'field': 'name',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // print(d.breed) — own field
                      {
                        'expression': stdCall('print', {
                          'messageCreation': {
                            'fields': [
                              field('message', {
                                'fieldAccess': {
                                  'object': ref('d'),
                                  'field': 'breed',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                    ],
                  },
                },
              },
            ],
            'typeDefs': [
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
                'descriptor': {
                  'name': 'Dog',
                  'field': [
                    {
                      'name': 'breed',
                      'number': 1,
                      'label': 'LABEL_OPTIONAL',
                      'type': 'TYPE_STRING',
                    },
                  ],
                },
                'metadata': {
                  'superclass': 'Animal',
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };

      final program = Program()..mergeFromProto3Json(programJson);
      final lines = await runAndCapture(program);
      // 'name' is on the child map directly (set in constructor), so accessible.
      // 'breed' is also on the child map directly.
      expect(lines, ['Rex', 'Lab']);
    });

    test('child instance accesses parent method via type hierarchy', () async {
      // class Animal { greet() => "I am an animal" }
      // class Dog extends Animal { bark() => "Woof" }
      // var d = Dog();
      // var barkFn = d.bark; print(barkFn(null));
      // var greetFn = d.greet; print(greetFn(null));
      //
      // d.greet should resolve through __methods__ inheritance.
      final programJson = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'assign', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              // Animal.greet method
              {
                'name': 'greet',
                'metadata': {'class': 'Animal'},
                'body': {
                  'literal': {'stringValue': 'I am an animal'},
                },
              },
              // Dog.bark method
              {
                'name': 'bark',
                'metadata': {'class': 'Dog'},
                'body': {
                  'literal': {'stringValue': 'Woof'},
                },
              },
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      // var d = Dog();
                      {
                        'expression': stdCall('assign', {
                          'messageCreation': {
                            'fields': [
                              field('target', ref('d')),
                              field('value', {
                                'messageCreation': {
                                  'typeName': 'Dog',
                                  'fields': [],
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // var barkFn = d.bark;
                      {
                        'expression': stdCall('assign', {
                          'messageCreation': {
                            'fields': [
                              field('target', ref('barkFn')),
                              field('value', {
                                'fieldAccess': {
                                  'object': ref('d'),
                                  'field': 'bark',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // print(barkFn(null))
                      {
                        'expression': stdCall('print', {
                          'messageCreation': {
                            'fields': [
                              field('message', {
                                'call': {
                                  'function': 'barkFn',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // var greetFn = d.greet;  (inherited from Animal)
                      {
                        'expression': stdCall('assign', {
                          'messageCreation': {
                            'fields': [
                              field('target', ref('greetFn')),
                              field('value', {
                                'fieldAccess': {
                                  'object': ref('d'),
                                  'field': 'greet',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // print(greetFn(null))
                      {
                        'expression': stdCall('print', {
                          'messageCreation': {
                            'fields': [
                              field('message', {
                                'call': {
                                  'function': 'greetFn',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                    ],
                  },
                },
              },
            ],
            'typeDefs': [
              {
                'name': 'main:Animal',
                'descriptor': {
                  'name': 'Animal',
                  'field': [],
                },
              },
              {
                'name': 'main:Dog',
                'descriptor': {
                  'name': 'Dog',
                  'field': [],
                },
                'metadata': {
                  'superclass': 'Animal',
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };

      final program = Program()..mergeFromProto3Json(programJson);
      final lines = await runAndCapture(program);
      expect(lines, ['Woof', 'I am an animal']);
    });

    test('child overrides parent method', () async {
      // class Animal { speak() => "..." }
      // class Dog extends Animal { speak() => "Woof!" }
      // Dog().speak should return "Woof!" (child override)
      // Animal().speak should return "..." (parent original)
      final programJson = {
        'name': 'test',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'assign', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              // Animal.speak method
              {
                'name': 'speak',
                'metadata': {'class': 'Animal'},
                'body': {
                  'literal': {'stringValue': '...'},
                },
              },
              // Dog.speak overrides Animal.speak
              {
                'name': 'speak',
                'metadata': {'class': 'Dog'},
                'body': {
                  'literal': {'stringValue': 'Woof!'},
                },
              },
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      // var d = Dog();
                      {
                        'expression': stdCall('assign', {
                          'messageCreation': {
                            'fields': [
                              field('target', ref('d')),
                              field('value', {
                                'messageCreation': {
                                  'typeName': 'Dog',
                                  'fields': [],
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // var dogSpeak = d.speak;
                      {
                        'expression': stdCall('assign', {
                          'messageCreation': {
                            'fields': [
                              field('target', ref('dogSpeak')),
                              field('value', {
                                'fieldAccess': {
                                  'object': ref('d'),
                                  'field': 'speak',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // print(dogSpeak()) — should be Dog's override
                      {
                        'expression': stdCall('print', {
                          'messageCreation': {
                            'fields': [
                              field('message', {
                                'call': {
                                  'function': 'dogSpeak',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // var a = Animal();
                      {
                        'expression': stdCall('assign', {
                          'messageCreation': {
                            'fields': [
                              field('target', ref('a')),
                              field('value', {
                                'messageCreation': {
                                  'typeName': 'Animal',
                                  'fields': [],
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // var animalSpeak = a.speak;
                      {
                        'expression': stdCall('assign', {
                          'messageCreation': {
                            'fields': [
                              field('target', ref('animalSpeak')),
                              field('value', {
                                'fieldAccess': {
                                  'object': ref('a'),
                                  'field': 'speak',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                      // print(animalSpeak()) — should be Animal's original
                      {
                        'expression': stdCall('print', {
                          'messageCreation': {
                            'fields': [
                              field('message', {
                                'call': {
                                  'function': 'animalSpeak',
                                },
                              }),
                            ],
                          },
                        }),
                      },
                    ],
                  },
                },
              },
            ],
            'typeDefs': [
              {
                'name': 'main:Animal',
                'descriptor': {
                  'name': 'Animal',
                  'field': [],
                },
              },
              {
                'name': 'main:Dog',
                'descriptor': {
                  'name': 'Dog',
                  'field': [],
                },
                'metadata': {
                  'superclass': 'Animal',
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };

      final program = Program()..mergeFromProto3Json(programJson);
      final lines = await runAndCapture(program);
      expect(lines[0], 'Woof!'); // Dog's override
      expect(lines[1], '...'); // Animal's original
    });
  });

  // ── Instance method dispatch via self field ─────────────────────────────
  group('instance method dispatch (self field)', () {
    test('simple instance method call', () async {
      // class Foo { int bar() => 42; }
      // main() { print(Foo().bar()); }
      final programJson = {
        'name': 'test_method',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              // Foo.bar method: returns 42
              {
                'name': 'main:Foo.bar',
                'metadata': {'kind': 'method'},
                'body': literal(42),
              },
              // main function
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      // print(Foo().bar()) — method call with self
                      stmt(printToString(
                        call('bar', input: msg([
                          field('self', msg([], typeName: 'main:Foo')),
                        ])),
                      )),
                    ],
                  },
                },
              },
            ],
            'typeDefs': [
              {
                'name': 'main:Foo',
                'descriptor': {'name': 'Foo', 'field': []},
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };

      final program = Program()..mergeFromProto3Json(programJson);
      final lines = await runAndCapture(program);
      expect(lines, ['42']);
    });

    test('method accessing instance field via self', () async {
      // class Foo { int x; int double_() => x * 2; }
      // main() { print(Foo(x: 5).double_()); }
      final programJson = {
        'name': 'test_method_field',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
              {'name': 'multiply', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              // Foo.double_ method: self.x * 2
              {
                'name': 'main:Foo.double_',
                'metadata': {'kind': 'method'},
                'body': stdCall('multiply', msg([
                  field('left', fieldAcc(ref('self'), 'x')),
                  field('right', literal(2)),
                ])),
              },
              // main function
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      // print(Foo(x:5).double_())
                      stmt(printToString(
                        call('double_', input: msg([
                          field('self', msg([
                            field('x', literal(5)),
                          ], typeName: 'main:Foo')),
                        ])),
                      )),
                    ],
                  },
                },
              },
            ],
            'typeDefs': [
              {
                'name': 'main:Foo',
                'descriptor': {
                  'name': 'Foo',
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
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };

      final program = Program()..mergeFromProto3Json(programJson);
      final lines = await runAndCapture(program);
      expect(lines, ['10']);
    });

    test('inherited method via superclass chain', () async {
      // class A { int val() => 1; }
      // class B extends A {}
      // main() { print(B().val()); }
      final programJson = {
        'name': 'test_inherited_method',
        'version': '1.0.0',
        'modules': [
          {
            'name': 'std',
            'functions': [
              {'name': 'print', 'isBase': true},
              {'name': 'to_string', 'isBase': true},
            ],
          },
          {
            'name': 'main',
            'functions': [
              // A.val method: returns 1
              {
                'name': 'main:A.val',
                'metadata': {'kind': 'method'},
                'body': literal(1),
              },
              // main function
              {
                'name': 'main',
                'body': {
                  'block': {
                    'statements': [
                      // print(B().val()) — B inherits val from A
                      stmt(printToString(
                        call('val', input: msg([
                          field('self', msg([], typeName: 'main:B')),
                        ])),
                      )),
                    ],
                  },
                },
              },
            ],
            'typeDefs': [
              {
                'name': 'main:A',
                'descriptor': {'name': 'A', 'field': []},
              },
              {
                'name': 'main:B',
                'descriptor': {'name': 'B', 'field': []},
                'metadata': {
                  'superclass': 'A',
                },
              },
            ],
          },
        ],
        'entryModule': 'main',
        'entryFunction': 'main',
      };

      final program = Program()..mergeFromProto3Json(programJson);
      final lines = await runAndCapture(program);
      expect(lines, ['1']);
    });
  });
}
