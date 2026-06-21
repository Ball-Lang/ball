/// Unit tests for the compiler's expression-kind emit helpers: spread,
/// cascade, record, map/set/typed-list creation, invoke, tear-off, collection
/// if/for, null-aware access/index/call, inline-if, switch-expr, compound
/// assignment, await/throw, and the block-expression (IIFE) statement forms.
///
/// These build Ball IR directly so the long tail of helpers that the Dart
/// encoder rarely emits (or only emits through specific shapes) is exercised
/// deterministically.
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
Expression _boolLit(bool b) =>
    Expression()..literal = (Literal()..boolValue = b);
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

Expression _blockExpr(List<Statement> statements, {Expression? result}) {
  final b = Block()..statements.addAll(statements);
  if (result != null) b.result = result;
  return Expression()..block = b;
}

Statement _exprStmt(Expression e) => Statement()..expression = e;
Statement _letStmt(String name, Expression value) =>
    Statement()
      ..let = (LetBinding()
        ..name = name
        ..value = value);

/// Wrap a block expression in `paren()` so the compiler lowers it via
/// `_compileBlockExpression` (the IIFE form) instead of the function-body
/// statement path — that's where `_compileStdStatementToString` lives.
Expression _parenBlock(List<Statement> statements, {Expression? result}) =>
    _call('paren', [_field('value', _blockExpr(statements, result: result))]);

Program _program(Expression expr) {
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = expr;
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in const [
        'print',
        'paren',
        'spread',
        'null_spread',
        'cascade',
        'record',
        'map_create',
        'set_create',
        'typed_list',
        'invoke',
        'tear_off',
        'collection_if',
        'collection_for',
        'null_aware_access',
        'null_aware_index',
        'null_aware_call',
        'index',
        'if',
        'switch_expr',
        'assign',
        'await',
        'throw',
        'return',
        'break',
        'continue',
        'rethrow',
        'goto',
        'label',
      ])
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  return Program()
    ..name = 'expressions_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.add(mainFn),
    ]);
}

String _compile(Expression expr) =>
    DartCompiler(_program(expr), noFormat: true).compile();
String _flat(Expression expr) => _compile(expr).replaceAll(RegExp(r'\s+'), ' ');

/// Compile [expr] in EXPRESSION position by wrapping it in `paren()`, forcing
/// the compiler down `_compileExpression` rather than the statement path that
/// kicks in when a std-control call (`if`, `throw`, …) is a function body.
String _exprFlat(Expression expr) =>
    _flat(_call('paren', [_field('value', expr)]));

void main() {
  group('spread', () {
    test('spread', () {
      expect(
        _compile(_call('spread', [_field('value', _ref('xs'))])),
        contains('...xs'),
      );
    });
    test('null_spread', () {
      expect(
        _compile(_call('null_spread', [_field('value', _ref('xs'))])),
        contains('...?xs'),
      );
    });
    test('spread with missing value', () {
      expect(_compile(_call('spread', [])), contains('...null'));
    });
  });

  group('index / null-aware', () {
    test('index', () {
      expect(
        _flat(
          _call('index', [
            _field('target', _ref('xs')),
            _field('index', _intLit(0)),
          ]),
        ),
        contains('xs [ 0 ]'),
      );
    });
    test('index missing operands', () {
      expect(
        _compile(_call('index', [_field('target', _ref('xs'))])),
        contains('/* invalid [] */'),
      );
    });
    test('null_aware_index', () {
      expect(
        _compile(
          _call('null_aware_index', [
            _field('target', _ref('xs')),
            _field('index', _intLit(0)),
          ]),
        ),
        contains('xs?[0]'),
      );
    });
    test('null_aware_index missing operands', () {
      expect(
        _compile(_call('null_aware_index', [])),
        contains('/* invalid ?[] */'),
      );
    });
    test('null_aware_access', () {
      expect(
        _compile(
          _call('null_aware_access', [
            _field('target', _ref('obj')),
            _field('field', _strLit('name')),
          ]),
        ),
        contains('obj?.name'),
      );
    });
    test('null_aware_access missing field', () {
      expect(
        _compile(_call('null_aware_access', [_field('target', _ref('obj'))])),
        contains('/* invalid ?. */'),
      );
    });
    test('null_aware_call', () {
      expect(
        _compile(
          _call('null_aware_call', [
            _field('target', _ref('obj')),
            _field('method', _strLit('foo')),
            _field('arg0', _intLit(1)),
          ]),
        ),
        contains('obj?.foo(1)'),
      );
    });
    test('null_aware_call missing method', () {
      expect(
        _compile(_call('null_aware_call', [_field('target', _ref('obj'))])),
        contains('/* invalid ?. call */'),
      );
    });
  });

  group('inline if (ternary)', () {
    test('with else', () {
      expect(
        _exprFlat(
          _call('if', [
            _field('condition', _boolLit(true)),
            _field('then', _intLit(1)),
            _field('else', _intLit(2)),
          ]),
        ),
        contains('true ? 1 : 2'),
      );
    });
    test('without else defaults to null', () {
      expect(
        _exprFlat(
          _call('if', [
            _field('condition', _boolLit(true)),
            _field('then', _intLit(1)),
          ]),
        ),
        contains('true ? 1 : null'),
      );
    });
    test('missing condition/then', () {
      expect(
        _exprFlat(_call('if', [_field('then', _intLit(1))])),
        contains('/* invalid inline if */'),
      );
    });
  });

  group('cascade', () {
    test('cascade with sections', () {
      final out = _compile(
        _call('cascade', [
          _field('target', _ref('builder')),
          _field(
            'sections',
            _listLit([
              _call('tear_off', [
                _field('target', _ref('__cascade_self__')),
                _field('method', _strLit('add')),
              ]),
            ]),
          ),
        ]),
      );
      expect(out, contains('builder'));
      expect(out, contains('..'));
    });
    test('null-aware cascade first section uses ?..', () {
      final out = _compile(
        _call('cascade', [
          _field('target', _ref('builder')),
          _field('null_aware', _boolLit(true)),
          _field('sections', _listLit([_ref('x')])),
        ]),
      );
      expect(out, contains('?..'));
    });
    test('cascade missing target', () {
      expect(_compile(_call('cascade', [])), contains('/* invalid cascade */'));
    });
  });

  group('record', () {
    test('positional record', () {
      expect(
        _flat(
          _call('record', [
            _field(r'$0', _intLit(1)),
            _field(r'$1', _intLit(2)),
          ]),
        ),
        contains('(1, 2)'),
      );
    });
    test('single positional gets trailing comma', () {
      expect(
        _flat(_call('record', [_field(r'$0', _intLit(1))])),
        contains('(1,)'),
      );
    });
    test('named record fields', () {
      final out = _flat(
        _call('record', [
          _field(r'$0', _intLit(1)),
          _field('name', _strLit('a')),
        ]),
      );
      expect(out, contains('name:'));
    });
    test('empty record', () {
      expect(_compile(_call('record', [])), contains('void main() { ()'));
    });
    test('legacy fields-list format', () {
      final out = _flat(
        _call('record', [
          _field(
            'fields',
            _listLit([
              _msg('', [
                _field('name', _strLit('x')),
                _field('value', _intLit(7)),
              ]),
            ]),
          ),
        ]),
      );
      expect(out, contains('x: 7'));
    });
  });

  group('map_create / set_create / typed_list', () {
    test('empty map', () {
      expect(_compile(_call('map_create', [])), contains('{}'));
    });
    test('map with type args', () {
      expect(
        _compile(
          _call('map_create', [_field('type_args', _strLit('String, int'))]),
        ),
        contains('<String, int>{}'),
      );
    });
    test('map with entries', () {
      final out = _flat(
        _call('map_create', [
          _field(
            'entry',
            _msg('', [
              _field('key', _strLit('a')),
              _field('value', _intLit(1)),
            ]),
          ),
        ]),
      );
      expect(out, contains("'a': 1"));
    });
    test('set_create empty / typed / dynamic / with elements', () {
      expect(_compile(_call('set_create', [])), contains('{}'));
      expect(
        _compile(_call('set_create', [_field('type_args', _strLit('int'))])),
        contains('<int>{}'),
      );
      // A non-empty type_args string is emitted as a `<...>{}` prefix.
      expect(
        _flat(
          _call('set_create', [_field('type_args', _strLit('Set<dynamic>'))]),
        ),
        contains('<Set<dynamic>>{}'),
      );
      expect(
        _flat(
          _call('set_create', [
            _field('elements', _listLit([_intLit(1), _intLit(2)])),
          ]),
        ),
        contains('{1, 2}'),
      );
    });
    test('typed_list with and without elements', () {
      expect(
        _flat(
          _call('typed_list', [
            _field('type_args', _strLit('<int>')),
            _field('elements', _listLit([_intLit(1), _intLit(2)])),
          ]),
        ),
        contains('<int>[1, 2]'),
      );
      expect(
        _flat(_call('typed_list', [_field('type_args', _strLit('<int>'))])),
        contains('<int>[]'),
      );
    });
  });

  group('invoke / tear_off', () {
    test('invoke', () {
      expect(
        _compile(
          _call('invoke', [
            _field('callee', _ref('fn')),
            _field('arg0', _intLit(1)),
          ]),
        ),
        contains('fn(1)'),
      );
    });
    test('invoke missing callee', () {
      expect(_compile(_call('invoke', [])), contains('/* invalid invoke */'));
    });
    test('tear_off with target', () {
      expect(
        _compile(
          _call('tear_off', [
            _field('target', _ref('obj')),
            _field('method', _strLit('foo')),
          ]),
        ),
        contains('obj.foo'),
      );
    });
    test('tear_off without target (static)', () {
      expect(
        _compile(_call('tear_off', [_field('method', _strLit('bar'))])),
        contains('bar'),
      );
    });
  });

  group('collection if / for', () {
    test('collection_if with else', () {
      final out = _flat(
        _call('collection_if', [
          _field('condition', _boolLit(true)),
          _field('then', _intLit(1)),
          _field('else', _intLit(2)),
        ]),
      );
      expect(out, contains('if (true) 1 else 2'));
    });
    test('collection_if without else', () {
      final out = _flat(
        _call('collection_if', [
          _field('condition', _boolLit(true)),
          _field('then', _intLit(1)),
        ]),
      );
      expect(out, contains('if (true) 1'));
      expect(out, isNot(contains('else')));
    });
    test('collection_if missing operands', () {
      expect(
        _compile(_call('collection_if', [])),
        contains('/* invalid collection if */'),
      );
    });
    test('collection_for for-each form', () {
      final out = _flat(
        _call('collection_for', [
          _field('variable', _strLit('x')),
          _field('iterable', _ref('xs')),
          _field('body', _ref('x')),
        ]),
      );
      expect(out, contains('for (final x in xs) x'));
    });
    test('collection_for missing body', () {
      expect(
        _compile(_call('collection_for', [])),
        contains('/* invalid collection for */'),
      );
    });
  });

  group('switch_expr', () {
    test('value cases + default', () {
      final out = _flat(
        _call('switch_expr', [
          _field('subject', _ref('x')),
          _field(
            'cases',
            _listLit([
              _msg('', [
                _field('value', _intLit(1)),
                _field('body', _strLit('one')),
              ]),
              _msg('', [
                _field('is_default', _boolLit(true)),
                _field('body', _strLit('other')),
              ]),
            ]),
          ),
        ]),
      );
      expect(out, contains('switch (x)'));
      expect(out, contains("1 => 'one'"));
      expect(out, contains("_ => 'other'"));
    });
    test('cosmetic pattern label with guard baked in', () {
      final out = _flat(
        _call('switch_expr', [
          _field('subject', _ref('x')),
          _field(
            'cases',
            _listLit([
              _msg('', [
                _field('pattern', _strLit('int n when n > 0')),
                _field('body', _strLit('pos')),
              ]),
            ]),
          ),
        ]),
      );
      expect(out, contains('int n when n > 0 =>'));
      // Non-exhaustive guard appended.
      expect(out, contains("throw StateError('non-exhaustive')"));
    });
    test('missing subject', () {
      expect(
        _compile(_call('switch_expr', [])),
        contains('/* invalid switch expr */'),
      );
    });
  });

  group('compound assignment', () {
    final target = _field('target', _ref('x'));
    final value = _field('value', _intLit(1));
    test('all compound operators', () {
      final ops = {
        '+=': 'x += 1',
        '-=': 'x -= 1',
        '*=': 'x *= 1',
        '/=': 'x /= 1',
        '~/=': 'x ~/= 1',
        '%=': 'x %= 1',
        '&=': 'x &= 1',
        '|=': 'x |= 1',
        '^=': 'x ^= 1',
        '<<=': 'x <<= 1',
        '>>=': 'x >>= 1',
        '>>>=': 'x >>>= 1',
        '??=': 'x ??= 1',
      };
      ops.forEach((op, expected) {
        // Expression position exercises `_compileAssign`'s operator switch.
        final out = _exprFlat(
          _call('assign', [target, value, _field('op', _strLit(op))]),
        );
        expect(out, contains(expected), reason: 'op=$op');
      });
    });
    test('all compound operators (statement form)', () {
      // Function-body position exercises `_generateAssign`'s operator switch.
      final ops = {
        '+=': 'x += 1',
        '-=': 'x -= 1',
        '*=': 'x *= 1',
        '~/=': 'x ~/= 1',
        '??=': 'x ??= 1',
      };
      ops.forEach((op, expected) {
        final out = _flat(
          _call('assign', [target, value, _field('op', _strLit(op))]),
        );
        expect(out, contains(expected), reason: 'op=$op');
      });
    });
    test('plain assign (statement form)', () {
      expect(_flat(_call('assign', [target, value])), contains('x = 1'));
    });
    test('plain assign (expression form)', () {
      expect(_exprFlat(_call('assign', [target, value])), contains('x = 1'));
    });
    test('assign missing target/value', () {
      expect(
        _exprFlat(_call('assign', [target])),
        contains('/* invalid assign */'),
      );
    });
  });

  group('await / throw expressions', () {
    test('await with value', () {
      expect(
        _compile(_call('await', [_field('value', _ref('fut'))])),
        contains('await fut'),
      );
    });
    test('await without value', () {
      expect(_compile(_call('await', [])), contains('await null'));
    });
    test('throw expression (special map form)', () {
      final out = _exprFlat(
        _call('throw', [
          _field('value', _msg('', [_field('__type', _strLit('NotFound'))])),
        ]),
      );
      expect(out, contains("(throw {'__type': 'NotFound'})"));
    });
    test('throw expression with plain value', () {
      expect(
        _exprFlat(_call('throw', [_field('value', _ref('e'))])),
        contains('(throw'),
      );
    });
    test('throw without value', () {
      expect(_exprFlat(_call('throw', [])), contains('(throw null)'));
    });
  });

  group('block-expression statement forms (IIFE)', () {
    test('return / break / continue inside block expr', () {
      final out = _flat(
        _parenBlock([
          _exprStmt(_call('return', [_field('value', _intLit(1))])),
        ]),
      );
      expect(out, contains('return 1;'));

      expect(
        _flat(_parenBlock([_exprStmt(_call('break', []))])),
        contains('break;'),
      );
      expect(
        _flat(
          _parenBlock([
            _exprStmt(_call('continue', [_field('label', _strLit('outer'))])),
          ]),
        ),
        contains('continue outer;'),
      );
    });
    test('throw / rethrow inside block expr', () {
      expect(
        _flat(
          _parenBlock([
            _exprStmt(_call('throw', [_field('value', _ref('e'))])),
          ]),
        ),
        contains('throw e;'),
      );
      expect(
        _flat(_parenBlock([_exprStmt(_call('rethrow', []))])),
        contains('rethrow;'),
      );
    });
    test('assign statement inside block expr', () {
      expect(
        _flat(
          _parenBlock([
            _exprStmt(
              _call('assign', [
                _field('target', _ref('x')),
                _field('value', _intLit(5)),
              ]),
            ),
          ]),
        ),
        contains('x = 5;'),
      );
    });
    test('goto / label inside block expr', () {
      expect(
        _flat(
          _parenBlock([
            _exprStmt(_call('goto', [_field('label', _strLit('end'))])),
          ]),
        ),
        contains('continue end;'),
      );
      final labelOut = _flat(
        _parenBlock([
          _exprStmt(
            _call('label', [
              _field('name', _strLit('lbl')),
              _field('body', _intLit(1)),
            ]),
          ),
        ]),
      );
      expect(labelOut, contains('switch (0)'));
      expect(labelOut, contains('lbl:'));
    });
    test('let binding + result inside block expr', () {
      final out = _flat(
        _parenBlock([_letStmt('y', _intLit(3))], result: _ref('y')),
      );
      expect(out, contains('y = 3'));
      expect(out, contains('return y;'));
    });
    test('unsupported control fn in block expr emits marker', () {
      expect(
        _flat(
          _parenBlock([
            _exprStmt(_call('assert', [_field('value', _boolLit(true))])),
          ]),
        ),
        contains('unsupported block-expr statement: std.assert'),
      );
    });
  });
}
