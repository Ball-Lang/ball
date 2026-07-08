/// Final-tail emission tests for the compiler's long-tail branches, built as
/// Ball IR (plus a few round-trips) so each is hit deterministically:
///   * class-member name partition without a module colon (`Class.method`).
///   * extension-type representation annotations + descriptor instance fields.
///   * expression-body constructor (`=> expr`); param alias without a type.
///   * goto-block result that is a std-control / break / no-label case.
///   * async* local-function signature; standalone `label` statement.
///   * `_compileStdStatementToString` labelled `break` (block-expr position).
///   * lambda-capture recursion into a block result / let value.
///   * switch-statement cosmetic pattern + value cases.
///   * assign list_concat → `..addAll`; cascade fieldAccess target.
///   * `_extractFields` single-value (non-message) input.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));
Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);
Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);
Expression _listLit(List<Expression> items) =>
    Expression()
      ..literal = (Literal()
        ..listValue = (ListLiteral()..elements.addAll(items)));

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

Expression _paren(Expression e) => _call('paren', [_field('value', e)]);

Statement _exprStmt(Expression e) => Statement()..expression = e;
Statement _letStmt(
  String name,
  Expression value, {
  Map<String, Object?>? meta,
}) {
  final lb = LetBinding()
    ..name = name
    ..value = value;
  if (meta != null) lb.mergeFromProto3Json({'metadata': meta});
  return Statement()..let = lb;
}

Expression _block(List<Statement> statements, {Expression? result}) {
  final b = Block()..statements.addAll(statements);
  if (result != null) b.result = result;
  return Expression()..block = b;
}

const _stdFns = [
  'print',
  'paren',
  'label',
  'goto',
  'return',
  'break',
  'assign',
  'list_concat',
  'switch',
  'yield',
  'for',
  'cascade',
];

Program _program({
  List<FunctionDefinition> members = const [],
  List<TypeDefinition> typeDefs = const [],
  Expression? mainBody,
}) {
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = mainBody ?? _call('print', [_field('message', _strLit('m'))]);
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in _stdFns)
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  return Program()
    ..name = 'emission_tail_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([...members, mainFn])
        ..typeDefs.addAll(typeDefs),
    ]);
}

FunctionDefinition _fn(
  String name, {
  Map<String, Object?>? metadata,
  Expression? body,
  String outputType = '',
}) {
  final fn = FunctionDefinition()..name = name;
  if (outputType.isNotEmpty) fn.outputType = outputType;
  if (body != null) fn.body = body;
  if (metadata != null) fn.mergeFromProto3Json({'metadata': metadata});
  return fn;
}

String _flat(Program p) =>
    DartCompiler(p, noFormat: true).compile().replaceAll(RegExp(r'\s+'), ' ');
String _flatBody(Expression body) =>
    _flat(_program(members: [_fn('host', body: body)]));
String _rt(String src) => DartCompiler(
  DartEncoder().encode(src),
  noFormat: true,
).compile().replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('class-member partition without a module colon', () {
    test('member named `Class.method` (no colon) is grouped to its class', () {
      final method = _fn(
        'Widget.render',
        metadata: {'kind': 'method'},
        body: _ref('input'),
      );
      final td = TypeDefinition()..name = 'Widget';
      td.mergeFromProto3Json({
        'descriptor': {'name': 'Widget'},
        'metadata': {'doc': '/// w'},
      });
      final out = _flat(_program(members: [method], typeDefs: [td]));
      expect(out, contains('class Widget'));
      expect(out, contains('render'));
    });
  });

  group('extension-type rep annotations + descriptor fields', () {
    test('rep field annotation and an extra instance field', () {
      final td = TypeDefinition()..name = 'main:Wrapped';
      td.mergeFromProto3Json({
        'descriptor': {
          'name': 'Wrapped',
          'field': [
            {'name': 'cached', 'type': 'TYPE_INT32', 'label': 'LABEL_OPTIONAL'},
          ],
        },
        'metadata': {
          'kind': 'extension_type',
          'rep_type': 'int',
          'rep_field': 'value',
          'rep_annotations': ['protected'],
          'fields': [
            {'name': 'cached', 'type': 'int', 'is_final': false},
          ],
        },
      });
      final out = _flat(_program(typeDefs: [td]));
      expect(out, contains('extension type Wrapped'));
      expect(out, contains('@protected'));
    });
  });

  group('expression-body constructor', () {
    test('factory with expression body emits `=> expr`', () {
      final td = TypeDefinition()..name = 'main:F';
      td.mergeFromProto3Json({
        'descriptor': {'name': 'F'},
        'metadata': {'doc': '/// f'},
      });
      final ctor = _fn(
        'main:F.make',
        metadata: {
          'kind': 'constructor',
          'is_factory': true,
          'expression_body': true,
        },
        body: _stdCall('main', 'main:F.new', const []),
      );
      final out = _flat(_program(members: [ctor], typeDefs: [td]));
      expect(out, contains('factory F.make() => '));
    });
  });

  group('param alias without a type', () {
    test('single untyped positional param is aliased as `var x = input`', () {
      final fn = _fn(
        'greet',
        metadata: {
          'params': [
            {'name': 'name'},
          ],
        },
        body: _ref('name'),
      );
      final out = _flat(_program(members: [fn]));
      expect(out, contains('var name = input;'));
    });
  });

  group('goto block result variants', () {
    test('a non-label/goto std-control result inside a goto block', () {
      // Block has a label statement (→ goto-switch path) AND a `return` result.
      final body = _block([
        _exprStmt(
          _stdCall('std', 'label', [
            _field('name', _strLit('L')),
            _field('body', _call('print', [_field('message', _strLit('x'))])),
          ]),
        ),
      ], result: _call('return', [_field('value', _intLit(0))]));
      final out = _flat(
        _program(
          members: [_fn('host', outputType: 'int', body: body)],
        ),
      );
      expect(out, contains('switch (0)'));
      expect(out, contains('return 0;'));
    });

    test('a goto block whose only statement is a goto (no labels)', () {
      // resultIsLabel triggers the goto-switch with no label statements:
      // firstLabelIdx defaults to statements.length and case 0 ends in break.
      final body = _block(
        [
          _exprStmt(_call('print', [_field('message', _strLit('a'))])),
        ],
        result: _stdCall('std', 'label', [
          _field('name', _strLit('only')),
          _field('body', _call('print', [_field('message', _strLit('b'))])),
        ]),
      );
      final out = _flatBody(body);
      expect(out, contains('switch (0)'));
      expect(out, contains('break;'));
      expect(out, contains('only:'));
    });
  });

  group('async* local function', () {
    test('async* lambda local fn emits async* signature', () {
      final lambdaFn = _fn(
        '_g',
        outputType: 'Stream<int>',
        metadata: {'is_async_star': true},
        body: _block([
          _exprStmt(_call('yield', [_field('value', _intLit(1))])),
        ]),
      );
      final body = _block([_letStmt('g', Expression()..lambda = lambdaFn)]);
      final out = _flatBody(body);
      expect(out, contains('async*'));
    });
  });

  group('standalone label statement', () {
    test('a label among labels emits a switch case (statement form)', () {
      // Two labels make _generateGotoSwitchBlock group them; a label that is a
      // plain statement (not the result) hits the standalone-label arm.
      final body = _block([
        _exprStmt(
          _stdCall('std', 'label', [
            _field('name', _strLit('a')),
            _field('body', _call('print', [_field('message', _strLit('1'))])),
          ]),
        ),
        _exprStmt(_stdCall('std', 'goto', [_field('label', _strLit('a'))])),
      ]);
      final out = _flatBody(body);
      expect(out, contains('a:'));
      expect(out, contains('continue a;'));
    });
  });

  group('block-expr labelled break (_compileStdStatementToString)', () {
    test('break with a label inside a block expression', () {
      // paren(block { break L; }) compiles the block as an IIFE, routing the
      // break through _compileStdStatementToString.
      final body = _paren(
        _block([
          _exprStmt(_call('break', [_field('label', _strLit('L'))])),
        ]),
      );
      final out = _flatBody(body);
      expect(out, contains('break L;'));
    });
  });

  group('loop var captured by a lambda stays in the for-init', () {
    // A closure that captures the loop variable must NOT force the declaration
    // out of the `for` header: Dart's C-style `for` gives each iteration a
    // fresh binding, so the closure snapshots that iteration's value — the
    // per-iteration semantics the engine and goldens require (#303).
    test('loop var captured via a let inside a lambda body block', () {
      // for-init declares `i`; the body lambda's block has `let z = i;`.
      final initBlock = _block([_letStmt('i', _intLit(0))]);
      final lambdaFn = _fn('_l', body: _block([_letStmt('z', _ref('i'))]));
      final forBody = _block([_letStmt('f', Expression()..lambda = lambdaFn)]);
      final forCall = _call('for', [
        _field('init', initBlock),
        _field('condition', _ref('c')),
        _field('update', _ref('u')),
        _field('body', forBody),
      ]);
      final out = _flatBody(_block([_exprStmt(forCall)]));
      expect(out, contains('for (var i = 0; c; u)'));
      expect(out, isNot(contains('for (; c; u)')));
    });

    test('loop var captured via a lambda as a block result', () {
      final initBlock = _block([_letStmt('j', _intLit(0))]);
      final innerLambda = _fn('_l', body: _ref('j'));
      final forBody = _block(
        const [],
        result: Expression()..lambda = innerLambda,
      );
      final forCall = _call('for', [
        _field('init', initBlock),
        _field('condition', _ref('c')),
        _field('update', _ref('u')),
        _field('body', forBody),
      ]);
      final out = _flatBody(_block([_exprStmt(forCall)]));
      expect(out, contains('for (var j = 0; c; u)'));
    });
  });

  group('switch statement labels', () {
    test('cosmetic pattern with `when`, and a plain value case', () {
      final body = _block([
        _exprStmt(
          _stdCall('std', 'switch', [
            _field('subject', _ref('x')),
            _field(
              'cases',
              _listLit([
                // Cosmetic-pattern case carrying its own `when`.
                _msg([
                  _field('pattern', _strLit('int n when n > 0')),
                  _field(
                    'body',
                    _call('print', [_field('message', _strLit('p'))]),
                  ),
                ]),
                // Plain value case.
                _msg([
                  _field('value', _intLit(0)),
                  _field(
                    'body',
                    _call('print', [_field('message', _strLit('z'))]),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ]);
      final out = _flatBody(body);
      expect(out, contains('case int n when n > 0:'));
      expect(out, contains('case 0:'));
    });
  });

  group('assign list_concat → addAll', () {
    test('assign(x, list_concat(left=x, right=ys)) → x.addAll(ys)', () {
      final body = _block([
        _exprStmt(
          _call('assign', [
            _field('target', _ref('xs')),
            _field(
              'value',
              _stdCall('std_collections', 'list_concat', [
                _field('left', _ref('xs')),
                _field('right', _ref('ys')),
              ]),
            ),
          ]),
        ),
      ]);
      final p = _program(members: [_fn('host', body: body)]);
      p.modules.add(
        Module()
          ..name = 'std_collections'
          ..functions.add(
            FunctionDefinition()
              ..name = 'list_concat'
              ..isBase = true,
          ),
      );
      final out = _flat(p);
      expect(out, contains('xs.addAll(ys);'));
    });
  });

  group('_extractFields single-value input', () {
    test('a base call whose input is a bare literal (not a message)', () {
      // print's input is a direct string literal, not a MessageCreation; the
      // field map collapses to {'value': literal}. print reads `message`, so
      // it falls back to `print()` but exercises the {'value': input} path.
      final printCall = Expression()
        ..call = (FunctionCall()
          ..module = 'std'
          ..function = 'paren'
          ..input = _strLit('hi'));
      final out = _flatBody(printCall);
      expect(out, contains("('hi')"));
    });
  });

  group('round-trip: catch var promotion + cascade self-method', () {
    test('`if (e is Map)` keeps subscript; `if (e is MyClass)` promotes', () {
      final out = _rt('''
class MyClass { int x = 0; }
void main() {
  try {
    throw MyClass();
  } catch (e) {
    if (e is Map) { print(e['k'].toString()); }
    if (e is MyClass) { print(e.x.toString()); }
  }
}
''');
      // `e is Map` keeps map subscript semantics inside the branch. (noFormat
      // emits stray spaces around the subscript: `e [ 'k' ]`.)
      expect(out.replaceAll(' ', ''), contains("e['k']"));
      // `e is MyClass` promotes to dotted member access.
      expect(out, contains('e.x'));
    });

    test('cascade with method-call sections compiles to `..method()`', () {
      final out = _rt('''
void main() {
  var sb = StringBuffer()..write('a')..writeln('b');
  print(sb.toString());
}
''');
      expect(out, contains("write('a')"));
    });
  });

  group('round-trip: for-in pattern destructuring', () {
    test('for ((a, b) in pairs) compiles a pattern for-in', () {
      final out = _rt('''
void main() {
  for (final (a, b) in [(1, 2)]) {
    print((a + b).toString());
  }
}
''');
      expect(out, contains('for (final ('));
    });
  });
}
