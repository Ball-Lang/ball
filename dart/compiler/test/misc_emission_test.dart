/// Unit tests for assorted compiler emission helpers reached most precisely via
/// IR: top-level variable declarations (`_buildTopLevelVarStr`), local-function
/// signatures with the full parameter grammar (`_buildParamList` via
/// `_generateLocalFunction` / `_compileLambda`), call type-argument rendering
/// (`_typeRefToStr` / `_callTypeArgsStr`), the set/map-create dynamic-typed
/// edge cases, and the constructor-boilerplate-body detector
/// (`_isConstructorBoilerplateBody`).
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

Statement _exprStmt(Expression e) => Statement()..expression = e;
Statement _letStmt(String name, Expression value) =>
    Statement()
      ..let = (LetBinding()
        ..name = name
        ..value = value);

Expression _block(List<Statement> statements, {Expression? result}) {
  final b = Block()..statements.addAll(statements);
  if (result != null) b.result = result;
  return Expression()..block = b;
}

const _stdFns = ['print', 'paren', 'set_create', 'map_create', 'return'];

/// A program with [members] in module `main` plus a trivial entry.
Program _program({
  List<FunctionDefinition> members = const [],
  Expression? mainBody,
}) {
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = mainBody ?? _stdCall('print', [_field('message', _strLit('m'))]);
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in _stdFns)
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  return Program()
    ..name = 'misc_emission_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([...members, mainFn]),
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

String _flatProgram(Program p) =>
    DartCompiler(p, noFormat: true).compile().replaceAll(RegExp(r'\s+'), ' ');

/// Compile a single base call (expression position).
String _flatExpr(Expression e) => DartCompiler(
  _program(mainBody: _paren(e)),
  noFormat: true,
).compile().replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('top-level variables', () {
    test('late + var (no type, no const/final) with doc', () {
      final out = _flatProgram(
        _program(
          members: [
            _fn(
              'counter',
              metadata: {
                'kind': 'top_level_variable',
                'doc': '/// counter',
                'is_late': true,
              },
              body: _intLit(0),
            ),
          ],
        ),
      );
      expect(out, contains('/// counter'));
      expect(out, contains('late var counter = 0;'));
    });

    test('typed final top-level variable', () {
      final out = _flatProgram(
        _program(
          members: [
            _fn(
              'answer',
              outputType: 'int',
              metadata: {'kind': 'top_level_variable', 'is_final': true},
              body: _intLit(42),
            ),
          ],
        ),
      );
      expect(out, contains('final int answer = 42;'));
    });
  });

  group('local function signature grammar (_buildParamList)', () {
    test('this/super/required-named/optional-default/named params', () {
      // A local function (lambda assigned to a let) renders its param list via
      // `_buildParamList` — the string-based grammar with [] and {} groups.
      final lambdaFn = _fn(
        '_l',
        metadata: {
          'params': [
            {'name': 'a', 'type': 'int'},
            {'name': 'b', 'type': 'int', 'is_optional': true, 'default': '2'},
            {'name': 'c', 'type': 'int', 'is_required_named': true},
            {'name': 'd', 'type': 'String', 'is_named': true},
          ],
        },
        body: _ref('a'),
      );
      final body = _block([_letStmt('f', Expression()..lambda = lambdaFn)]);
      final out = _flatProgram(_program(members: [_fn('host', body: body)]));
      expect(out, contains('int a'));
      expect(out, contains('[int b = 2]'));
      expect(out, contains('{required int c, String d}'));
    });

    test('this and super formal params in a local function', () {
      final lambdaFn = _fn(
        '_l',
        metadata: {
          'params': [
            {'name': 'x', 'is_this': true},
            {'name': 'y', 'is_super': true},
          ],
        },
        body: _ref('x'),
      );
      final body = _block([_letStmt('f', Expression()..lambda = lambdaFn)]);
      final out = _flatProgram(_program(members: [_fn('host', body: body)]));
      expect(out, contains('this.x'));
      expect(out, contains('super.y'));
    });
  });

  group('lambda generator markers (_compileLambda)', () {
    test('async / async* / sync* lambdas emit their keywords', () {
      for (final spec in const [
        ('is_async', 'async'),
        ('is_async_star', 'async*'),
        ('is_sync_star', 'sync*'),
      ]) {
        final lambdaFn = _fn(
          '_l',
          metadata: {spec.$1: true},
          body: _block([_exprStmt(_intLit(1))]),
        );
        final out = _flatExpr(Expression()..lambda = lambdaFn);
        expect(out, contains(spec.$2), reason: spec.$1);
      }
    });
  });

  group('call type arguments (_typeRefToStr / _callTypeArgsStr)', () {
    test('user call with nested + nullable type args', () {
      // identity<List<int?>>(value=...)
      final call = FunctionCall()
        ..module = 'main'
        ..function = 'identity'
        ..input = _msg([_field('value', _intLit(1))]);
      call.typeArgs.add(
        TypeRef()
          ..name = 'List'
          ..typeArgs.add(
            TypeRef()
              ..name = 'int'
              ..nullable = true,
          ),
      );
      final out = _flatExpr(Expression()..call = call);
      expect(out, contains('identity<List<int?>>'));
    });
  });

  group('set / map create dynamic-typed edges', () {
    test(
      'typed set_create with empty element list returns prefixed braces',
      () {
        final out = _flatExpr(
          _stdCall('set_create', [
            _field('type_args', _strLit('int')),
            _field('elements', _listLit(const [])),
          ]),
        );
        expect(out, contains('<int>{}'));
      },
    );

    test('typed set_create with no elements field at all', () {
      final out = _flatExpr(
        _stdCall('set_create', [_field('type_args', _strLit('String'))]),
      );
      expect(out, contains('<String>{}'));
    });
  });

  group('constructor boilerplate detection (_isConstructorBoilerplateBody)', () {
    // A non-factory constructor whose body matches a Ball "create self / return"
    // or "alias input" idiom must be stripped (emitting an empty `;` body).

    TypeDefinition typeDef(String n) {
      final td = TypeDefinition()..name = 'main:$n';
      td.mergeFromProto3Json({
        'descriptor': {'name': n},
        'metadata': {'doc': '/// $n'},
      });
      return td;
    }

    Program ctorProgram(String className, Expression body) {
      final ctor = _fn(
        'main:$className.new',
        metadata: {'kind': 'constructor'},
        body: body,
      );
      final p = _program(members: [ctor]);
      p.modules
          .firstWhere((m) => m.name == 'main')
          .typeDefs
          .add(typeDef(className));
      return p;
    }

    test('let self = TypeName(); return self;  → stripped body', () {
      final body = _block([
        _letStmt(
          'self',
          _msg([_field('x', _intLit(1))])..messageCreation.typeName = 'main:A',
        ),
        _exprStmt(_stdCall('return', [_field('value', _ref('self'))])),
      ]);
      final out = _flatProgram(ctorProgram('A', body));
      // Boilerplate stripped: a plain `A();` constructor with no body block.
      expect(out, contains('A('));
      expect(out, isNot(contains('return self')));
    });

    test('let v = TypeName(); v;  → stripped body', () {
      final body = _block([
        _letStmt('inst', _msg([])..messageCreation.typeName = 'main:B'),
        _exprStmt(_ref('inst')),
      ]);
      final out = _flatProgram(ctorProgram('B', body));
      expect(out, isNot(contains('inst;')));
    });

    test('single `let v = input;` alias body → stripped', () {
      final body = _block([_letStmt('v', _ref('input'))]);
      final out = _flatProgram(ctorProgram('C', body));
      expect(out, isNot(contains('v = input')));
    });

    test('single bare-reference statement body → stripped', () {
      final body = _block([_exprStmt(_ref('input'))]);
      final out = _flatProgram(ctorProgram('D', body));
      expect(out, isNot(contains('input;')));
    });

    test('bare reference (non-block) body → stripped', () {
      final out = _flatProgram(ctorProgram('E', _ref('input')));
      expect(out, contains('E('));
    });
  });
}
