/// Block-lowered cascades must compile to Dart's own `..` cascade syntax,
/// never to an immediately-invoked closure (issue #573, case 1).
///
/// `DartEncoder._encodeCascade` lowers every cascade it cannot route to a
/// collection base function into a `Block`:
///
/// ```
/// Block {
///   let __cascade_self__ = <target>   // metadata.kind == 'cascade'
///   <section>;  <section>; …
///   result = reference(__cascade_self__)
/// }
/// ```
///
/// `_compileBlockExpression` used to compile EVERY value-position `Block` to
/// `(() { … })()`. That is semantically fine but it introduces a function
/// literal, and Dart's flow analysis deliberately refuses to carry a local's
/// type promotion across a closure boundary. So this, from
/// `path/lib/src/context.dart`:
///
/// ```dart
/// from = from == null ? current : absolute(from);  // `from` promoted String
/// final fromParsed = _parse(from)..normalize();     // read inside the IIFE
/// ```
///
/// compiled back to a `_parse(from)` call inside a closure, where `from` is
/// demoted to `String?` again and `_parse(String)` rejects it.
///
/// Every pre-existing cascade test in this suite builds the NATIVE
/// `std.cascade(target:…, sections:[…])` `FunctionCall` shape, which the Dart
/// encoder never emits — which is exactly why none of them saw this. These
/// tests build the `Block` shape the encoder actually produces.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart'
    as structpb;
import 'package:test/test.dart';

Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));
Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);
Expression _nullLit() => Expression()..literal = Literal();

FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

Expression _msg(List<FieldValuePair> fields, {String typeName = ''}) =>
    Expression()
      ..messageCreation = (MessageCreation()
        ..typeName = typeName
        ..fields.addAll(fields));

Expression _stdCall(String module, String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = module
        ..function = fn
        ..input = _msg(fields));

Expression _call(String fn, List<FieldValuePair> fields) =>
    _stdCall('std', fn, fields);

/// `<self>.<method>()` — the shape the encoder emits for a `..method()`
/// cascade section (the section's receiver is the bound `__cascade_self__`).
Expression _methodOn(String self, String method) =>
    _stdCall('main', method, [_field('self', _ref(self))]);

Expression _fieldAccess(Expression object, String field) =>
    Expression()
      ..fieldAccess = (FieldAccess()
        ..object = object
        ..field_2 = field);

Statement _exprStmt(Expression e) => Statement()..expression = e;

Statement _cascadeLet(String name, Expression value, {bool nullAware = false}) {
  final meta = structpb.Struct()
    ..fields['kind'] = (structpb.Value()..stringValue = 'cascade');
  if (nullAware) {
    meta.fields['null_aware'] = structpb.Value()..boolValue = true;
  }
  return Statement()
    ..let = (LetBinding()
      ..name = name
      ..value = value
      ..metadata = meta);
}

Statement _plainLet(String name, Expression value) =>
    Statement()
      ..let = (LetBinding()
        ..name = name
        ..value = value);

Expression _block(List<Statement> statements, {Expression? result}) {
  final b = Block()..statements.addAll(statements);
  if (result != null) b.result = result;
  return Expression()..block = b;
}

/// `std.if(condition: std.equals(left: ref, right: null), then: null,
/// else: <inner>)` — `_buildNullGuard`'s exact output.
Expression _nullGuard(String name, Expression inner) => _call('if', [
  _field(
    'condition',
    _call('equals', [_field('left', _ref(name)), _field('right', _nullLit())]),
  ),
  _field('then', _nullLit()),
  _field('else', inner),
]);

const _stdFns = ['print', 'if', 'equals', 'assign', 'paren'];

Program _program(Expression hostBody) {
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in _stdFns)
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  return Program()
    ..name = 'cascade_block_lowering_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([
          FunctionDefinition()
            ..name = 'host'
            ..body = hostBody,
          FunctionDefinition()
            ..name = 'main'
            ..body = _call('print', [
              _field(
                'message',
                Expression()..literal = (Literal()..stringValue = 'm'),
              ),
            ]),
        ]),
    ]);
}

/// The compiled `host` function, whitespace-collapsed.
///
/// [body] is placed in VALUE position (as a call argument) — a `Block` that IS
/// the whole function body is emitted as plain statements by
/// `_generateFunctionBody` and never reaches the value-position lowering under
/// test here.
String _flat(Expression body) => DartCompiler(
  _program(_call('print', [_field('message', body)])),
  noFormat: true,
).compile().replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('Block-lowered cascade → native `..` syntax (#573 case 1)', () {
    test('single-section cascade emits no immediately-invoked closure', () {
      final body = _block([
        _cascadeLet('__cascade_self__', _stdCall('main', 'parse', [])),
        _exprStmt(_methodOn('__cascade_self__', 'normalize')),
      ], result: _ref('__cascade_self__'));

      final out = _flat(body);
      expect(
        out,
        contains('(parse()..normalize())'),
        reason: 'compiled output was:\n$out',
      );
      expect(
        out,
        isNot(contains('(() {')),
        reason:
            'the IIFE reintroduces a closure boundary, across which Dart '
            'refuses to carry local type promotion (#573). Output:\n$out',
      );
      expect(out, isNot(contains('__cascade_self__')));
    });

    test('multi-section cascade chains every section', () {
      final body = _block([
        _cascadeLet('__cascade_self__', _stdCall('main', 'parse', [])),
        _exprStmt(_methodOn('__cascade_self__', 'normalize')),
        _exprStmt(_methodOn('__cascade_self__', 'clean')),
      ], result: _ref('__cascade_self__'));

      final out = _flat(body);
      expect(
        out,
        contains('(parse()..normalize()..clean())'),
        reason: 'compiled output was:\n$out',
      );
      expect(out, isNot(contains('(() {')));
    });

    test('a `..field = v` section keeps the assignment inside the cascade', () {
      final body = _block([
        _cascadeLet('__cascade_self__', _stdCall('main', 'parse', [])),
        _exprStmt(
          _call('assign', [
            _field('target', _fieldAccess(_ref('__cascade_self__'), 'depth')),
            _field('value', _intLit(1)),
          ]),
        ),
      ], result: _ref('__cascade_self__'));

      final out = _flat(body);
      expect(
        out,
        contains('(parse()..depth = 1)'),
        reason: 'compiled output was:\n$out',
      );
      expect(out, isNot(contains('(() {')));
    });

    test('null-aware cascade emits `?..` and no closure', () {
      // `_encodeCascade`'s isNullAware branch nests the sections inside a
      // second Block behind `std.if(equals(self, null), null, …)`.
      final body = _block(
        [
          _cascadeLet(
            '__cascade_self__',
            _stdCall('main', 'parse', []),
            nullAware: true,
          ),
        ],
        result: _nullGuard(
          '__cascade_self__',
          _block([
            _exprStmt(_methodOn('__cascade_self__', 'normalize')),
            _exprStmt(_methodOn('__cascade_self__', 'clean')),
          ], result: _ref('__cascade_self__')),
        ),
      );

      final out = _flat(body);
      expect(
        out,
        contains('(parse()?..normalize()..clean())'),
        reason: 'compiled output was:\n$out',
      );
      expect(out, isNot(contains('(() {')));
    });
  });

  group('the recognizer stays conservative (#573 case 1)', () {
    test('an untagged let is still lowered to a closure', () {
      final body = _block([
        _plainLet('__cascade_self__', _stdCall('main', 'parse', [])),
        _exprStmt(_methodOn('__cascade_self__', 'normalize')),
      ], result: _ref('__cascade_self__'));

      final out = _flat(body);
      expect(
        out,
        contains('(() {'),
        reason:
            'without the encoder\'s `kind: cascade` tag this Block is not '
            'provably a cascade, so it must keep the generic lowering. '
            'Output:\n$out',
      );
    });

    test('a result that is not the bound name is still a closure', () {
      final body = _block([
        _cascadeLet('__cascade_self__', _stdCall('main', 'parse', [])),
        _exprStmt(_methodOn('__cascade_self__', 'normalize')),
      ], result: _intLit(7));

      final out = _flat(body);
      expect(out, contains('(() {'), reason: 'output:\n$out');
    });

    test('a second let among the sections is still a closure', () {
      final body = _block([
        _cascadeLet('__cascade_self__', _stdCall('main', 'parse', [])),
        _plainLet('tmp', _intLit(1)),
        _exprStmt(_methodOn('__cascade_self__', 'normalize')),
      ], result: _ref('__cascade_self__'));

      final out = _flat(body);
      expect(out, contains('(() {'), reason: 'output:\n$out');
    });

    test('a cascade Block nested inside a non-matching Block keeps its own '
        'real `__cascade_self__` local', () {
      // The inner Block has an extra `let`, so it cannot be recognized. Its
      // `__cascade_self__` is then a genuine local and the sections inside it
      // must KEEP their explicit receiver rather than collapse to `..method()`.
      final inner = _block([
        _cascadeLet('__cascade_self__', _stdCall('main', 'inner', [])),
        _plainLet('tmp', _intLit(1)),
        _exprStmt(_methodOn('__cascade_self__', 'normalize')),
      ], result: _ref('__cascade_self__'));

      final body = _block([
        _cascadeLet('__cascade_self__', _stdCall('main', 'parse', [])),
        _exprStmt(
          _stdCall('main', 'consume', [
            _field('self', _ref('x')),
            _field('arg0', inner),
          ]),
        ),
      ], result: _ref('__cascade_self__'));

      final out = _flat(body);
      expect(
        out,
        contains('__cascade_self__.normalize()'),
        reason:
            'the inner Block is not cascade-shaped, so its bound name is a '
            'real local and the receiver must survive. Output:\n$out',
      );
    });
  });
}
