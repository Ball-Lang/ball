/// Wave-6 tail-coverage for `compiler.dart` (issue #61): the
/// catch-bound-variable field-access rewrite (`_compileFieldAccess`) for a
/// Ball tag-typed catch, where the caught value is compiled as a Dart `Map`
/// and dotted `.field` access must become `['field']` indexing — except for
/// the two universal `Object` members (`runtimeType`/`hashCode`), which stay
/// dotted since every value (including a `Map`) has them.
///
/// Reuses the `_flatHelper` Ball-IR-builder pattern from
/// try_catch_emission_test.dart (a tag catch never arises from the Dart
/// encoder for a declared type, so it is built as Ball IR directly).
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:test/test.dart';

// ── Ball-IR builders (mirrors try_catch_emission_test.dart). ──────────────
Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);
Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);
FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;
Expression _msg(List<FieldValuePair> fields) =>
    Expression()
      ..messageCreation = (MessageCreation()
        ..typeName = ''
        ..fields.addAll(fields));
Expression _stdCall(String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = fn
        ..input = _msg(fields));
Statement _exprStmt(Expression e) => Statement()..expression = e;
Expression _block(List<Statement> stmts) =>
    Expression()..block = (Block()..statements.addAll(stmts));
Expression _list(List<Expression> elems) =>
    Expression()
      ..literal = (Literal()
        ..listValue = (ListLiteral()..elements.addAll(elems)));
Expression _print(Expression v) => _stdCall('print', [_field('value', v)]);
Expression _throwTag(String tag) => _stdCall('throw', [
  _field('value', _msg([_field('__type', _strLit(tag))])),
]);
Expression _fieldAccess(Expression obj, String field) =>
    Expression()
      ..fieldAccess = (FieldAccess()
        ..object = obj
        ..field_2 = field);

/// Compile [helperBody] as the body of a standalone `helper()` function.
String _flatHelper(Expression helperBody) {
  final helper = FunctionDefinition()
    ..name = 'helper'
    ..body = helperBody;
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = _print(_strLit('m'));
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in const ['print', 'throw', 'rethrow', 'try', 'to_string'])
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  final program = Program()
    ..name = 'compiler_wave6_coverage_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([helper, mainFn]),
    ]);
  return DartCompiler(
    program,
    noFormat: true,
  ).compile().replaceAll(RegExp(r'\s+'), ' ');
}

void main() {
  group('tag-catch bound variable field access', () {
    test('a custom field on a tag-caught variable indexes into the Map', () {
      // try { throw {__type: 'BallTag', code: 'x'}; }
      //   on BallTag catch (e) { print(e.code); }
      final tryCall = _stdCall('try', [
        _field('body', _block([_exprStmt(_throwTag('BallTag'))])),
        _field(
          'catches',
          _list([
            _msg([
              _field('type', _strLit('BallTag')),
              _field('variable', _strLit('e')),
              _field(
                'body',
                _block([_exprStmt(_fieldAccess(_ref('e'), 'code'))]),
              ),
            ]),
          ]),
        ),
      ]);
      final out = _flatHelper(_block([_exprStmt(tryCall)]));
      // A custom field must be indexed, not dotted, on the Map-typed catch.
      expect(out, contains("e['code']"));
      expect(out, isNot(contains('e.code')));
    });

    test('runtimeType stays dotted on a tag-caught variable', () {
      final tryCall = _stdCall('try', [
        _field('body', _block([_exprStmt(_throwTag('BallTag'))])),
        _field(
          'catches',
          _list([
            _msg([
              _field('type', _strLit('BallTag')),
              _field('variable', _strLit('e')),
              _field(
                'body',
                _block([_exprStmt(_fieldAccess(_ref('e'), 'runtimeType'))]),
              ),
            ]),
          ]),
        ),
      ]);
      final out = _flatHelper(_block([_exprStmt(tryCall)]));
      expect(out, contains('e.runtimeType'));
      expect(out, isNot(contains("e['runtimeType']")));
    });
  });
}
