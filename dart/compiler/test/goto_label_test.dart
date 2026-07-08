/// Compile tests for the goto/label control-flow lowering.
///
/// Dart has no native `goto`, so the compiler simulates `std.label` /
/// `std.goto` calls with a `switch (0) { caseN: ... continue labelX; }`
/// state machine (see `_generateGotoSwitchBlock`). These tests build Ball
/// programs directly (the Dart encoder never emits goto/label — only
/// hand-written or cross-language Ball does) and assert both forward and
/// backward jumps compile into the expected switch + labelled `continue`.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:test/test.dart';

// ── Tiny Ball-IR builders ─────────────────────────────────────────
Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);
Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = $fixnum.Int64(n));
Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);

FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

Expression _stdCall(String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = fn
        ..input = (Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = ''
            ..fields.addAll(fields))));

Expression _printCall(String msg) =>
    _stdCall('print', [_field('value', _strLit(msg))]);

Statement _exprStmt(Expression e) => Statement()..expression = e;

Statement _letVar(String name, Expression value) {
  final lb = LetBinding()
    ..name = name
    ..value = value;
  lb.mergeFromProto3Json({
    'metadata': {'keyword': 'var'},
  });
  return Statement()..let = lb;
}

Expression _block(List<Statement> stmts) =>
    Expression()..block = (Block()..statements.addAll(stmts));

/// A `std.label` statement carrying a name + body expression.
Statement _label(String name, Expression body) => _exprStmt(
  _stdCall('label', [_field('name', _strLit(name)), _field('body', body)]),
);

/// A `std.goto` statement jumping to `target`.
Statement _goto(String target) =>
    _exprStmt(_stdCall('goto', [_field('label', _strLit(target))]));

/// Build a single-module program whose `main` body is the given block.
Program _program(Block body) {
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = (Expression()..block = body);
  final stdModule = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in const [
        'print',
        'label',
        'goto',
        'switch',
        'continue',
        'if',
        'assign',
        'add',
        'less_than',
      ])
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  final mainModule = Module()
    ..name = 'main'
    ..functions.add(mainFn);
  return Program()
    ..name = 'goto_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([stdModule, mainModule]);
}

String _compile(Block body) =>
    DartCompiler(_program(body), noFormat: true).compile();

void main() {
  group('goto/label lowering', () {
    test('forward goto skips over a label body', () {
      // case 0: print("start"); goto end;
      // start: print("middle");   // skipped
      // end:   print("end");
      final block = Block()
        ..statements.addAll([
          _exprStmt(_printCall('start')),
          _goto('end'),
          _label('start', _printCall('middle')),
          _label('end', _printCall('end')),
        ]);
      final out = _compile(block);

      // A switch-based state machine is emitted.
      expect(out, contains('switch (0)'));
      // Labels become Dart switch labels.
      expect(out, contains('start:'));
      expect(out, contains('end:'));
      // The forward jump compiles to a labelled continue targeting `end`.
      expect(out, contains('continue end;'));
      // No unsupported/unknown markers leaked.
      expect(out, isNot(contains('/* unsupported')));
      expect(out, isNot(contains('/* unknown')));
    });

    test('backward goto jumps to an earlier label', () {
      // top: print("top");
      //      goto top;   // backward jump (would loop; we only check codegen)
      //      print("after");
      final block = Block()
        ..statements.addAll([
          _label('top', _printCall('top')),
          _goto('top'),
          _exprStmt(_printCall('after')),
        ]);
      final out = _compile(block);

      expect(out, contains('switch (0)'));
      expect(out, contains('top:'));
      // Backward jump => labelled continue back to `top`.
      expect(out, contains('continue top;'));
      expect(out, isNot(contains('/* unsupported')));
      expect(out, isNot(contains('/* unknown')));
    });

    test('label without goto still emits a reachable case', () {
      final block = Block()
        ..statements.addAll([
          _exprStmt(_printCall('a')),
          _label('only', _printCall('b')),
        ]);
      final out = _compile(block);
      expect(out, contains('switch (0)'));
      expect(out, contains('only:'));
      expect(out, isNot(contains('/* unsupported')));
    });

    test('label body with nested control flow lowers to statements', () {
      // var i = 0;
      // loop: { print("x"); i = i + 1; if (i < 3) goto loop; }
      final loopBody = _block([
        _exprStmt(_printCall('x')),
        _exprStmt(
          _stdCall('assign', [
            _field('target', _ref('i')),
            _field(
              'value',
              _stdCall('add', [
                _field('left', _ref('i')),
                _field('right', _intLit(1)),
              ]),
            ),
          ]),
        ),
        _exprStmt(
          _stdCall('if', [
            _field(
              'condition',
              _stdCall('less_than', [
                _field('left', _ref('i')),
                _field('right', _intLit(3)),
              ]),
            ),
            _field(
              'then',
              _stdCall('goto', [_field('label', _strLit('loop'))]),
            ),
          ]),
        ),
      ]);
      final block = Block()
        ..statements.addAll([
          _letVar('i', _intLit(0)),
          _label('loop', loopBody),
        ]);
      final out = _compile(block);

      // The nested `if` survives as a real statement (not dropped as an
      // unsupported block-expression) and its `goto` becomes `continue loop;`.
      expect(out, isNot(contains('/* unsupported')));
      expect(out, contains('if ('));
      expect(out, contains('continue loop;'));
      // The pre-label declaration is hoisted ABOVE the switch — Dart scopes a
      // case-group's locals to that group, so it must not live inside case 0.
      final declIdx = out.indexOf('i = 0');
      final switchIdx = out.indexOf('switch (0)');
      expect(declIdx, greaterThanOrEqualTo(0));
      expect(
        declIdx,
        lessThan(switchIdx),
        reason: 'loop var declaration must precede the switch',
      );
    });

    test('a labelled switch case emits its `continue` target label', () {
      // switch (0) { case 0: continue loop; loop: case 1: print("y"); }
      // (The shape the goto lowering produces; the encoder now preserves the
      //  case label so it round-trips.)
      final switchCall = _stdCall('switch', [
        _field('subject', _intLit(0)),
        _field(
          'cases',
          Expression()
            ..literal = (Literal()
              ..listValue = (ListLiteral()
                ..elements.addAll([
                  Expression()
                    ..messageCreation = (MessageCreation()
                      ..fields.addAll([
                        _field('value', _intLit(0)),
                        _field(
                          'body',
                          _stdCall('continue', [
                            _field('label', _strLit('loop')),
                          ]),
                        ),
                      ])),
                  Expression()
                    ..messageCreation = (MessageCreation()
                      ..fields.addAll([
                        _field('label', _strLit('loop')),
                        _field('value', _intLit(1)),
                        _field('body', _printCall('y')),
                      ])),
                ]))),
        ),
      ]);
      final out = _compile(Block()..statements.add(_exprStmt(switchCall)));
      expect(out, contains('loop:'));
      expect(out, contains('case 1:'));
      expect(out, contains('continue loop;'));
      // The label must precede its case.
      expect(out.indexOf('loop:'), lessThan(out.indexOf('case 1:')));
    });
  });
}
