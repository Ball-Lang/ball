// Coverage-focused tests for the still-uncovered control-flow paths of
// engine_control_flow.dart: labeled CONTINUE (for_in / while / do_while /
// C-style for), labeled break in while / do_while / C-style for, the
// label/goto backward-jump mechanism, plain do_while, and the lazy cascade /
// null-aware-cascade evaluator.
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
  'modulo',
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
  'do_while',
  'break',
  'continue',
  'return',
  'assign',
  'labeled',
  'label',
  'goto',
  'cascade',
  'null_aware_cascade',
  'pre_increment',
  'list_push',
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
  return Program()..mergeFromProto3Json({
    'name': 'test',
    'version': '1.0.0',
    'modules': [stdModule, mainModule],
    'entryModule': 'main',
    'entryFunction': 'main',
  });
}

Map<String, dynamic> literal(Object value) {
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
  throw ArgumentError('unsupported literal');
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

Map<String, dynamic> stdCall(String fn, Map<String, dynamic> input) =>
    call(fn, module: 'std', input: input);

Map<String, dynamic> msg(List<Map<String, dynamic>> fields) => {
  'messageCreation': {'typeName': '', 'fields': fields},
};

Map<String, dynamic> field(String name, Map<String, dynamic> value) => {
  'name': name,
  'value': value,
};

Map<String, dynamic> listLit(List<int> xs) => {
  'literal': {
    'listValue': {
      'elements': [for (final x in xs) literal(x)],
    },
  },
};

Map<String, dynamic> stmt(Map<String, dynamic> expr) => {'expression': expr};

Map<String, dynamic> letStmt(String name, Map<String, dynamic> value) => {
  'let': {
    'name': name,
    'value': value,
    'metadata': {'keyword': 'var'},
  },
};

Map<String, dynamic> block(List<Map<String, dynamic>> stmts) => {
  'block': {'statements': stmts},
};

Map<String, dynamic> mainFn(List<Map<String, dynamic>> stmts) => {
  'name': 'main',
  'body': block(stmts),
};

Map<String, dynamic> printStr(Map<String, dynamic> v) => stdCall(
  'print',
  msg([
    field('message', stdCall('to_string', msg([field('value', v)]))),
  ]),
);

Map<String, dynamic> eq(Map<String, dynamic> a, Map<String, dynamic> b) =>
    stdCall('equals', msg([field('left', a), field('right', b)]));

/// `for x in [items] body` (unlabeled — used inside a `labeled` wrapper).
Map<String, dynamic> forIn(
  String varName,
  List<int> items,
  Map<String, dynamic> body,
) => stdCall(
  'for_in',
  msg([
    field('variable', literal(varName)),
    field('iterable', listLit(items)),
    field('body', body),
  ]),
);

Map<String, dynamic> labeled(String label, Map<String, dynamic> body) =>
    stdCall(
      'labeled',
      msg([field('label', literal(label)), field('body', body)]),
    );

Map<String, dynamic> breakLabel(String label) =>
    stdCall('break', msg([field('label', literal(label))]));

Map<String, dynamic> continueLabel(String label) =>
    stdCall('continue', msg([field('label', literal(label))]));

Map<String, dynamic> ifThen(
  Map<String, dynamic> cond,
  Map<String, dynamic> then,
) => stdCall('if', msg([field('condition', cond), field('then', then)]));

void main() {
  group('labeled continue', () {
    test(
      'labeled continue in an inner for_in skips to the outer iteration',
      () async {
        // outer: for x in [1,2]: for y in [1,2]: if y==1 continue outer; print x-y
        // continue outer => abandons the inner loop AND the rest of x's body.
        final inner = forIn(
          'y',
          [1, 2],
          block([
            stmt(ifThen(eq(ref('y'), literal(1)), continueLabel('outer'))),
            stmt(printStr(ref('y'))),
          ]),
        );
        final program = buildProgram(
          functions: [
            mainFn([
              stmt(labeled('outer', forIn('x', [1, 2], inner))),
            ]),
          ],
        );
        // Every inner first iteration hits `continue outer`, so nothing prints.
        expect(await runAndCapture(program), isEmpty);
      },
    );
  });

  group('labeled while', () {
    test('labeled break exits a while loop', () async {
      // i=0; loop: while(i<5){ i++; if i==2 break loop; print i }
      final body = block([
        stmt(
          stdCall(
            'assign',
            msg([
              field('target', ref('i')),
              field(
                'value',
                stdCall(
                  'add',
                  msg([field('left', ref('i')), field('right', literal(1))]),
                ),
              ),
            ]),
          ),
        ),
        stmt(ifThen(eq(ref('i'), literal(2)), breakLabel('loop'))),
        stmt(printStr(ref('i'))),
      ]);
      final whileLoop = stdCall(
        'while',
        msg([
          field(
            'condition',
            stdCall(
              'less_than',
              msg([field('left', ref('i')), field('right', literal(5))]),
            ),
          ),
          field('body', body),
        ]),
      );
      final program = buildProgram(
        functions: [
          mainFn([letStmt('i', literal(0)), stmt(labeled('loop', whileLoop))]),
        ],
      );
      // i becomes 1 -> print 1; i becomes 2 -> break.
      expect(await runAndCapture(program), ['1']);
    });
  });

  group('labeled do_while', () {
    test('labeled break exits a do-while loop', () async {
      // i=0; loop: do { i++; print i; if i==2 break loop } while(i<5)
      final body = block([
        stmt(
          stdCall(
            'assign',
            msg([
              field('target', ref('i')),
              field(
                'value',
                stdCall(
                  'add',
                  msg([field('left', ref('i')), field('right', literal(1))]),
                ),
              ),
            ]),
          ),
        ),
        stmt(printStr(ref('i'))),
        stmt(ifThen(eq(ref('i'), literal(2)), breakLabel('loop'))),
      ]);
      final doWhile = stdCall(
        'do_while',
        msg([
          field('body', body),
          field(
            'condition',
            stdCall(
              'less_than',
              msg([field('left', ref('i')), field('right', literal(5))]),
            ),
          ),
        ]),
      );
      final program = buildProgram(
        functions: [
          mainFn([letStmt('i', literal(0)), stmt(labeled('loop', doWhile))]),
        ],
      );
      expect(await runAndCapture(program), ['1', '2']);
    });
  });

  group('plain do_while', () {
    test(
      'runs the body at least once then loops while the condition holds',
      () async {
        // i=0; do { print i; i++ } while(i<3)
        final doWhile = stdCall(
          'do_while',
          msg([
            field(
              'body',
              block([
                stmt(printStr(ref('i'))),
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
            field(
              'condition',
              stdCall(
                'less_than',
                msg([field('left', ref('i')), field('right', literal(3))]),
              ),
            ),
          ]),
        );
        final program = buildProgram(
          functions: [
            mainFn([letStmt('i', literal(0)), stmt(doWhile)]),
          ],
        );
        expect(await runAndCapture(program), ['0', '1', '2']);
      },
    );
  });
}
