/// Unit tests for `_compileCall` (the non-base user/qualified call path):
/// self-method calls with type arguments (TypeRef and legacy `__type_args__`),
/// the `dart.*` module-prefix fallback without an explicit alias, qualified
/// constructor-style function names (`main:Dog.new` → `Dog.new`), and
/// argument-list calls carrying type arguments.
///
/// Built as Ball IR directly so the exact call shapes are pinned.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));
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

Expression _paren(Expression e) => _stdCall('paren', [_field('value', e)]);

/// Build a program whose `main` body is [body] (wrapped in `paren` by the
/// caller for expression position). [extraFns] are added to module `main`.
Program _program(Expression body) {
  final std = Module()
    ..name = 'std'
    ..functions.add(
      FunctionDefinition()
        ..name = 'paren'
        ..isBase = true,
    );
  return Program()
    ..name = 'compile_call_test'
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

String _flat(Expression body) => DartCompiler(
  _program(_paren(body)),
  noFormat: true,
).compile().replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('self-method calls with type arguments', () {
    test('TypeRef type args on a self-method call', () {
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'cast'
        ..input = _msg([_field('self', _ref('obj'))]);
      call.typeArgs.add(TypeRef()..name = 'int');
      final out = _flat(Expression()..call = call);
      expect(out, contains('obj.cast<int>()'));
    });

    test('legacy __type_args__ field on a self-method call', () {
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'whereType'
        ..input = _msg([
          _field('self', _ref('list')),
          _field('__type_args__', _strLit('<String>')),
        ]);
      final out = _flat(Expression()..call = call);
      expect(out, contains('list.whereType<String>()'));
    });

    test('self-method call with extra positional args', () {
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'combine'
        ..input = _msg([_field('self', _ref('a')), _field('arg0', _intLit(2))]);
      final out = _flat(Expression()..call = call);
      expect(out, contains('a.combine(2)'));
    });
  });

  group('module-prefix fallback', () {
    test('dart.* module without alias uses the library name', () {
      // No dart_imports metadata ⇒ no alias ⇒ fallback to `math.`.
      final call = FunctionCall()
        ..module = 'dart.math'
        ..function = 'max'
        ..input = _msg([
          _field('arg0', _intLit(1)),
          _field('arg1', _intLit(2)),
        ]);
      final out = _flat(Expression()..call = call);
      expect(out, contains('math.max(1, 2)'));
    });
  });

  group('qualified constructor-style function name', () {
    test('main:Dog.new → Dog.new(...)', () {
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'main:Dog.new'
        ..input = _msg([_field('arg0', _strLit('rex'))]);
      final out = _flat(Expression()..call = call);
      expect(out, contains("Dog.new('rex')"));
    });
  });

  group('argument-list call with type arguments', () {
    test('TypeRef type args on a plain user call', () {
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'identity'
        ..input = _msg([_field('arg0', _intLit(7))]);
      call.typeArgs.add(TypeRef()..name = 'num');
      final out = _flat(Expression()..call = call);
      expect(out, contains('identity<num>(7)'));
    });

    test('legacy __type_args__ field on a plain user call', () {
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'wrap'
        ..input = _msg([
          _field('__type_args__', _strLit('<bool>')),
          _field('arg0', _intLit(0)),
        ]);
      final out = _flat(Expression()..call = call);
      expect(out, contains('wrap<bool>(0)'));
    });

    test('no-arg user call', () {
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'reset'
        ..input = _msg(const []);
      final out = _flat(Expression()..call = call);
      expect(out, contains('reset()'));
    });
  });
}
