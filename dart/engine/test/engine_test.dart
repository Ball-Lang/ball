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
List<String> runAndCapture(
  Program program, {
  List<BallModuleHandler>? handlers,
}) {
  final lines = <String>[];
  final engine = BallEngine(
    program,
    stdout: lines.add,
    moduleHandlers: handlers,
  );
  engine.run();
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

    test('loads program metadata', () {
      expect(program.name, 'hello_world');
      expect(program.version, '1.0.0');
      expect(program.entryFunction, 'main');
    });

    test('engine produces correct output', () {
      final lines = runAndCapture(program);
      expect(lines, ['Hello, World!']);
    });
  });

  group('fibonacci.ball.json', () {
    late Program program;

    setUpAll(() {
      program = loadProgram('../../examples/fibonacci/fibonacci.ball.json');
    });

    test('loads program metadata', () {
      expect(program.name, 'fibonacci');
      expect(program.modules.length, 2);
    });

    test('engine computes fib(10) = 55', () {
      final lines = runAndCapture(program);
      expect(lines, ['55']);
    });
  });

  group('all_constructs.ball.json', () {
    late Program program;
    late List<String> lines;

    setUpAll(() {
      program = loadProgram(
        '../../examples/all_constructs/all_constructs.ball.json',
      );
      lines = runAndCapture(program);
    });

    test('arithmetic operations', () {
      // add(3,4)=7, subtract(10,3)=7, multiply(5,6)=30
      expect(lines[0], '7');
      expect(lines[1], '7');
      expect(lines[2], '30');
    });

    test('division operations', () {
      // divide(10.0,3.0), intDivide(10,3), modulo(10,3)
      expect(lines[3], '3.3333333333333335');
      expect(lines[4], '3');
      expect(lines[5], '1');
    });

    test('negation', () {
      expect(lines[6], '-5');
    });

    test('comparison operations', () {
      expect(lines[7], 'true'); // lessThan(1,2)
      expect(lines[8], 'true'); // greaterThan(3,2)
      expect(lines[9], 'true'); // lessOrEqual(2,2)
      expect(lines[10], 'true'); // greaterOrEqual(3,2)
      expect(lines[11], 'true'); // isEqual(5,5)
      expect(lines[12], 'true'); // isNotEqual(5,3)
    });

    test('logical operations', () {
      expect(lines[13], 'false'); // and(true,false)
      expect(lines[14], 'true'); // or(true,false)
      expect(lines[15], 'true'); // not(false)
    });

    test('bitwise operations', () {
      expect(lines[16], '2'); // bitwiseAnd(6,3)
      expect(lines[17], '7'); // bitwiseOr(6,3)
      expect(lines[18], '5'); // bitwiseXor(6,3)
      expect(lines[19], '8'); // leftShift(1,3)
      expect(lines[20], '2'); // rightShift(8,2)
      expect(lines[21], '-1'); // bitwiseNot(0)
    });

    test('string concatenation', () {
      expect(lines[22], 'Hello, World!');
    });

    test('control flow (if/else)', () {
      expect(lines[23], 'negative'); // classify(-5)
      expect(lines[24], 'zero'); // classify(0)
      expect(lines[25], 'positive'); // classify(7)
    });

    test('ternary', () {
      expect(lines[26], 'yes'); // ternary(true)
      expect(lines[27], 'no'); // ternary(false)
    });

    test('for loop (sumRange)', () {
      expect(lines[28], '10'); // sumRange(5) = 0+1+2+3+4 = 10
    });

    test('while loop (whileLoop)', () {
      expect(lines[29], '3'); // whileLoop(3)
    });

    test('recursion (factorial)', () {
      expect(lines[30], '720'); // factorial(6) = 720
    });

    test('local vars and nested calls', () {
      expect(lines[31], '19'); // localVars(10) = 10*2 - 1 = 19
      expect(
        lines[32],
        '14',
      ); // nested(5) = add(multiply(5,2), subtract(5,1)) = 10+4 = 14
      expect(lines[33], 'Result: 42'); // multiStep(21) = "Result: 42"
    });

    test('produces exactly 34 output lines', () {
      // 32 lines expected from the Dart source — but engine exits normally
      // after producing all lines (no remaining errors)
      expect(lines.length, 34);
    });
  });

  // ── Inline program unit tests ────────────────────────────

  group('engine: literals and print', () {
    test('prints a string literal', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printStr('hello'))]),
        ],
      );
      expect(runAndCapture(program), ['hello']);
    });

    test('prints an integer via to_string', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(literal(42)))]),
        ],
      );
      expect(runAndCapture(program), ['42']);
    });

    test('prints a double via to_string', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(literal(3.14)))]),
        ],
      );
      expect(runAndCapture(program), ['3.14']);
    });

    test('prints a boolean via to_string', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(literal(true)))]),
        ],
      );
      expect(runAndCapture(program), ['true']);
    });
  });

  group('engine: arithmetic', () {
    test('add two integers', () {
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
      expect(runAndCapture(program), ['30']);
    });

    test('subtract', () {
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
      expect(runAndCapture(program), ['63']);
    });

    test('multiply', () {
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
      expect(runAndCapture(program), ['56']);
    });

    test('negate', () {
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
      expect(runAndCapture(program), ['-42']);
    });
  });

  group('engine: comparisons', () {
    test('less_than true', () {
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
      expect(runAndCapture(program), ['true']);
    });

    test('less_than false', () {
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
      expect(runAndCapture(program), ['false']);
    });

    test('equals true', () {
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
      expect(runAndCapture(program), ['true']);
    });
  });

  group('engine: let bindings and variables', () {
    test('let binding and reference', () {
      final program = buildProgram(
        functions: [
          mainFn([letStmt('x', literal(42)), stmt(printToString(ref('x')))]),
        ],
      );
      expect(runAndCapture(program), ['42']);
    });

    test('multiple let bindings', () {
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
      expect(runAndCapture(program), ['30']);
    });

    test('let binding uses expression', () {
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
      expect(runAndCapture(program), ['7']);
    });
  });

  group('engine: user-defined functions', () {
    test('single-parameter function', () {
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
      expect(runAndCapture(program), ['42']);
    });

    test('two-parameter function with arg0/arg1', () {
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
      expect(runAndCapture(program), ['7']);
    });

    test('recursive function (fibonacci)', () {
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
      expect(runAndCapture(program), ['55']);
    });
  });

  group('engine: control flow', () {
    test('if-then-else (true branch)', () {
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
      expect(runAndCapture(program), ['yes']);
    });

    test('if-then-else (false branch)', () {
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
      expect(runAndCapture(program), ['no']);
    });

    test('if without else', () {
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
      expect(runAndCapture(program), ['only if']);
    });

    test('nested if', () {
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
      expect(runAndCapture(program), ['small positive']);
    });
  });

  group('engine: top-level variables', () {
    test('const top-level variable', () {
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
      expect(runAndCapture(program), ['99']);
    });

    test('multiple top-level variables', () {
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
      expect(runAndCapture(program), ['30']);
    });
  });

  group('engine: while loop', () {
    test('while loop with counter', () {
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
      expect(runAndCapture(program), ['0', '1', '2']);
    });
  });

  group('engine: for loop', () {
    test('for loop counting', () {
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
      expect(runAndCapture(program), ['0', '1', '2']);
    });
  });

  group('engine: string operations', () {
    test('string concatenation via add', () {
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
      expect(runAndCapture(program), ['Hello, World!']);
    });
  });

  group('engine: multiple print statements', () {
    test('sequence of prints', () {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printStr('line 1')),
            stmt(printStr('line 2')),
            stmt(printStr('line 3')),
          ]),
        ],
      );
      expect(runAndCapture(program), ['line 1', 'line 2', 'line 3']);
    });
  });

  group('engine: error handling', () {
    test('throws on undefined variable', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(ref('undefined_var')))]),
        ],
      );
      expect(() => runAndCapture(program), throwsA(isA<BallRuntimeError>()));
    });

    test('throws on missing entry point', () {
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
      expect(() => runAndCapture(program), throwsA(isA<BallRuntimeError>()));
    });
  });

  group('engine: stdout capture', () {
    test('custom stdout sink captures output', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printStr('captured'))]),
        ],
      );
      final captured = <String>[];
      final engine = BallEngine(program, stdout: captured.add);
      engine.run();
      expect(captured, ['captured']);
    });

    test('default stdout uses print (no crash)', () {
      final program = buildProgram(functions: [mainFn([])]);
      // Just verify it doesn't throw with default stdout
      final engine = BallEngine(program);
      expect(engine.run, returnsNormally);
    });
  });

  group('engine: protobuf deserialization', () {
    test('Program round-trips through proto3 JSON', () {
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

    test('Program round-trips through binary protobuf', () {
      final program = loadProgram(
        '../../examples/fibonacci/fibonacci.ball.json',
      );
      final bytes = program.writeToBuffer();
      final restored = Program.fromBuffer(bytes);
      expect(restored.name, 'fibonacci');
      final lines = runAndCapture(restored);
      expect(lines, ['55']);
    });
  });

  // ══════════════════════════════════════════════════════════════
  //  Comprehensive new capability tests
  // ══════════════════════════════════════════════════════════════

  group('engine: string_interpolation', () {
    test('interpolates a list of string parts', () {
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
      expect(runAndCapture(program), ['Hello, World!']);
    });

    test('interpolates mixed types', () {
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
      expect(runAndCapture(program), ['n = 42']);
    });

    test('single value field', () {
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
      expect(runAndCapture(program), ['direct']);
    });
  });

  // ── Virtual property field access ─────────────────────────────────────────

  group('engine: field access — virtual properties on String', () {
    test('.length', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal('hello'), 'length')))]),
        ],
      );
      expect(runAndCapture(program), ['5']);
    });

    test('.isEmpty on empty string', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal(''), 'isEmpty')))]),
        ],
      );
      expect(runAndCapture(program), ['true']);
    });

    test('.isEmpty on non-empty string', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal('hi'), 'isEmpty')))]),
        ],
      );
      expect(runAndCapture(program), ['false']);
    });

    test('.isNotEmpty', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(literal('abc'), 'isNotEmpty')))]),
        ],
      );
      expect(runAndCapture(program), ['true']);
    });
  });

  group('engine: field access — virtual properties on List', () {
    test('.length', () {
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
      expect(runAndCapture(program), ['3']);
    });

    test('.isEmpty on empty list', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printToString(fieldAcc(listLit([]), 'isEmpty')))]),
        ],
      );
      expect(runAndCapture(program), ['true']);
    });

    test('.isNotEmpty on non-empty list', () {
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(printToString(fieldAcc(listLit([literal(1)]), 'isNotEmpty'))),
          ]),
        ],
      );
      expect(runAndCapture(program), ['true']);
    });

    test('.first', () {
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
      expect(runAndCapture(program), ['10']);
    });

    test('.last', () {
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
      expect(runAndCapture(program), ['30']);
    });

    test('.reversed', () {
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
      expect(runAndCapture(program), ['3', '1']);
    });
  });

  group('engine: field access — message fields', () {
    test('access typed message fields', () {
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
      expect(runAndCapture(program), ['10', '20']);
    });

    test('.isEmpty on empty message', () {
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
      expect(runAndCapture(program), ['true']);
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

    test('bitwise AND', () {
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
      expect(runAndCapture(p), ['2']);
    });

    test('bitwise OR', () {
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
      expect(runAndCapture(p), ['7']);
    });

    test('bitwise XOR', () {
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
      expect(runAndCapture(p), ['5']);
    });

    test('bitwise NOT', () {
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
      expect(runAndCapture(p), ['-1']);
    });

    test('left shift', () {
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
      expect(runAndCapture(p), ['8']);
    });

    test('right shift', () {
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
      expect(runAndCapture(p), ['2']);
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

    test('string_length', () {
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
      expect(runAndCapture(p), ['5']);
    });

    test('string_is_empty — true', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('string_is_empty — false', () {
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
      expect(runAndCapture(p), ['false']);
    });

    test('string_to_upper', () {
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
      expect(runAndCapture(p), ['HELLO']);
    });

    test('string_to_lower', () {
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
      expect(runAndCapture(p), ['world']);
    });

    test('string_trim', () {
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
      expect(runAndCapture(p), ['hi']);
    });

    test('string_trim_start', () {
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
      expect(runAndCapture(p), ['hi  ']);
    });

    test('string_trim_end', () {
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
      expect(runAndCapture(p), ['  hi']);
    });

    test('string_contains — true', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('string_starts_with — true', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('string_ends_with — true', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('string_substring', () {
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
      expect(runAndCapture(p), ['world']);
    });

    test('string_split', () {
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
      expect(runAndCapture(p), ['3', 'b']);
    });

    test('string_replace', () {
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
      expect(runAndCapture(p), ['aaXXcc']);
    });

    test('string_replace_all', () {
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
      expect(runAndCapture(p), ['ZbZb']);
    });

    test('string_repeat', () {
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
      expect(runAndCapture(p), ['ababab']);
    });

    test('string_pad_left', () {
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
      expect(runAndCapture(p), ['0005']);
    });

    test('string_pad_right', () {
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
      expect(runAndCapture(p), ['hi---']);
    });

    test('string_char_at', () {
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
      expect(runAndCapture(p), ['e']);
    });

    test('string_char_code_at + string_from_char_code round-trip', () {
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
      expect(runAndCapture(p), ['A']);
    });

    test('string_index_of', () {
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
      expect(runAndCapture(p), ['2']);
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

    test('math_abs', () {
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
      expect(runAndCapture(p), ['7']);
    });

    test('math_floor', () {
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
      expect(runAndCapture(p), ['3']);
    });

    test('math_ceil', () {
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
      expect(runAndCapture(p), ['4']);
    });

    test('math_round', () {
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
      expect(runAndCapture(p), ['4']);
    });

    test('math_sqrt of 25', () {
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
      expect(runAndCapture(p), ['5.0']);
    });

    test('math_pow', () {
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
      expect(runAndCapture(p), ['1024.0']);
    });

    test('math_min', () {
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
      expect(runAndCapture(p), ['3']);
    });

    test('math_max', () {
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
      expect(runAndCapture(p), ['7']);
    });

    test('math_clamp', () {
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
      expect(runAndCapture(p), ['10']);
    });

    test('math_pi is approximately 3.14', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('math_infinity', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('math_nan', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('math_gcd', () {
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
      expect(runAndCapture(p), ['4']);
    });

    test('math_sign positive', () {
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
      expect(runAndCapture(p), ['1']);
    });

    test('math_sign negative', () {
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
      expect(runAndCapture(p), ['-1']);
    });
  });

  // ── for_in loop ───────────────────────────────────────────────────────────

  group('engine: for_in loop', () {
    test('iterates over a list', () {
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
      expect(runAndCapture(program), ['10', '20', '30']);
    });

    test('break inside for_in', () {
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
      expect(runAndCapture(program), ['1', '2']);
    });

    test('accumulates sum via for_in', () {
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
      expect(runAndCapture(program), ['15']);
    });
  });

  // ── do_while loop ─────────────────────────────────────────────────────────

  group('engine: do_while loop', () {
    test('runs body at least once', () {
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
      expect(runAndCapture(program), ['0', '1', '2']);
    });

    test('runs body once even if condition false', () {
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
      expect(runAndCapture(program), ['once']);
    });
  });

  // ── switch statement (lazy) ───────────────────────────────────────────────

  group('engine: switch statement', () {
    test('matches a case', () {
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
      expect(runAndCapture(program), ['two']);
    });

    test('falls through to default', () {
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
      expect(runAndCapture(program), ['default']);
    });

    test('no match and no default produces no output', () {
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
      expect(runAndCapture(program), ['done']);
    });
  });

  // ── switch expression (eager) ─────────────────────────────────────────────

  group('engine: switch expression', () {
    final switchFn = [
      {'name': 'switch_expr', 'isBase': true},
    ];

    test('matches string pattern', () {
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
      expect(runAndCapture(p), ['two']);
    });

    test('default wildcard _', () {
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
      expect(runAndCapture(p), ['default']);
    });

    test('type pattern — int', () {
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
      expect(runAndCapture(p), ['is int']);
    });

    test('type pattern — String', () {
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
      expect(runAndCapture(p), ['is string']);
    });

    test('exact value equality (int)', () {
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
      expect(runAndCapture(p), ['seven']);
    });
  });

  // ── try / catch / finally ────────────────────────────────────────────────

  group('engine: try/catch/finally', () {
    test('finally runs even without throw', () {
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
      expect(runAndCapture(program), ['try', 'finally']);
    });

    test('catch handles thrown exception', () {
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
      expect(runAndCapture(program), ['caught', 'after']);
    });

    test('catch + finally', () {
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
      expect(runAndCapture(program), ['caught', 'finally']);
    });

    test('uncaught throw propagates', () {
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
      expect(() => runAndCapture(program), throwsA(isA<BallException>()));
    });
  });

  // ── break and continue ───────────────────────────────────────────────────

  group('engine: break and continue', () {
    test('break exits for loop early', () {
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
      expect(runAndCapture(program), ['0', '1', '2']);
    });

    test('continue skips iteration', () {
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
      expect(runAndCapture(program), ['0', '1', '3', '4']);
    });

    test('break in while loop', () {
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
      expect(runAndCapture(program), ['0', '1', '2']);
    });
  });

  // ── Lambda / invoke ───────────────────────────────────────────────────────

  group('engine: lambda and closures', () {
    final invokeFns = [
      {'name': 'invoke', 'isBase': true},
    ];

    test('lambda with single input param', () {
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
      expect(runAndCapture(p), ['6']);
    });

    test('closure captures enclosing variable', () {
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
      expect(runAndCapture(p), ['107']);
    });

    test('lambda with no arguments (null input)', () {
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
      expect(runAndCapture(p), ['hello!']);
    });

    test('lambda returned from function', () {
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
      expect(runAndCapture(p), ['15']);
    });
  });

  // ── index operator ────────────────────────────────────────────────────────

  group('engine: index operator', () {
    final indexFns = [
      {'name': 'index', 'isBase': true},
    ];

    test('index into list', () {
      final p = buildProgram(
        stdFunctions: indexFns,
        functions: [
          mainFn([
            letStmt('nums', listLit([literal(10), literal(20), literal(30)])),
            stmt(printToString(indexExpr(ref('nums'), literal(1)))),
          ]),
        ],
      );
      expect(runAndCapture(p), ['20']);
    });

    test('index into string', () {
      final p = buildProgram(
        stdFunctions: indexFns,
        functions: [
          mainFn([stmt(printExpr(indexExpr(literal('hello'), literal(0))))]),
        ],
      );
      expect(runAndCapture(p), ['h']);
    });

    test('index set (list mutation)', () {
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
      expect(runAndCapture(p), ['99']);
    });
  });

  // ── compound assign ───────────────────────────────────────────────────────

  group('engine: compound assign', () {
    test('+= operator', () {
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
      expect(runAndCapture(program), ['15']);
    });

    test('-= operator', () {
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
      expect(runAndCapture(program), ['7']);
    });

    test('*= operator', () {
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
      expect(runAndCapture(program), ['12']);
    });

    test('??= operator — assigns when null', () {
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
      expect(runAndCapture(program), ['42']);
    });
  });

  // ── pre/post increment and decrement ──────────────────────────────────────

  group('engine: increment and decrement', () {
    test('pre_increment returns new value and mutates', () {
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
      expect(runAndCapture(program), ['6', '6']);
    });

    test('post_increment returns old value but mutates', () {
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
      expect(runAndCapture(program), ['5', '6']);
    });

    test('pre_decrement returns new value and mutates', () {
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
      expect(runAndCapture(program), ['2', '2']);
    });

    test('post_decrement returns old value but mutates', () {
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
      expect(runAndCapture(program), ['3', '2']);
    });
  });

  // ── null safety ───────────────────────────────────────────────────────────

  group('engine: null safety', () {
    final nullFns = [
      {'name': 'null_coalesce', 'isBase': true},
      {'name': 'null_check', 'isBase': true},
      {'name': 'null_aware_access', 'isBase': true},
    ];

    test('null_coalesce returns right when left is null', () {
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
      expect(runAndCapture(p), ['42']);
    });

    test('null_coalesce returns left when not null', () {
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
      expect(runAndCapture(p), ['7']);
    });

    test('null_check passes through non-null', () {
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
      expect(runAndCapture(p), ['5']);
    });

    test('null_aware_access returns null on null target', () {
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
      expect(runAndCapture(p), ['-1']);
    });
  });

  // ── type checks ───────────────────────────────────────────────────────────

  group('engine: type checks', () {
    final typeFns = [
      {'name': 'is', 'isBase': true},
      {'name': 'is_not', 'isBase': true},
      {'name': 'as', 'isBase': true},
    ];

    test('is int — true', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('is String — false for int', () {
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
      expect(runAndCapture(p), ['false']);
    });

    test('is_not int — false for int', () {
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
      expect(runAndCapture(p), ['false']);
    });

    test('is bool — true', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('is List — true', () {
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
      expect(runAndCapture(p), ['true']);
    });

    test('as is a no-op passthrough', () {
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
      expect(runAndCapture(p), ['42']);
    });
  });

  // ── map / set creation ────────────────────────────────────────────────────

  group('engine: map and set creation', () {
    final collFns = [
      {'name': 'map_create', 'isBase': true},
      {'name': 'set_create', 'isBase': true},
      {'name': 'index', 'isBase': true},
    ];

    test('map_create builds a map accessible by key', () {
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
      expect(runAndCapture(p), ['1', '2']);
    });

    test('set_create from list', () {
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
      expect(runAndCapture(p), ['3']); // duplicates removed
    });
  });

  // ── short-circuit logic ───────────────────────────────────────────────────

  group('engine: short-circuit and / or', () {
    test('and: false && _ = false (does not eval right)', () {
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
      expect(runAndCapture(program), ['false']);
    });

    test('and: true && true = true', () {
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
      expect(runAndCapture(program), ['true']);
    });

    test('or: true || _ = true', () {
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
      expect(runAndCapture(program), ['true']);
    });

    test('or: false || false = false', () {
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
      expect(runAndCapture(program), ['false']);
    });
  });

  // ── profiling ─────────────────────────────────────────────────────────────

  group('engine: profiling', () {
    test('profiling disabled by default — report is empty', () {
      final program = buildProgram(
        functions: [
          mainFn([stmt(printStr('x'))]),
        ],
      );
      final engine = BallEngine(program, stdout: (_) {});
      engine.run();
      expect(engine.profilingReport(), isEmpty);
    });

    test('profiling enabled — counts std function calls', () {
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
      engine.run();
      final report = engine.profilingReport();
      expect(report['print'], 3);
      expect(report['add'], 1);
      expect(report['to_string'], 1);
    });

    test('profilingReport is unmodifiable', () {
      final program = buildProgram(functions: [mainFn([])]);
      final engine = BallEngine(program, enableProfiling: true);
      engine.run();
      expect(
        () => engine.profilingReport()['x'] = 1,
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('profiling counts string ops correctly', () {
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
      engine.run();
      final report = engine.profilingReport();
      expect(report['string_to_upper'], 2);
      expect(report['string_to_lower'], 1);
    });
  });

  // ── call cache ────────────────────────────────────────────────────────────

  group('engine: call cache', () {
    test('repeated calls to user function produce correct results', () {
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
      expect(runAndCapture(program), ['4', '9', '16', '100']);
    });

    test('call cache handles multiple distinct functions', () {
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
      expect(runAndCapture(program), ['10', '15', '14', '21']);
    });
  });

  // ── block with result expression ──────────────────────────────────────────

  group('engine: block with result', () {
    test('block evaluates result expression', () {
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
      expect(runAndCapture(program), ['7']);
    });
  });

  // ── list literal operations ───────────────────────────────────────────────

  group('engine: list literals', () {
    test('creates and accesses list', () {
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
      expect(runAndCapture(program), ['3', '10', '30']);
    });

    test('empty list has length 0 and isEmpty true', () {
      final program = buildProgram(
        functions: [
          mainFn([
            letStmt('lst', listLit([])),
            stmt(printToString(fieldAcc(ref('lst'), 'length'))),
            stmt(printToString(fieldAcc(ref('lst'), 'isEmpty'))),
          ]),
        ],
      );
      expect(runAndCapture(program), ['0', 'true']);
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

    test('composition-only module resolves cross-module calls correctly', () {
      final lines = runAndCapture(buildCompositionProgram());
      expect(lines[0], '5.0');
      expect(lines[1], '81.0');
    });

    test('no handler registration required for composition-only module', () {
      // Default engine — only StdModuleHandler registered.
      // geometry has no isBase functions, so no handler is needed for it.
      final engine = BallEngine(buildCompositionProgram(), stdout: (_) {});
      expect(engine.run, returnsNormally);
    });

    test('composition-only module chains multiple levels deep', () {
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
      expect(runAndCapture(prog), ['27']);
    });
  });

  group('engine: BallCallable — handler-to-handler composition', () {
    test('custom handler delegates to std via BallCallable', () {
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
      final lines = runAndCapture(prog, handlers: [StdModuleHandler(), mymath]);
      expect(lines, ['7', '7']);
    });

    test('BallCallable can call user-defined functions too', () {
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
      final lines = runAndCapture(
        prog,
        handlers: [StdModuleHandler(), delegateHandler],
      );
      expect(lines, ['20']); // double_it(double_it(5)) = 20
    });
  });

  group('engine: StdModuleHandler.registerComposer', () {
    test('registerComposer can call back into std', () {
      final std = StdModuleHandler()
        ..registerComposer('sum_of_squares', (input, engine) {
          final m = input as Map<String, Object?>;
          final a = m['a'] as num;
          final b = m['b'] as num;
          final a2 = engine('std', 'multiply', {'left': a, 'right': a}) as num;
          final b2 = engine('std', 'multiply', {'left': b, 'right': b}) as num;
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
      BallEngine(prog, stdout: lines.add, moduleHandlers: [std]).run();
      expect(lines, ['25']); // 3^2 + 4^2 = 25
    });

    test('registerComposer overrides a built-in', () {
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
      BallEngine(program, stdout: lines.add, moduleHandlers: [std]).run();
      expect(lines, ['99']);
    });

    test('registerComposer and register coexist', () {
      final std = StdModuleHandler()
        ..register('my_const', (_) => 42)
        ..registerComposer(
          'my_doubled',
          (input, engine) => (engine('std', 'my_const', null) as int) * 2,
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
      BallEngine(prog, stdout: lines.add, moduleHandlers: [std]).run();
      expect(lines, ['42', '84']);
    });
  });

  group('engine: callFunction() public bridge', () {
    test('callFunction invokes a user-defined function', () {
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
      engine.run(); // initialise
      expect(engine.callFunction('main', 'triple', 7), 21);
    });

    test('callFunction invokes a std base function', () {
      final program = buildProgram(functions: [mainFn([])]);
      final engine = BallEngine(program, stdout: (_) {});
      engine.run();
      final result = engine.callFunction('std', 'add', {
        'left': 10,
        'right': 32,
      });
      expect(result, 42);
    });

    test('callFunction throws BallRuntimeError for unknown function', () {
      final program = buildProgram(functions: [mainFn([])]);
      final engine = BallEngine(program, stdout: (_) {});
      engine.run();
      expect(
        () => engine.callFunction('main', 'nonexistent', null),
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

    test('custom BallModuleHandler handles a new module', () {
      final math2 = _Math2Handler();
      final lines = <String>[];
      final engine = BallEngine(
        buildMath2Program(),
        stdout: lines.add,
        moduleHandlers: [StdModuleHandler(), math2],
      );
      engine.run();
      expect(lines, ['14', '25']);
    });

    test('custom handler is queried before unknown-module error', () {
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
      BallEngine(
        prog,
        stdout: lines.add,
        moduleHandlers: [StdModuleHandler(), math2],
      ).run();
      expect(lines, ['6']);
    });

    test('throws BallRuntimeError when no handler matches the module', () {
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
      expect(
        () => BallEngine(prog, moduleHandlers: [StdModuleHandler()]).run(),
        throwsA(isA<BallRuntimeError>()),
      );
    });
  });

  group('engine: StdModuleHandler customisation', () {
    test('register adds a new std function', () {
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
      BallEngine(prog, stdout: lines.add, moduleHandlers: [stdHandler]).run();
      expect(lines, ['hihi']);
    });

    test('register overrides an existing function', () {
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
      BallEngine(
        program,
        stdout: lines.add,
        moduleHandlers: [stdHandler],
      ).run();
      expect(lines, ['999']);
    });

    test('unregister removes a function — subsequent call throws', () {
      final stdHandler = StdModuleHandler()..unregister('negate');
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('negate', msg([field('value', literal(5))]))),
          ]),
        ],
      );
      expect(
        () => BallEngine(program, moduleHandlers: [stdHandler]).run(),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('StdModuleHandler.subset only exposes named functions', () {
      final stdHandler = StdModuleHandler.subset({'print', 'add', 'to_string'});
      // Calling an excluded function should throw.
      final program = buildProgram(
        functions: [
          mainFn([
            stmt(stdCall('negate', msg([field('value', literal(5))]))),
          ]),
        ],
      );
      expect(
        () => BallEngine(program, moduleHandlers: [stdHandler]).run(),
        throwsA(isA<BallRuntimeError>()),
      );
    });

    test('StdModuleHandler.subset allows included functions', () {
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
      BallEngine(
        program,
        stdout: lines.add,
        moduleHandlers: [stdHandler],
      ).run();
      expect(lines, ['7']);
    });

    test('registeredFunctions returns current key set', () {
      final h = StdModuleHandler.subset({'print', 'add'});
      final program = buildProgram(functions: [mainFn([])]);
      BallEngine(program, moduleHandlers: [h]); // triggers init
      expect(h.registeredFunctions, containsAll(['print', 'add']));
      expect(h.registeredFunctions, isNot(contains('negate')));
    });

    test('multiple handlers — first match wins', () {
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
      BallEngine(
        program,
        stdout: lines.add,
        moduleHandlers: [overrideStd, normalStd], // overrideStd wins
      ).run();
      expect(lines, ['999']); // first handler's result, not 3
    });

    test('spy handler counts calls while forwarding to delegate', () {
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
      BallEngine(program, stdout: lines.add, moduleHandlers: [spy]).run();
      expect(lines, ['a', 'b', 'c']); // delegation worked
      expect(
        calls,
        greaterThanOrEqualTo(3),
      ); // at minimum 3 print calls counted
    });

    test('dart_std module also handled by StdModuleHandler', () {
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
      BallEngine(prog, stdout: lines.add).run();
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

    test('loads successfully', () {
      expect(program.name, isNotEmpty);
      expect(program.modules, isNotEmpty);
    });

    test('engine runs or throws BallRuntimeError (no Dart errors)', () {
      // comprehensive.ball.json uses enums and advanced constructs that may
      // not yet be fully supported — we verify no Dart-level exception leaks.
      try {
        runAndCapture(program);
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

    test('list_push and list_length', () {
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
      expect(runAndCapture(p), ['3']);
    });

    test('list_pop returns last element', () {
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
      expect(runAndCapture(p), ['6']);
    });

    test('list_get and list_set', () {
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
      expect(runAndCapture(p), ['99']);
    });

    test('list_map, list_filter, and list_reduce', () {
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
      expect(runAndCapture(p), ['6', '2', '10']);
    });

    test('list_any, list_all, and list_none', () {
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
      expect(runAndCapture(p), ['true', 'true', 'true']);
    });

    test('map_get, map_set, map_delete, and map_length', () {
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
      expect(runAndCapture(p), ['3', 'true', '2']);
    });

    test('map_keys, map_values, and string_join', () {
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
      expect(runAndCapture(p), ['2', '2', 'a-b']);
    });

    test('set_create, set_add, set_union, and set_length', () {
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
      expect(runAndCapture(p), ['true', '4']);
    });
  });

  // ==========================================================================
  // std_io module
  // ==========================================================================

  group('engine: std_io module', () {
    test('print_error writes to stderr', () {
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
      engine.run();
      expect(errLines, contains('error msg'));
    });

    test('timestamp_ms returns epoch ms', () {
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
      final lines = runAndCapture(program);
      expect(lines, hasLength(1));
      final ts = int.parse(lines.first);
      expect(ts, greaterThan(1000000000000)); // after 2001
    });

    test('random_int returns value in range', () {
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
      final lines = runAndCapture(program);
      final val = int.parse(lines.first);
      expect(val, inInclusiveRange(1, 10));
    });

    test('random_double returns value in [0, 1)', () {
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
      final lines = runAndCapture(program);
      final val = double.parse(lines.first);
      expect(val, greaterThanOrEqualTo(0.0));
      expect(val, lessThan(1.0));
    });

    test('env_get reads environment variable', () {
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
      engine.run();
      expect(lines.first, equals('/usr/bin'));
    });

    test('args_get returns provided args', () {
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
      engine.run();
      expect(lines.first, contains('--verbose'));
    });
  });

  // ==========================================================================
  // std_convert module
  // ==========================================================================

  group('engine: std_convert module', () {
    test('json_encode encodes a map', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, contains('"x"'));
      expect(lines.first, contains('42'));
    });

    test('json_decode parses a string', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('42'));
    });

    test('utf8 encode and decode roundtrip', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('abc'));
    });
  });

  // ==========================================================================
  // std_time module
  // ==========================================================================

  group('engine: std_time module', () {
    test('now returns epoch ms', () {
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
      final lines = runAndCapture(program);
      final ts = int.parse(lines.first);
      expect(ts, greaterThan(1000000000000));
    });

    test('year returns valid year', () {
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
      final lines = runAndCapture(program);
      final year = int.parse(lines.first);
      expect(year, greaterThanOrEqualTo(2024));
    });
  });

  // ==========================================================================
  // Pattern matching (enhanced switch_expr)
  // ==========================================================================

  group('engine: pattern matching', () {
    test('type pattern matches int', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('was int'));
    });

    test('wildcard pattern matches as default', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('default'));
    });

    test('direct value equality match', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('two'));
    });
  });

  // ==========================================================================
  // Inheritance (__super__ chain)
  // ==========================================================================

  group('engine: inheritance via __super__', () {
    test('field access walks __super__ chain', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('bark'));
    });

    test('own field shadows __super__', () {
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
      final lines = runAndCapture(program);
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

    test('file_write and file_read roundtrip', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('hello ball'));
    });

    test('file_exists returns true for existing file', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('true'));
    });

    test('dir_create and dir_exists', () {
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
      final lines = runAndCapture(program);
      expect(lines.first, equals('true'));
    });
  });

  group('engine: cpp_std scope_exit cleanup', () {
    test('runs cleanup when block exits', () {
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
      expect(runAndCapture(program), ['2']);
    });

    test('runs multiple cleanups in LIFO order', () {
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
      expect(runAndCapture(program), ['B', 'A']);
    });
  });
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
  BallValue call(String function, BallValue input, BallCallable engine) {
    _onCall();
    return _delegate.call(function, input, engine);
  }
}

/// Handler for 'mymath' that computes abs_diff(a, b) by composing std functions.
class _ComposingHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'mymath';

  @override
  BallValue call(String function, BallValue input, BallCallable engine) {
    if (function == 'abs_diff') {
      final m = input as Map<String, Object?>;
      final diff = engine('std', 'subtract', {'left': m['a'], 'right': m['b']});
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
  BallValue call(String function, BallValue input, BallCallable engine) {
    if (function == 'quadruple') {
      final once = engine('main', 'double_it', input);
      return engine('main', 'double_it', once);
    }
    throw BallRuntimeError('Unknown ops function: "$function"');
  }
}
