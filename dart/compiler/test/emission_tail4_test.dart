/// Final reachable-tail emission tests (IR):
///   * `_moduleHasExports` (a re-export facade module with empty declarations).
///   * goto-block whose result is a `goto` and which has no label statements.
///   * for-init expression fallback (`_e(initExpr)` for a non-block init).
///   * a `label` statement reached through `_generateStdStatement` (as an `if`
///     branch body, not folded into the goto-switch).
///   * self-method call carrying type args but no remaining positional args.
///   * `_stripCascadeSelf` null-aware (`..?.x`) section.
///   * `_compileLiteralValue` default branch (a non-int/string record name).
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:test/test.dart';

Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);
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

Expression _block(List<Statement> statements, {Expression? result}) {
  final b = Block()..statements.addAll(statements);
  if (result != null) b.result = result;
  return Expression()..block = b;
}

const _stdFns = [
  'print',
  'paren',
  'if',
  'for',
  'goto',
  'label',
  'cascade',
  'null_aware_access',
  'record',
];

Program _program({
  List<FunctionDefinition> members = const [],
  List<Module> extraModules = const [],
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
    ..name = 'emission_tail4_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      ...extraModules,
      Module()
        ..name = 'main'
        ..functions.addAll([...members, mainFn]),
    ]);
}

FunctionDefinition _fn(
  String name, {
  Expression? body,
  String outputType = '',
}) {
  final fn = FunctionDefinition()..name = name;
  if (outputType.isNotEmpty) fn.outputType = outputType;
  if (body != null) fn.body = body;
  return fn;
}

DartCompiler _compiler(Program p) => DartCompiler(p, noFormat: true);
String _flat(Program p) =>
    _compiler(p).compile().replaceAll(RegExp(r'\s+'), ' ');
String _flatBody(Expression body) =>
    _flat(_program(members: [_fn('host', body: body)]));

void main() {
  group('_moduleHasExports', () {
    test('a facade module with dart_exports + no declarations is emitted', () {
      final p = _program();
      final facade = Module()..name = 'facade';
      facade.mergeFromProto3Json({
        'metadata': {
          'dart_exports': [
            {'uri': 'src/impl.dart'},
          ],
        },
      });
      p.modules.add(facade);
      final all = _compiler(p).compileAllModules();
      // The export-only facade is NOT skipped as an empty stub.
      expect(all.containsKey('facade'), isTrue);
      expect(all['facade'], contains("export 'src/impl.dart'"));
    });
  });

  group('goto block whose result is a goto (no labels)', () {
    test('result goto with no label statements ends case 0 in break', () {
      // resultIsLabel true via a `goto` result; no label statements ⇒
      // firstLabelIdx defaults to statements.length and case 0 → break.
      final body = _block([
        _exprStmt(_call('print', [_field('message', _strLit('a'))])),
      ], result: _stdCall('std', 'goto', [_field('label', _strLit('x'))]));
      final out = _flatBody(body);
      expect(out, contains('switch (0)'));
      expect(out, contains('continue x;'));
      expect(out, contains('break;'));
    });
  });

  group('for-init expression fallback', () {
    test('a non-block, non-string init expression is rendered via _e', () {
      // init is a call expression (assignment-like), not a let-block.
      final forCall = _call('for', [
        _field('init', _stdCall('main', 'setup', const [])),
        _field('condition', _ref('c')),
        _field('update', _ref('u')),
        _field('body', _call('print', [_field('message', _strLit('b'))])),
      ]);
      final out = _flat(
        _program(
          members: [
            _fn('setup'),
            _fn('host', body: _block([_exprStmt(forCall)])),
          ],
        ),
      );
      expect(out, contains('for (setup();'));
    });
  });

  group('label statement via _generateStdStatement', () {
    test('a label as an if-branch body is lowered as its own switch case', () {
      // The then-branch is a single `label` statement; _generateBranchBody sees
      // a std-control call and routes it to _generateStdStatement (case label).
      final labelBody = _stdCall('std', 'label', [
        _field('name', _strLit('inner')),
        _field('body', _call('print', [_field('message', _strLit('x'))])),
      ]);
      final ifStmt = _call('if', [
        _field('condition', _boolLit(true)),
        _field('then', labelBody),
      ]);
      final out = _flatBody(_block([_exprStmt(ifStmt)]));
      expect(out, contains('inner:'));
    });
  });

  group('self-method call with type args and no remaining args', () {
    test('obj.method<T>() with no positional args', () {
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'toList'
        ..input = _msg([_field('self', _ref('it'))]);
      call.typeArgs.add(TypeRef()..name = 'int');
      final out = _flatBody(_paren(Expression()..call = call));
      expect(out, contains('it.toList<int>()'));
    });
  });

  group('cascade null-aware-access section', () {
    test('cascade `..?.field` section keeps the null-aware operator', () {
      final naSection = _call('null_aware_access', [
        _field('target', _ref('__cascade_self__')),
        _field('field', _strLit('flag')),
      ]);
      final body = _paren(
        _call('cascade', [
          _field('target', _ref('b')),
          _field('sections', _listLit([naSection])),
        ]),
      );
      final out = _flatBody(body);
      expect(out, contains('?.flag'));
    });
  });

  group('_compileLiteralValue default branch', () {
    test('record legacy fields-list with a bool `name` falls to _e', () {
      // A bool literal name is neither string nor int ⇒ default `_e(expr)`.
      final rec = _call('record', [
        _field(
          'fields',
          _listLit([
            _msg([
              _field('name', _boolLit(true)),
              _field('value', _strLit('a')),
            ]),
          ]),
        ),
      ]);
      final out = _flatBody(_paren(rec));
      // The bool name renders as `true` (the default _e branch).
      expect(out, contains("true: 'a'"));
    });
  });
}
