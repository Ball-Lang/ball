/// Unit tests for the compiler's defensive `/* invalid ... */` fallbacks in
/// `_compileBaseCall` — the markers emitted when a base call is missing the
/// operand fields its lowering requires. These are reachable shapes (a
/// hand-written or cross-language Ball program can emit a malformed call), so
/// they are pinned with real tests rather than ignored.
///
/// Covers the unary/method/property/static/type/math helper guards and the
/// string replace/pad guards.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:test/test.dart';

FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

Expression _msg(List<FieldValuePair> fields) =>
    Expression()
      ..messageCreation = (MessageCreation()
        ..typeName = ''
        ..fields.addAll(fields));

Expression _call(String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = fn
        ..input = _msg(fields));

/// Wrap [expr] in `paren()` to force the expression-compilation path.
Expression _paren(Expression expr) => _call('paren', [_field('value', expr)]);

Program _program(Expression body) {
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in const ['paren', 'print'])
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  return Program()
    ..name = 'invalid_markers_test'
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
            ..body = body,
        ),
    ]);
}

String _compile(Expression body) =>
    DartCompiler(_program(body), noFormat: true).compile();

/// Compile a base call [fn] with no operand fields and return the source.
String _empty(String fn) => _compile(_paren(_call(fn, const [])));

void main() {
  group('unary op guards (missing value)', () {
    test('prefix ops: negate / not / bitwise_not', () {
      expect(_empty('negate'), contains('/* invalid - */'));
      expect(_empty('not'), contains('/* invalid ! */'));
      expect(_empty('bitwise_not'), contains('/* invalid ~ */'));
    });
    test('prefix mutation: pre_increment / pre_decrement', () {
      expect(_empty('pre_increment'), contains('/* invalid ++ */'));
      expect(_empty('pre_decrement'), contains('/* invalid -- */'));
    });
    test('postfix mutation: post_increment / post_decrement / null_check', () {
      expect(_empty('post_increment'), contains('/* invalid ++ */'));
      expect(_empty('post_decrement'), contains('/* invalid -- */'));
      expect(_empty('null_check'), contains('/* invalid ! */'));
    });
  });

  group('member-access guards (missing value)', () {
    test('method call expr: int_to_string', () {
      expect(_empty('int_to_string'), contains('/* invalid .toString() */'));
    });
    test('property access: length', () {
      expect(_empty('length'), contains('/* invalid .length */'));
    });
    test('static call: string_to_int', () {
      expect(_empty('string_to_int'), contains('/* invalid int.parse() */'));
    });
  });

  group('two-operand guards (missing left/right)', () {
    test('method2: string_contains', () {
      expect(_empty('string_contains'), contains('/* invalid contains() */'));
    });
    test('math binary: math_pow', () {
      expect(_empty('math_pow'), contains('/* invalid pow */'));
    });
  });

  group('math / type guards', () {
    test('math func: math_sqrt missing value', () {
      expect(_empty('math_sqrt'), contains('/* invalid sqrt */'));
    });
    test('type op: as missing value/type', () {
      expect(_empty('as'), contains('/* invalid as */'));
    });
  });

  group('string helper guards', () {
    test('string_replace missing operands', () {
      expect(_empty('string_replace'), contains('/* invalid replaceFirst */'));
    });
    test('string_pad_left missing operands', () {
      expect(_empty('string_pad_left'), contains('/* invalid padLeft */'));
    });
  });
}
