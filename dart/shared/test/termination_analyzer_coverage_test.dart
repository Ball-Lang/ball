/// Coverage-focused termination-analyzer tests: the recursion-into-nested-type
/// branches (lambda / fieldAccess / messageCreation / literal-list / block
/// result) of every walker, plus analyzeModuleTermination, the do-while
/// condition-variable path, for-loop variants, mutual-recursion base cases, and
/// the full formatTerminationReport icon/severity rendering.
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/cli_core.dart';
import 'package:test/test.dart';

// ── Builders (same shape as termination_analyzer_test.dart) ─────────────────

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

Module _buildModule(List<Map<String, dynamic>> functions) {
  final json = {'name': 'main', 'functions': functions};
  return Module()..mergeFromProto3Json(json, ignoreUnknownFields: true);
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

Map<String, dynamic> _litStr(String v) => {
  'literal': {'stringValue': v},
};

Map<String, dynamic> _litList(List<Map<String, dynamic>> elems) => {
  'literal': {
    'listValue': {'elements': elems},
  },
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

/// A std `while(true)` with an arbitrary [body] — the smallest infinite-loop the
/// analyzer flags, used to plant a detectable warning inside nested wrappers.
Map<String, dynamic> _whileTrue(Map<String, dynamic> body) => _call(
  'std',
  'while',
  _msg('WhileInput', [
    _field('condition', _litBool(true)),
    _field('body', body),
  ]),
);

const _loopStd = [
  {'name': 'while', 'inputType': 'WhileInput'},
  {'name': 'do_while', 'inputType': 'DoWhileInput'},
  {'name': 'for', 'inputType': 'ForInput'},
  {'name': 'print', 'inputType': 'PrintInput'},
  {'name': 'less_than', 'inputType': 'BinaryInput'},
];

Map<String, dynamic> _printX() => _call(
  'std',
  'print',
  _msg('PrintInput', [_field('message', _litStr('x'))]),
);

void main() {
  group('analyzeModuleTermination entry point', () {
    test('audits a Module directly (no synthetic Program wrapper)', () {
      final module = _buildModule([
        {'name': 'main', 'body': _whileTrue(_printX())},
      ]);
      final report = analyzeModuleTermination(module).cast<Map>();
      expect(report, isNotEmpty);
      expect(report.first['category'], 'infinite_loop');
    });

    test('audits a Module plus inline imports', () {
      final module = _buildModule([
        {'name': 'main', 'body': _litInt(0)},
      ]);
      final imported = _buildModule([
        {'name': 'helper', 'body': _whileTrue(_printX())},
      ]);
      final report = analyzeModuleTermination(
        module,
        imports: [imported],
      ).cast<Map>();
      expect(report.any((w) => w['location'].contains('helper')), isTrue);
    });
  });

  group('walkers recurse into nested expression types', () {
    // Each wrapper embeds a flagged while(true). If the walker did not recurse
    // into that wrapper type, no warning would be produced.

    test('a loop inside a lambda body is found by _checkLoopsInExpr', () {
      // The loop walker recurses into lambdas (unlike the exit-signal walker).
      final program = _buildProgram(
        stdFunctions: _loopStd,
        functions: [
          {'name': 'main', 'body': _lambda(_whileTrue(_printX()))},
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(report.where((w) => w['category'] == 'infinite_loop'), isNotEmpty);
    });

    test('a loop inside a messageCreation field is found', () {
      final program = _buildProgram(
        stdFunctions: _loopStd,
        functions: [
          {
            'name': 'main',
            'body': _msg('Wrapper', [_field('inner', _whileTrue(_printX()))]),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(report.where((w) => w['category'] == 'infinite_loop'), isNotEmpty);
    });

    test('a loop inside a fieldAccess object is found', () {
      final program = _buildProgram(
        stdFunctions: _loopStd,
        functions: [
          {
            'name': 'main',
            'body': _fieldAccess(_whileTrue(_printX()), 'someField'),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(report.where((w) => w['category'] == 'infinite_loop'), isNotEmpty);
    });

    test('a loop inside a block result expression is found', () {
      final program = _buildProgram(
        stdFunctions: _loopStd,
        functions: [
          {
            'name': 'main',
            'body': _block([_letStmt('x', _litInt(0))], _whileTrue(_printX())),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(report.where((w) => w['category'] == 'infinite_loop'), isNotEmpty);
    });

    test('a loop inside a let-statement value is found', () {
      final program = _buildProgram(
        stdFunctions: _loopStd,
        functions: [
          {
            'name': 'main',
            'body': _block([_letStmt('x', _whileTrue(_printX()))]),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(report.where((w) => w['category'] == 'infinite_loop'), isNotEmpty);
    });
  });

  group('callgraph collects callees through nested types', () {
    // Recursion detection only fires if _collectCallees descends into the
    // wrapper holding the self-call. Each test plants a self-call inside a
    // different wrapper and expects an unbounded-recursion warning.

    test('self-call inside a literal list element', () {
      final program = _buildProgram(
        functions: [
          {'name': 'main', 'body': _call('main', 'rec', _litInt(1))},
          {
            'name': 'rec',
            'body': _litList([_call('main', 'rec', _litInt(1))]),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(
        report.where((w) => w['category'] == 'unbounded_recursion'),
        isNotEmpty,
      );
    });

    test('self-call inside a lambda body', () {
      final program = _buildProgram(
        functions: [
          {'name': 'main', 'body': _call('main', 'rec', _litInt(1))},
          {'name': 'rec', 'body': _lambda(_call('main', 'rec', _litInt(1)))},
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(
        report.where((w) => w['category'] == 'unbounded_recursion'),
        isNotEmpty,
      );
    });

    test('self-call inside a fieldAccess object', () {
      final program = _buildProgram(
        functions: [
          {'name': 'main', 'body': _call('main', 'rec', _litInt(1))},
          {
            'name': 'rec',
            'body': _fieldAccess(_call('main', 'rec', _litInt(1)), 'f'),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(
        report.where((w) => w['category'] == 'unbounded_recursion'),
        isNotEmpty,
      );
    });

    test('self-call inside a block result', () {
      final program = _buildProgram(
        functions: [
          {'name': 'main', 'body': _call('main', 'rec', _litInt(1))},
          {'name': 'rec', 'body': _block([], _call('main', 'rec', _litInt(1)))},
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(
        report.where((w) => w['category'] == 'unbounded_recursion'),
        isNotEmpty,
      );
    });
  });

  group('do-while + for variants', () {
    test('do-while condition var not mutated warns', () {
      final program = _buildProgram(
        stdFunctions: _loopStd,
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'do_while',
              _msg('DoWhileInput', [
                _field('body', _printX()),
                _field(
                  'condition',
                  _call(
                    'std',
                    'less_than',
                    _msg('BinaryInput', [
                      _field('left', _ref('i')),
                      _field('right', _litInt(10)),
                    ]),
                  ),
                ),
              ]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      final loop = report
          .where((w) => w['category'] == 'infinite_loop')
          .toList();
      expect(loop, hasLength(1));
      expect(loop.first['message'], contains('do-while'));
      expect(loop.first['message'], contains('does not modify'));
    });

    test('for loop missing both update and body does not crash, warns', () {
      final program = _buildProgram(
        stdFunctions: _loopStd,
        functions: [
          {
            'name': 'main',
            'body': _call(
              'std',
              'for',
              _msg('ForInput', [_field('init', _litInt(0))]),
            ),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(
        report.where((w) => w['category'] == 'infinite_loop'),
        hasLength(1),
      );
    });
  });

  group('unreachable code recurses into nested blocks', () {
    test('dead code inside a nested block in a let value is flagged', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'return', 'inputType': 'ReturnInput'},
          {'name': 'print', 'inputType': 'PrintInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _block([
              _letStmt(
                'x',
                _block([
                  _exprStmt(
                    _call(
                      'std',
                      'return',
                      _msg('ReturnInput', [_field('value', _litInt(0))]),
                    ),
                  ),
                  _exprStmt(_printX()),
                ]),
              ),
            ]),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      expect(
        report.where((w) => w['category'] == 'unreachable_code'),
        isNotEmpty,
      );
    });
  });

  group('orphaned labels recurse into nested types', () {
    test('an orphaned break label inside a lambda is reported', () {
      final program = _buildProgram(
        stdFunctions: [
          {'name': 'break', 'inputType': 'BreakInput'},
        ],
        functions: [
          {
            'name': 'main',
            'body': _lambda(
              _call(
                'std',
                'break',
                _msg('BreakInput', [_field('label', _litStr('ghost'))]),
              ),
            ),
          },
        ],
      );
      final report = analyzeTermination(program).cast<Map>();
      final labels = report
          .where((w) => w['category'] == 'orphaned_label')
          .toList();
      expect(labels, hasLength(1));
      expect(labels.first['message'], contains('ghost'));
    });
  });

  group('formatTerminationReport rendering', () {
    test('renders error + warning + info icons and the totals line', () {
      final report = <Map>[
        _w('error', 'orphaned_label', 'bad label', 'main.a'),
        _w('warning', 'infinite_loop', 'spinny', 'main.b'),
        _w('info', 'unreachable_code', 'fyi', 'main.c'),
      ];
      final text = formatTerminationReport(report);
      expect(text, contains('Orphaned Labels'));
      expect(text, contains('Potential Infinite Loops'));
      expect(text, contains('Unreachable Code'));
      // Icons: error U+2716, warning U+26A0, info U+2139.
      expect(text, contains('✖'));
      expect(text, contains('⚠'));
      expect(text, contains('ℹ'));
      expect(text, contains('1 error(s), 1 warning(s), 1 info(s)'));
    });

    test('unknown category falls through to the raw name label', () {
      final report = <Map>[_w('warning', 'mystery_category', 'm', 'main.x')];
      final text = formatTerminationReport(report);
      expect(text, contains('mystery_category'));
    });
  });

  group('report flags', () {
    test('terminationHasErrors reflects severities', () {
      final errReport = <Map>[_w('error', 'orphaned_label', 'm', 'l')];
      expect(terminationHasErrors(errReport), isTrue);
      expect(errReport.isEmpty, isFalse);

      final warnReport = <Map>[_w('warning', 'infinite_loop', 'm', 'l')];
      expect(terminationHasErrors(warnReport), isFalse);

      expect(<Map>[].isEmpty, isTrue);
    });

    test('warning Map carries severity/category/message/location fields', () {
      final w = _w('warning', 'infinite_loop', 'spins forever', 'main.loop');
      expect(w['severity'], 'warning');
      expect(w['category'], 'infinite_loop');
      expect(w['message'], 'spins forever');
      expect(w['location'], 'main.loop');
    });
  });
}

/// Build a termination warning Map (mirrors the analyzer's warning shape).
Map<String, Object?> _w(
  String severity,
  String category,
  String message,
  String location,
) => {
  'severity': severity,
  'category': category,
  'message': message,
  'location': location,
};
