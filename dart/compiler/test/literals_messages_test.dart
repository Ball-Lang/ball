/// Unit tests for literal emission (`_compileLiteral` / `_dartStringLiteral`)
/// and message-creation emission (`_compileMessageCreation`): control-character
/// escaping, bytes/list/bool/double/null literals, the map-literal-entry
/// sentinel, builtin const named constructors, const constructors, and
/// type-argument metadata.
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

/// Wrap [expr] in `paren()` to compile it in expression position.
Expression _paren(Expression expr) => _call('paren', [_field('value', expr)]);

Program _program(Expression body) {
  final std = Module()
    ..name = 'std'
    ..functions.add(
      FunctionDefinition()
        ..name = 'paren'
        ..isBase = true,
    );
  return Program()
    ..name = 'literals_messages_test'
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
String _flat(Expression body) => _compile(body).replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('string-literal control character escaping', () {
    test('escapes the full control-char set', () {
      // Build from explicit code units so every escaper branch is hit:
      // backspace(0x08), tab(0x09), newline(0x0a), vertical-tab(0x0b),
      // form-feed(0x0c), carriage-return(0x0d), dollar(0x24), single-quote
      // (0x27), backslash(0x5c), DEL(0x7f), C1 control(0x85), and a sub-0x20
      // control (0x01 -> \x01).
      final raw = String.fromCharCodes([
        0x08,
        0x09,
        0x0a,
        0x0b,
        0x0c,
        0x0d,
        0x24,
        0x27,
        0x5c,
        0x7f,
        0x85,
        0x01,
      ]);
      final out = _compile(_paren(_strLit(raw)));
      expect(out, contains(r'\b'));
      expect(out, contains(r'\t'));
      expect(out, contains(r'\n'));
      expect(out, contains(r'\v'));
      expect(out, contains(r'\f'));
      expect(out, contains(r'\r'));
      expect(out, contains(r'\$'));
      expect(out, contains(r"\'"));
      expect(out, contains(r'\\'));
      expect(out, contains(r'\x7F'));
      expect(out, contains(r'\u0085'));
      expect(out, contains(r'\x01'));
    });

    test('double-quote and printable ascii are preserved verbatim', () {
      final out = _compile(_paren(_strLit('a"b c')));
      expect(out, contains('a"b c'));
    });
  });

  group('non-string literals', () {
    test('bool literal', () {
      expect(
        _compile(_paren(Expression()..literal = (Literal()..boolValue = true))),
        contains('true'),
      );
    });
    test('double literal', () {
      expect(
        _compile(
          _paren(Expression()..literal = (Literal()..doubleValue = 2.5)),
        ),
        contains('2.5'),
      );
    });
    test('bytes literal', () {
      final out = _compile(
        _paren(Expression()..literal = (Literal()..bytesValue = [1, 2, 3])),
      );
      expect(out, contains('[1, 2, 3]'));
    });
    test('list literal', () {
      final list = Expression()
        ..literal = (Literal()
          ..listValue = (ListLiteral()
            ..elements.addAll([_intLit(1), _intLit(2)])));
      // code_builder emits a trailing comma in unformatted mode.
      expect(_flat(_paren(list)), contains('[1, 2,'));
    });
    test('notSet literal compiles to null', () {
      expect(
        _compile(_paren(Expression()..literal = Literal())),
        contains('null'),
      );
    });
  });

  group('message creation', () {
    test('empty message marker', () {
      expect(_compile(_paren(_msg('', []))), contains('/* empty message */'));
    });
    test('map-literal-entry sentinel (key/value pair)', () {
      final out = _flat(
        _paren(
          _msg('', [_field('key', _strLit('a')), _field('value', _intLit(1))]),
        ),
      );
      expect(out, contains("'a': 1"));
    });
    test('plain constructor', () {
      expect(
        _flat(_paren(_msg('main:Widget', [_field('width', _intLit(10))]))),
        contains('Widget(width: 10)'),
      );
    });
    test('zero-arg constructor', () {
      expect(_compile(_paren(_msg('main:Widget', []))), contains('Widget()'));
    });
    test('builtin const named constructor', () {
      // "bool:fromEnvironment" -> `const bool.fromEnvironment(...)`.
      final out = _flat(
        _paren(_msg('bool:fromEnvironment', [_field('name', _strLit('FLAG'))])),
      );
      expect(out, contains('const bool.fromEnvironment'));
    });
    test('const via legacy __const__ field', () {
      final out = _flat(
        _paren(
          _msg('main:Vec', [
            _field('x', _intLit(1)),
            _field(
              '__const__',
              Expression()..literal = (Literal()..boolValue = true),
            ),
          ]),
        ),
      );
      expect(out, contains('const Vec(x: 1)'));
    });
    test('type args via legacy __type_args__ field', () {
      final out = _flat(
        _paren(
          _msg('main:Box', [
            _field('__type_args__', _strLit('<int>')),
            _field('item', _intLit(5)),
          ]),
        ),
      );
      expect(out, contains('Box<int>(item: 5)'));
    });
    test('type args via metadata (nested generics + nullable)', () {
      final mc = MessageCreation()
        ..typeName = 'main:Holder'
        ..fields.add(_field('value', _intLit(1)));
      mc.mergeFromProto3Json({
        'metadata': {
          'type_args': [
            {
              'name': 'List',
              'type_args': [
                {'name': 'int', 'nullable': true},
              ],
            },
          ],
        },
      });
      final out = _flat(_paren(Expression()..messageCreation = mc));
      expect(out, contains('Holder<List<int?>>(value: 1)'));
    });
    test('generic named constructor (TypeName<T>.ctor form)', () {
      final out = _flat(
        _paren(
          _msg('main:Map.from', [
            _field('__type_args__', _strLit('<String, int>')),
            _field('other', _intLit(0)),
          ]),
        ),
      );
      expect(out, contains('Map<String, int>.from'));
    });
  });
}
