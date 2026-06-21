/// Unit tests for structured Dart-pattern emission (`_compilePatternExpr`) and
/// the string-literal control-character escaper (`_dartStringLiteral`).
///
/// Patterns are carried on a switch-expr case's `pattern_expr` field as a
/// MessageCreation whose `typeName` is the pattern kind (VarPattern,
/// RecordPattern, ObjectPattern, …). We build that IR directly and assert the
/// native Dart pattern syntax the compiler transcribes.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);
Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));
Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);
Expression _listLit(List<Expression> items) =>
    Expression()
      ..literal = (Literal()
        ..listValue = (ListLiteral()..elements.addAll(items)));

FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

Expression _msg(String typeName, List<FieldValuePair> fields) =>
    Expression()
      ..messageCreation = (MessageCreation()
        ..typeName = typeName
        ..fields.addAll(fields));

Expression _call(String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = fn
        ..input = _msg('', fields));

/// Build a switch-expr whose single case carries [patternExpr], wrapped in
/// `paren()` so it compiles in expression position.
Expression _switchWithPattern(Expression patternExpr, {Expression? guard}) {
  final caseFields = <FieldValuePair>[
    _field('pattern_expr', patternExpr),
    _field('body', _strLit('hit')),
  ];
  if (guard != null) caseFields.add(_field('guard', guard));
  return _call('paren', [
    _field(
      'value',
      _call('switch_expr', [
        _field('subject', _ref('x')),
        _field('cases', _listLit([_msg('', caseFields)])),
      ]),
    ),
  ]);
}

Program _program(Expression expr) {
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in const ['paren', 'switch_expr', 'greater_than'])
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  return Program()
    ..name = 'patterns_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.add(
          FunctionDefinition()
            ..name = 'main'
            ..body = expr,
        ),
    ]);
}

String _compile(Expression expr) =>
    DartCompiler(_program(expr), noFormat: true).compile();
String _flatPattern(Expression patternExpr, {Expression? guard}) => _compile(
  _switchWithPattern(patternExpr, guard: guard),
).replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('structured patterns', () {
    test('VarPattern typed and untyped', () {
      expect(
        _flatPattern(
          _msg('VarPattern', [
            _field('name', _strLit('n')),
            _field('type', _strLit('int')),
          ]),
        ),
        contains('int n =>'),
      );
      expect(
        _flatPattern(_msg('VarPattern', [_field('name', _strLit('n'))])),
        contains('var n =>'),
      );
    });

    test('WildcardPattern typed and untyped', () {
      expect(
        _flatPattern(
          _msg('WildcardPattern', [_field('type', _strLit('String'))]),
        ),
        contains('String _ =>'),
      );
      expect(_flatPattern(_msg('WildcardPattern', [])), contains('_ =>'));
    });

    test('ConstPattern', () {
      expect(
        _flatPattern(_msg('ConstPattern', [_field('value', _intLit(42))])),
        contains('42 =>'),
      );
    });

    test('RecordPattern with named + positional fields', () {
      final out = _flatPattern(
        _msg('RecordPattern', [
          _field(
            'fields',
            _listLit([
              _msg('', [
                _field(
                  'pattern',
                  _msg('VarPattern', [_field('name', _strLit('a'))]),
                ),
              ]),
              _msg('', [
                _field('name', _strLit('y')),
                _field(
                  'pattern',
                  _msg('VarPattern', [_field('name', _strLit('b'))]),
                ),
              ]),
            ]),
          ),
        ]),
      );
      expect(out, contains('(var a, y: var b)'));
    });

    test('ObjectPattern', () {
      final out = _flatPattern(
        _msg('ObjectPattern', [
          _field('type', _strLit('Point')),
          _field(
            'fields',
            _listLit([
              _msg('', [
                _field('name', _strLit('x')),
                _field(
                  'pattern',
                  _msg('VarPattern', [_field('name', _strLit('px'))]),
                ),
              ]),
            ]),
          ),
        ]),
      );
      expect(out, contains('Point(x: var px)'));
    });

    test('ListPattern', () {
      final out = _flatPattern(
        _msg('ListPattern', [
          _field(
            'elements',
            _listLit([
              _msg('VarPattern', [_field('name', _strLit('a'))]),
              _msg('RestPattern', []),
            ]),
          ),
        ]),
      );
      expect(out, contains('[var a, ...]'));
    });

    test('MapPattern', () {
      final out = _flatPattern(
        _msg('MapPattern', [
          _field(
            'entries',
            _listLit([
              _msg('', [
                _field('key', _strLit('k')),
                _field(
                  'value',
                  _msg('VarPattern', [_field('name', _strLit('v'))]),
                ),
              ]),
            ]),
          ),
        ]),
      );
      expect(out, contains("{'k': var v}"));
    });

    test('NullCheckPattern / NullAssertPattern', () {
      expect(
        _flatPattern(
          _msg('NullCheckPattern', [
            _field(
              'pattern',
              _msg('VarPattern', [_field('name', _strLit('a'))]),
            ),
          ]),
        ),
        contains('var a? =>'),
      );
      expect(
        _flatPattern(
          _msg('NullAssertPattern', [
            _field(
              'pattern',
              _msg('VarPattern', [_field('name', _strLit('a'))]),
            ),
          ]),
        ),
        contains('var a! =>'),
      );
    });

    test('CastPattern', () {
      expect(
        _flatPattern(
          _msg('CastPattern', [
            _field(
              'pattern',
              _msg('VarPattern', [_field('name', _strLit('a'))]),
            ),
            _field('type', _strLit('int')),
          ]),
        ),
        contains('var a as int =>'),
      );
    });

    test('LogicalAndPattern / LogicalOrPattern', () {
      expect(
        _flatPattern(
          _msg('LogicalAndPattern', [
            _field('left', _msg('VarPattern', [_field('name', _strLit('a'))])),
            _field('right', _msg('WildcardPattern', [])),
          ]),
        ),
        contains('var a && _ =>'),
      );
      expect(
        _flatPattern(
          _msg('LogicalOrPattern', [
            _field('left', _msg('ConstPattern', [_field('value', _intLit(1))])),
            _field(
              'right',
              _msg('ConstPattern', [_field('value', _intLit(2))]),
            ),
          ]),
        ),
        contains('1 || 2 =>'),
      );
    });

    test('RelationalPattern', () {
      expect(
        _flatPattern(
          _msg('RelationalPattern', [
            _field('operator', _strLit('>')),
            _field('operand', _intLit(0)),
          ]),
        ),
        contains('> 0 =>'),
      );
    });

    test('RestPattern with subpattern', () {
      final out = _flatPattern(
        _msg('ListPattern', [
          _field(
            'elements',
            _listLit([
              _msg('RestPattern', [
                _field(
                  'subpattern',
                  _msg('VarPattern', [_field('name', _strLit('rest'))]),
                ),
              ]),
            ]),
          ),
        ]),
      );
      expect(out, contains('[...var rest]'));
    });

    test('pattern with guard appends `when`', () {
      final out = _flatPattern(
        _msg('VarPattern', [
          _field('name', _strLit('n')),
          _field('type', _strLit('int')),
        ]),
        guard: _call('greater_than', [
          _field('left', _ref('n')),
          _field('right', _intLit(0)),
        ]),
      );
      expect(out, contains('int n when'));
    });

    test('unknown pattern kind falls through (no native syntax)', () {
      // An unrecognized pattern typeName returns null → the case is dropped,
      // leaving an empty switch body (no false case emitted).
      final out = _flatPattern(_msg('TotallyUnknownPattern', []));
      expect(out, contains('switch (x) { }'));
      expect(out, isNot(contains('=>')));
    });
  });
}
