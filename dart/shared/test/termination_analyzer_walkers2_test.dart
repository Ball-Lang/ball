/// Additional coverage for termination_analyzer.dart's tree-walkers: the
/// `block`/`lambda`/`messageCreation`/`fieldAccess`/`notSet` branches of
/// `_exprContainsConditionalReturn` / `_exprContainsReturn` (base-case
/// detection), `_collectReferencedVars` / `_exprHasExitSignal` /
/// `_collectMutatedVars` (while/do-while loop analysis), and the `notSet`
/// catch-alls of the other walkers (`_collectCallees`, `_checkLoopsInExpr`,
/// `_checkUnreachableInExpr`, `_collectDefinedLabels`, `_collectLabelUsages`).
///
/// These walkers only get exercised on their non-default shapes when a
/// condition/body/then-branch/else-branch is directly a block, lambda,
/// messageCreation, fieldAccess, or a bare not-set expression — shapes the
/// existing suites never happen to construct.
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/termination_analyzer.dart';
import 'package:test/test.dart';

Program _buildProgram({
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> stdFunctions = const [],
}) {
  final json = {
    'name': 'test',
    'version': '1.0.0',
    'entryModule': 'main',
    'entryFunction': 'main',
    'modules': [
      {
        'name': 'std',
        'functions': [
          for (final f in stdFunctions) {...f, 'isBase': true},
        ],
      },
      {'name': 'main', 'functions': functions},
    ],
  };
  return Program()..mergeFromProto3Json(json, ignoreUnknownFields: true);
}

Map<String, dynamic> _call(
  String module,
  String fn, [
  Map<String, dynamic>? input,
]) => {
  'call': {'module': module, 'function': fn, if (input != null) 'input': input},
};

Map<String, dynamic> _msg(String typeName, List<Map<String, dynamic>> fields) =>
    {
      'messageCreation': {'typeName': typeName, 'fields': fields},
    };

Map<String, dynamic> _field(String name, Map<String, dynamic> value) => {
  'name': name,
  'value': value,
};

Map<String, dynamic> _ref(String name) => {
  'reference': {'name': name},
};

Map<String, dynamic> _litBool(bool v) => {
  'literal': {'boolValue': v},
};

Map<String, dynamic> _litInt(int v) => {
  'literal': {'intValue': '$v'},
};

Map<String, dynamic> _lambda(Map<String, dynamic> body) => {
  'lambda': {'body': body},
};

Map<String, dynamic> _fieldAccess(Map<String, dynamic> object, String field) =>
    {
      'fieldAccess': {'object': object, 'field': field},
    };

Map<String, dynamic> _block(
  List<Map<String, dynamic>> stmts, [
  Map<String, dynamic>? result,
]) => {
  'block': {'statements': stmts, if (result != null) 'result': result},
};

Map<String, dynamic> _exprStmt(Map<String, dynamic> expr) => {
  'expression': expr,
};

Map<String, dynamic> _letStmt(String name, Map<String, dynamic> value) => {
  'let': {'name': name, 'value': value},
};

/// A bare not-set expression (`Expression()` with no oneof field populated).
const Map<String, dynamic> _notSet = <String, dynamic>{};

Map<String, dynamic> _returnCall(Object value) => _call(
  'std',
  'return',
  _msg('ReturnInput', [
    _field(
      'value',
      value is int ? _litInt(value) : value as Map<String, dynamic>,
    ),
  ]),
);

const _recursionStd = [
  {'name': 'if', 'inputType': 'IfInput'},
  {'name': 'return', 'inputType': 'ReturnInput'},
  {'name': 'print', 'inputType': 'PrintInput'},
  {'name': 'wrap', 'inputType': 'WrapInput'},
];

Map<String, dynamic> _printX() =>
    _call('std', 'print', _msg('PrintInput', [_field('message', _litInt(1))]));

void main() {
  group('base-case detection recurses into then/else nested shapes', () {
    test('then-branch return wrapped in a block (let + expression stmt)', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _call(
              'std',
              'if',
              _msg('IfInput', [
                _field('condition', _ref('n')),
                _field(
                  'then',
                  _block([
                    _letStmt('tmp', _litInt(0)),
                    _exprStmt(_returnCall(0)),
                  ]),
                ),
                _field('else', _call('main', 'recurse', _litInt(1))),
              ]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test('then-branch return wrapped in a block result expression', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _call(
              'std',
              'if',
              _msg('IfInput', [
                _field('condition', _ref('n')),
                _field('then', _block([], _returnCall(0))),
                _field('else', _call('main', 'recurse', _litInt(1))),
              ]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test('then-branch return wrapped in a lambda body', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _call(
              'std',
              'if',
              _msg('IfInput', [
                _field('condition', _ref('n')),
                _field('then', _lambda(_returnCall(0))),
                _field('else', _call('main', 'recurse', _litInt(1))),
              ]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test('then-branch return wrapped in a messageCreation field', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _call(
              'std',
              'if',
              _msg('IfInput', [
                _field('condition', _ref('n')),
                _field(
                  'then',
                  _msg('Wrapper', [_field('inner', _returnCall(0))]),
                ),
                _field('else', _call('main', 'recurse', _litInt(1))),
              ]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test('then-branch return wrapped in a fieldAccess object', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _call(
              'std',
              'if',
              _msg('IfInput', [
                _field('condition', _ref('n')),
                _field('then', _fieldAccess(_returnCall(0), 'x')),
                _field('else', _call('main', 'recurse', _litInt(1))),
              ]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test('then-branch return wrapped in a call that has an input', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _call(
              'std',
              'if',
              _msg('IfInput', [
                _field('condition', _ref('n')),
                _field('then', _call('main', 'wrap', _returnCall(0))),
                _field('else', _call('main', 'recurse', _litInt(1))),
              ]),
            ),
          },
          {'name': 'wrap', 'body': _litInt(0)},
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test(
      'else-branch (not then-branch) carries the return — right side of OR',
      () {
        final program = _buildProgram(
          stdFunctions: _recursionStd,
          functions: [
            {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
            {
              'name': 'recurse',
              'body': _call(
                'std',
                'if',
                _msg('IfInput', [
                  _field('condition', _ref('n')),
                  _field('then', _printX()),
                  _field('else', _returnCall(0)),
                ]),
              ),
            },
          ],
        );
        final report = analyzeTermination(program);
        expect(
          report.warnings.where((w) => w.category == 'unbounded_recursion'),
          isEmpty,
        );
      },
    );

    test('neither then nor else returns directly: falls through to the '
        'generic call.input traversal (else-branch OR check + reference/'
        'not-set base cases)', () {
      // Neither `then` nor `else` contains a `std.return` directly, so the
      // `(thenBranch has return) || (elseBranch has return)` check (both
      // operands — the `||` does not short-circuit on a false left side)
      // falls through to the generic `call.input` recursion, which walks
      // every IfInput field (`condition`: a bare reference, `then`: a
      // messageCreation wrapping a bare reference, `else`: not-set)
      // through `_exprContainsConditionalReturn` itself.
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _call(
              'std',
              'if',
              _msg('IfInput', [
                _field('condition', _ref('n')),
                _field(
                  'then',
                  _msg('Wrapper', [_field('inner', _ref('unused'))]),
                ),
                _field('else', _notSet),
                _field('extra', _call('main', 'recurse', _litInt(1))),
              ]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program);
      // No base case anywhere — the recursion is genuinely unbounded.
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isNotEmpty,
      );
    });

    test('function body itself is a block wrapping the base-case if', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _block([
              _letStmt(
                'r',
                _call(
                  'std',
                  'if',
                  _msg('IfInput', [
                    _field('condition', _ref('n')),
                    _field('then', _returnCall(0)),
                    _field('else', _call('main', 'recurse', _litInt(1))),
                  ]),
                ),
              ),
            ]),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test('function body itself is a block whose expression stmt is the if', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _block([
              _exprStmt(
                _call(
                  'std',
                  'if',
                  _msg('IfInput', [
                    _field('condition', _ref('n')),
                    _field('then', _returnCall(0)),
                    _field('else', _call('main', 'recurse', _litInt(1))),
                  ]),
                ),
              ),
            ]),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test('function body itself is a messageCreation wrapping the if', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _msg('Wrapper', [
              _field(
                'inner',
                _call(
                  'std',
                  'if',
                  _msg('IfInput', [
                    _field('condition', _ref('n')),
                    _field('then', _returnCall(0)),
                    _field('else', _call('main', 'recurse', _litInt(1))),
                  ]),
                ),
              ),
            ]),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });

    test('function body itself is a fieldAccess wrapping the if', () {
      final program = _buildProgram(
        stdFunctions: _recursionStd,
        functions: [
          {'name': 'main', 'body': _call('main', 'recurse', _litInt(1))},
          {
            'name': 'recurse',
            'body': _fieldAccess(
              _call(
                'std',
                'if',
                _msg('IfInput', [
                  _field('condition', _ref('n')),
                  _field('then', _returnCall(0)),
                  _field('else', _call('main', 'recurse', _litInt(1))),
                ]),
              ),
              'x',
            ),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unbounded_recursion'),
        isEmpty,
      );
    });
  });

  group('while/do-while loop analysis recurses into nested condition/body', () {
    const loopStd = [
      {'name': 'while', 'inputType': 'WhileInput'},
      {'name': 'do_while', 'inputType': 'DoWhileInput'},
      {'name': 'break', 'inputType': 'BreakInput'},
      {'name': 'assign', 'inputType': 'AssignInput'},
    ];

    test('while condition is a block (referenced vars walker)', () {
      final program = _buildProgram(
        stdFunctions: loopStd,
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field('condition', _block([], _ref('flag'))),
                _field('body', _block([_exprStmt(_ref('flag'))])),
              ]),
            ),
          },
        ],
      );
      // Just must not crash; the point is walking the block-shaped condition.
      expect(() => analyzeTermination(program), returnsNormally);
    });

    test('while condition is a fieldAccess (referenced vars walker)', () {
      final program = _buildProgram(
        stdFunctions: loopStd,
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field('condition', _fieldAccess(_ref('flag'), 'value')),
                _field('body', _block([_exprStmt(_ref('flag'))])),
              ]),
            ),
          },
        ],
      );
      expect(() => analyzeTermination(program), returnsNormally);
    });

    test('while condition is a lambda (referenced vars walker)', () {
      final program = _buildProgram(
        stdFunctions: loopStd,
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field('condition', _lambda(_ref('flag'))),
                _field('body', _block([_exprStmt(_ref('flag'))])),
              ]),
            ),
          },
        ],
      );
      expect(() => analyzeTermination(program), returnsNormally);
    });

    test(
      'while body is a fieldAccess (exit-signal + mutated-vars walkers)',
      () {
        final program = _buildProgram(
          stdFunctions: loopStd,
          functions: [
            {
              'name': 'main',
              'body': _call(
                'std',
                'while',
                _msg('WhileInput', [
                  _field('condition', _ref('flag')),
                  _field(
                    'body',
                    _fieldAccess(
                      _call(
                        'std',
                        'assign',
                        _msg('AssignInput', [
                          _field('target', _ref('flag')),
                          _field('value', _litBool(false)),
                        ]),
                      ),
                      'x',
                    ),
                  ),
                ]),
              ),
            },
          ],
        );
        expect(() => analyzeTermination(program), returnsNormally);
      },
    );

    test('while condition is a block with let/expression statements and a '
        'not-set result (referenced vars walker: block-statement + notSet '
        'branches)', () {
      final program = _buildProgram(
        stdFunctions: loopStd,
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field(
                  'condition',
                  _block([
                    _letStmt('a', _ref('x')),
                    _exprStmt(_litInt(5)),
                  ], _notSet),
                ),
                _field('body', _block([_exprStmt(_ref('flag'))])),
              ]),
            ),
          },
        ],
      );
      expect(() => analyzeTermination(program), returnsNormally);
    });

    test('while body is a block whose let-statement and result recurse into '
        'the mutated-vars walker', () {
      final program = _buildProgram(
        stdFunctions: loopStd,
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field('condition', _ref('flag')),
                _field(
                  'body',
                  _block([
                    _letStmt(
                      'tmp',
                      _call(
                        'std',
                        'assign',
                        _msg('AssignInput', [
                          _field('target', _ref('flag')),
                          _field('value', _litBool(false)),
                        ]),
                      ),
                    ),
                  ], _ref('unused')),
                ),
              ]),
            ),
          },
        ],
      );
      expect(() => analyzeTermination(program), returnsNormally);
    });

    test('do-while body is a lambda (exit-signal + mutated-vars walkers)', () {
      final program = _buildProgram(
        stdFunctions: loopStd,
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'do_while',
              _msg('DoWhileInput', [
                _field(
                  'body',
                  _lambda(
                    _call(
                      'std',
                      'assign',
                      _msg('AssignInput', [
                        _field('target', _ref('flag')),
                        _field('value', _litBool(false)),
                      ]),
                    ),
                  ),
                ),
                _field('condition', _ref('flag')),
              ]),
            ),
          },
        ],
      );
      expect(() => analyzeTermination(program), returnsNormally);
    });
  });

  group('notSet catch-alls are reachable via a bare not-set expression', () {
    test('a not-set list element does not crash callgraph collection', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _exprStmt({
                'literal': {
                  'listValue': {
                    'elements': [_notSet],
                  },
                },
              }),
            ]),
          },
        ],
      );
      expect(() => analyzeTermination(program), returnsNormally);
    });

    test('a not-set expression inside a while(true) body does not crash', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'while', 'inputType': 'WhileInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field('condition', _litBool(true)),
                _field('body', _block([_exprStmt(_notSet)])),
              ]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'infinite_loop'),
        isNotEmpty,
      );
    });

    test('a not-set expression inside unreachable-code scanning', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'return', 'inputType': 'ReturnInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _exprStmt(_returnCall(0)),
              _exprStmt(_notSet),
              _exprStmt(_notSet),
            ]),
          },
        ],
      );
      final report = analyzeTermination(program);
      expect(
        report.warnings.where((w) => w.category == 'unreachable_code'),
        isNotEmpty,
      );
    });

    test('a not-set expression inside label collection does not crash', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'break', 'inputType': 'BreakInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _exprStmt(_notSet),
              _exprStmt(
                _call(
                  'std',
                  'break',
                  _msg('BreakInput', [_field('label', _notSet)]),
                ),
              ),
            ]),
          },
        ],
      );
      expect(() => analyzeTermination(program), returnsNormally);
    });
  });
}
