import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/termination_analyzer.dart';
import 'package:test/test.dart';

/// Build a minimal program from JSON maps, following the same pattern
/// as the capability analyzer tests.
Program _buildProgram({
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> stdFunctions = const [],
  List<Map<String, dynamic>> extraModules = const [],
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
      ...extraModules,
    ],
  };
  return Program()..mergeFromProto3Json(json, ignoreUnknownFields: true);
}

// ── Helpers to build common expression JSON structures ────────────────────

Map<String, dynamic> _call(String module, String fn,
        [Map<String, dynamic>? input]) =>
    {
      'call': {
        'module': module,
        'function': fn,
        if (input != null) 'input': input,
      },
    };

Map<String, dynamic> _msg(String typeName, List<Map<String, dynamic>> fields) =>
    {
      'messageCreation': {
        'typeName': typeName,
        'fields': fields,
      },
    };

Map<String, dynamic> _field(String name, Map<String, dynamic> value) =>
    {'name': name, 'value': value};

Map<String, dynamic> _ref(String name) => {'reference': {'name': name}};

Map<String, dynamic> _litBool(bool v) => {'literal': {'boolValue': v}};

Map<String, dynamic> _litInt(int v) => {'literal': {'intValue': '$v'}};

Map<String, dynamic> _litStr(String v) => {'literal': {'stringValue': v}};

Map<String, dynamic> _block(List<Map<String, dynamic>> stmts,
        [Map<String, dynamic>? result]) =>
    {
      'block': {
        'statements': stmts,
        if (result != null) 'result': result,
      },
    };

Map<String, dynamic> _exprStmt(Map<String, dynamic> expr) =>
    {'expression': expr};

Map<String, dynamic> _letStmt(String name, Map<String, dynamic> value) =>
    {'let': {'name': name, 'value': value}};

void main() {
  group('infinite_loop', () {
    test('while(true) without break warns', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'while', 'inputType': 'WhileInput'},
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field('condition', _litBool(true)),
                _field(
                    'body',
                    _call('std', 'print',
                        _msg('PrintInput', [_field('message', _litStr('x'))]))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      expect(report.warnings, hasLength(1));
      expect(report.warnings[0].category, 'infinite_loop');
      expect(report.warnings[0].severity, 'warning');
      expect(report.warnings[0].message, contains('while(true)'));
    });

    test('while(true) with break does not warn', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'while', 'inputType': 'WhileInput'},
          {'name': 'break', 'inputType': 'BreakInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field('condition', _litBool(true)),
                _field(
                    'body',
                    _call('std', 'break',
                        _msg('BreakInput', [_field('label', _litStr(''))]))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final loopWarnings =
          report.warnings.where((w) => w.category == 'infinite_loop').toList();
      expect(loopWarnings, isEmpty);
    });

    test('while loop with condition variable not mutated warns', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'while', 'inputType': 'WhileInput'},
          {'name': 'less_than', 'inputType': 'BinaryInput'},
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field(
                    'condition',
                    _call(
                        'std',
                        'less_than',
                        _msg('BinaryInput', [
                          _field('left', _ref('i')),
                          _field('right', _litInt(10)),
                        ]))),
                _field(
                    'body',
                    _call('std', 'print',
                        _msg('PrintInput', [_field('message', _litStr('x'))]))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final loopWarnings =
          report.warnings.where((w) => w.category == 'infinite_loop').toList();
      expect(loopWarnings, hasLength(1));
      expect(loopWarnings[0].message, contains('i'));
      expect(loopWarnings[0].message, contains('does not modify'));
    });

    test('while loop with condition variable mutated does not warn', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'while', 'inputType': 'WhileInput'},
          {'name': 'less_than', 'inputType': 'BinaryInput'},
          {'name': 'assign', 'inputType': 'AssignInput'},
          {'name': 'add', 'inputType': 'BinaryInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'while',
              _msg('WhileInput', [
                _field(
                    'condition',
                    _call(
                        'std',
                        'less_than',
                        _msg('BinaryInput', [
                          _field('left', _ref('i')),
                          _field('right', _litInt(10)),
                        ]))),
                _field(
                    'body',
                    _call(
                        'std',
                        'assign',
                        _msg('AssignInput', [
                          _field('target', _ref('i')),
                          _field(
                              'value',
                              _call(
                                  'std',
                                  'add',
                                  _msg('BinaryInput', [
                                    _field('left', _ref('i')),
                                    _field('right', _litInt(1)),
                                  ]))),
                        ]))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final loopWarnings =
          report.warnings.where((w) => w.category == 'infinite_loop').toList();
      expect(loopWarnings, isEmpty);
    });

    test('for loop without update warns', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'for', 'inputType': 'ForInput'},
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'for',
              _msg('ForInput', [
                _field('init', _litInt(0)),
                _field(
                    'condition',
                    _call(
                        'std',
                        'less_than',
                        _msg('BinaryInput', [
                          _field('left', _ref('i')),
                          _field('right', _litInt(10)),
                        ]))),
                // No 'update' field.
                _field(
                    'body',
                    _call('std', 'print',
                        _msg('PrintInput', [_field('message', _litStr('x'))]))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final loopWarnings =
          report.warnings.where((w) => w.category == 'infinite_loop').toList();
      expect(loopWarnings, hasLength(1));
      expect(loopWarnings[0].message, contains('for loop without update'));
    });

    test('for loop with update does not warn', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'for', 'inputType': 'ForInput'},
          {'name': 'assign', 'inputType': 'AssignInput'},
          {'name': 'add', 'inputType': 'BinaryInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'for',
              _msg('ForInput', [
                _field('init', _litInt(0)),
                _field('condition', _ref('i')),
                _field(
                    'update',
                    _call(
                        'std',
                        'assign',
                        _msg('AssignInput', [
                          _field('target', _ref('i')),
                          _field('value', _litInt(1)),
                        ]))),
                _field('body', _litInt(0)),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final loopWarnings =
          report.warnings.where((w) => w.category == 'infinite_loop').toList();
      expect(loopWarnings, isEmpty);
    });

    test('do-while(true) without break warns', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'do_while', 'inputType': 'DoWhileInput'},
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'do_while',
              _msg('DoWhileInput', [
                _field(
                    'body',
                    _call('std', 'print',
                        _msg('PrintInput', [_field('message', _litStr('x'))]))),
                _field('condition', _litBool(true)),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final loopWarnings =
          report.warnings.where((w) => w.category == 'infinite_loop').toList();
      expect(loopWarnings, hasLength(1));
      expect(loopWarnings[0].message, contains('do-while(true)'));
    });
  });

  group('unbounded_recursion', () {
    test('direct recursion without base case warns', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _exprStmt(_call('main', 'recurse', _litInt(1))),
            ]),
          },
          {
            'name': 'recurse',
            'body': _call('main', 'recurse', _litInt(1)),
          },
        ],
      );

      final report = analyzeTermination(program);
      final recWarnings = report.warnings
          .where((w) => w.category == 'unbounded_recursion')
          .toList();
      expect(recWarnings, hasLength(1));
      expect(recWarnings[0].message, contains('direct recursion'));
      expect(recWarnings[0].message, contains('no base case'));
    });

    test('direct recursion with base case does not warn', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'if', 'inputType': 'IfInput'},
          {'name': 'return', 'inputType': 'ReturnInput'},
          {'name': 'less_than', 'inputType': 'BinaryInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call('main', 'recurse', _litInt(1)),
          },
          {
            'name': 'recurse',
            'body': _call(
              'std',
              'if',
              _msg('IfInput', [
                _field('condition', _ref('n')),
                _field(
                    'then',
                    _call('std', 'return',
                        _msg('ReturnInput', [_field('value', _litInt(0))]))),
                _field('else', _call('main', 'recurse', _litInt(1))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final recWarnings = report.warnings
          .where((w) => w.category == 'unbounded_recursion')
          .toList();
      expect(recWarnings, isEmpty);
    });

    test('mutual recursion without base case warns', () {
      final program = _buildProgram(
        stdFunctions: [],
        functions: [
          {
            'name': 'main',
            'body': _call('main', 'a', _litInt(1)),
          },
          {
            'name': 'a',
            'body': _call('main', 'b', _litInt(1)),
          },
          {
            'name': 'b',
            'body': _call('main', 'a', _litInt(1)),
          },
        ],
      );

      final report = analyzeTermination(program);
      final recWarnings = report.warnings
          .where((w) => w.category == 'unbounded_recursion')
          .toList();
      expect(recWarnings, hasLength(1));
      expect(recWarnings[0].message, contains('mutual recursion'));
    });
  });

  group('unreachable_code', () {
    test('statement after return is unreachable', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'return', 'inputType': 'ReturnInput'},
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _exprStmt(_call('std', 'return',
                  _msg('ReturnInput', [_field('value', _litInt(0))]))),
              _exprStmt(_call('std', 'print',
                  _msg('PrintInput', [_field('message', _litStr('dead'))]))),
            ]),
          },
        ],
      );

      final report = analyzeTermination(program);
      final deadWarnings = report.warnings
          .where((w) => w.category == 'unreachable_code')
          .toList();
      expect(deadWarnings, hasLength(1));
      expect(deadWarnings[0].message, contains('unreachable'));
      expect(deadWarnings[0].message, contains('std.return'));
      expect(deadWarnings[0].location, contains('stmt[1]'));
    });

    test('statement after throw is unreachable', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'throw', 'inputType': 'UnaryInput'},
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _exprStmt(_call('std', 'throw',
                  _msg('UnaryInput', [_field('value', _litStr('error'))]))),
              _exprStmt(_call('std', 'print',
                  _msg('PrintInput', [_field('message', _litStr('dead'))]))),
            ]),
          },
        ],
      );

      final report = analyzeTermination(program);
      final deadWarnings = report.warnings
          .where((w) => w.category == 'unreachable_code')
          .toList();
      expect(deadWarnings, hasLength(1));
      expect(deadWarnings[0].message, contains('std.throw'));
    });

    test('no warning when return is last statement', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'return', 'inputType': 'ReturnInput'},
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _exprStmt(_call('std', 'print',
                  _msg('PrintInput', [_field('message', _litStr('ok'))]))),
              _exprStmt(_call('std', 'return',
                  _msg('ReturnInput', [_field('value', _litInt(0))]))),
            ]),
          },
        ],
      );

      final report = analyzeTermination(program);
      final deadWarnings = report.warnings
          .where((w) => w.category == 'unreachable_code')
          .toList();
      expect(deadWarnings, isEmpty);
    });
  });

  group('orphaned_label', () {
    test('break with undefined label is error', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'break', 'inputType': 'BreakInput'},
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
                _field(
                    'body',
                    _call(
                        'std',
                        'break',
                        _msg('BreakInput', [
                          _field('label', _litStr('outer')),
                        ]))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final labelWarnings = report.warnings
          .where((w) => w.category == 'orphaned_label')
          .toList();
      expect(labelWarnings, hasLength(1));
      expect(labelWarnings[0].severity, 'error');
      expect(labelWarnings[0].message, contains('outer'));
    });

    test('break with defined label does not warn', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'break', 'inputType': 'BreakInput'},
          {'name': 'label', 'inputType': 'LabelInput'},
          {'name': 'while', 'inputType': 'WhileInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'label',
              _msg('LabelInput', [
                _field('name', _litStr('outer')),
                _field(
                    'body',
                    _call(
                      'std',
                      'while',
                      _msg('WhileInput', [
                        _field('condition', _litBool(true)),
                        _field(
                            'body',
                            _call(
                                'std',
                                'break',
                                _msg('BreakInput', [
                                  _field('label', _litStr('outer')),
                                ]))),
                      ]),
                    )),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final labelWarnings = report.warnings
          .where((w) => w.category == 'orphaned_label')
          .toList();
      expect(labelWarnings, isEmpty);
    });

    test('continue with undefined label is error', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'continue', 'inputType': 'ContinueInput'},
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
                _field(
                    'body',
                    _call(
                        'std',
                        'continue',
                        _msg('ContinueInput', [
                          _field('label', _litStr('missing')),
                        ]))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final labelWarnings = report.warnings
          .where((w) => w.category == 'orphaned_label')
          .toList();
      expect(labelWarnings, hasLength(1));
      expect(labelWarnings[0].severity, 'error');
      expect(labelWarnings[0].message, contains('missing'));
    });

    test('break without label does not trigger orphan check', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'break', 'inputType': 'BreakInput'},
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
                _field(
                    'body',
                    _call(
                        'std',
                        'break',
                        _msg('BreakInput', [
                          _field('label', _litStr('')),
                        ]))),
              ]),
            ),
          },
        ],
      );

      final report = analyzeTermination(program);
      final labelWarnings = report.warnings
          .where((w) => w.category == 'orphaned_label')
          .toList();
      expect(labelWarnings, isEmpty);
    });
  });

  group('valid programs', () {
    test('empty main function has no warnings', () {
      final program = _buildProgram(
        functions: [
          {
            'name': 'main',
            'body': _litInt(0),
          },
        ],
      );

      final report = analyzeTermination(program);
      expect(report.warnings, isEmpty);
    });

    test('simple print program has no warnings', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _call('std', 'print',
                _msg('PrintInput', [_field('message', _litStr('hello'))])),
          },
        ],
      );

      final report = analyzeTermination(program);
      expect(report.warnings, isEmpty);
    });

    test('well-formed while loop has no warnings', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'while', 'inputType': 'WhileInput'},
          {'name': 'less_than', 'inputType': 'BinaryInput'},
          {'name': 'assign', 'inputType': 'AssignInput'},
          {'name': 'add', 'inputType': 'BinaryInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _letStmt('i', _litInt(0)),
              _exprStmt(_call(
                'std',
                'while',
                _msg('WhileInput', [
                  _field(
                      'condition',
                      _call(
                          'std',
                          'less_than',
                          _msg('BinaryInput', [
                            _field('left', _ref('i')),
                            _field('right', _litInt(10)),
                          ]))),
                  _field(
                      'body',
                      _call(
                          'std',
                          'assign',
                          _msg('AssignInput', [
                            _field('target', _ref('i')),
                            _field(
                                'value',
                                _call(
                                    'std',
                                    'add',
                                    _msg('BinaryInput', [
                                      _field('left', _ref('i')),
                                      _field('right', _litInt(1)),
                                    ]))),
                          ]))),
                ]),
              )),
            ]),
          },
        ],
      );

      final report = analyzeTermination(program);
      expect(report.warnings, isEmpty);
    });
  });

  group('formatTerminationReport', () {
    test('empty report says no issues', () {
      final report = TerminationReport([]);
      final text = formatTerminationReport(report);
      expect(text, contains('No issues found'));
    });

    test('report with warnings formats correctly', () {
      final report = TerminationReport([
        TerminationWarning(
          severity: 'warning',
          category: 'infinite_loop',
          message: 'while(true) loop without break',
          location: 'main.loop_fn',
        ),
      ]);
      final text = formatTerminationReport(report);
      expect(text, contains('Potential Infinite Loops'));
      expect(text, contains('main.loop_fn'));
      expect(text, contains('0 error(s), 1 warning(s)'));
    });
  });
}
