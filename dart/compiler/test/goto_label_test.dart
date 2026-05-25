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
import 'package:test/test.dart';

// ── Tiny Ball-IR builders ─────────────────────────────────────────
Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);

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
      FunctionDefinition()
        ..name = 'print'
        ..isBase = true,
      FunctionDefinition()
        ..name = 'label'
        ..isBase = true,
      FunctionDefinition()
        ..name = 'goto'
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
  });
}
