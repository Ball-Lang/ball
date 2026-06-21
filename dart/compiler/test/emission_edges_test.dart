/// Unit tests for the long tail of compiler emission edges, built as Ball IR
/// (and a few round-trips) so each branch is hit deterministically:
///   * `compile()` / `compileModule()` / `compileModuleRaw()` on bad names
///     (the `orElse` StateError guards) and `compileAllModules` skips.
///   * `_wrapReturnType` Stream<T> (async* List<T>) rewrite.
///   * `self`-param / `let self` shadow depth in methods & lambdas.
///   * std.if missing operands / case-pattern; for-init expression fallback.
///   * switch-expr subject-less and the list-mutation `addAll` assign elision.
///   * cascade `__cascade_self__` field/method targets; `notSet` expression.
///   * generator-typed `let` (sync*/async* call) type rewrite.
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
  'if',
  'for',
  'switch_expr',
  'assign',
  'list_concat',
  'yield',
];

/// A program with [members] (added to module `main`) and a trivial entry.
Program _program({
  List<FunctionDefinition> members = const [],
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
  // std_collections for list mutation tests.
  final stdCol = Module()
    ..name = 'std_collections'
    ..functions.add(
      FunctionDefinition()
        ..name = 'list_push'
        ..isBase = true,
    );
  return Program()
    ..name = 'emission_edges_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      stdCol,
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

DartCompiler _compiler(Program p) => DartCompiler(p, noFormat: true);
String _flat(Program p) =>
    _compiler(p).compile().replaceAll(RegExp(r'\s+'), ' ');
String _flatBody(Expression body) =>
    _flat(_program(members: [_fn('host', body: body)]));

void main() {
  group('entry / module lookup guards', () {
    test('compile() throws when entry module is missing', () {
      final p = _program()..entryModule = 'nope';
      expect(_compiler(p).compile, throwsStateError);
    });

    test('compile() throws when entry function is missing', () {
      final p = _program()..entryFunction = 'nope';
      expect(_compiler(p).compile, throwsStateError);
    });

    test('compileModule throws on an unknown module', () {
      expect(
        () => _compiler(_program()).compileModule('ghost'),
        throwsStateError,
      );
    });

    test('compileModuleRaw throws on an unknown module', () {
      expect(
        () => _compiler(_program()).compileModuleRaw('ghost'),
        throwsStateError,
      );
    });

    test('compileAllModules skips base/empty modules', () {
      final out = _compiler(_program()).compileAllModules();
      // The `main` module is emitted; pure-base std modules are skipped.
      expect(out.containsKey('main'), isTrue);
      expect(out.containsKey('std'), isFalse);
      expect(out.containsKey('std_collections'), isFalse);
    });
  });

  group('async* return-type rewrite (_wrapReturnType)', () {
    test('async* with List<T> output → Stream<T>', () {
      final out = _flat(
        _program(
          members: [
            _fn(
              'gen',
              outputType: 'List<int>',
              metadata: {'is_async_star': true},
              body: _block([
                _exprStmt(_call('yield', [_field('value', _intLit(1))])),
              ]),
            ),
          ],
        ),
      );
      expect(out, contains('Stream<int> gen()'));
      expect(out, contains('async*'));
    });
  });

  group('self shadow depth (let self / self param)', () {
    test('a method with a `self` parameter keeps `self` references', () {
      final method = _fn(
        'main:K.run',
        metadata: {
          'kind': 'method',
          'params': [
            {'name': 'self', 'type': 'Object'},
          ],
        },
        body: _ref('self'),
      );
      final td = TypeDefinition()..name = 'main:K';
      td.mergeFromProto3Json({
        'descriptor': {'name': 'K'},
        'metadata': {'doc': '/// k'},
      });
      final p = _program(members: [method]);
      p.modules.firstWhere((m) => m.name == 'main').typeDefs.add(td);
      final out = _flat(p);
      // The single positional `self` param is renamed to `input` and aliased
      // back (`Object self = input;`); the body's `self` reference stays `self`
      // rather than being rewritten to the implicit `this` receiver.
      expect(out, contains('Object self = input;'));
      expect(out, contains('self;'));
    });

    test('a `let self = ...` binding inside a function body', () {
      final body = _block([
        _letStmt('self', _ref('outer')),
        _exprStmt(_call('print', [_field('message', _ref('self'))])),
      ]);
      final out = _flatBody(body);
      expect(out, contains('final self = outer'));
    });
  });

  group('std.if edge cases', () {
    test('std.if missing condition/then emits an ERROR comment', () {
      final body = _block([
        _exprStmt(_call('if', [_field('then', _intLit(1))])),
      ]);
      final out = _flatBody(body);
      expect(out, contains('// ERROR: std.if missing condition or then'));
    });

    test('std.if with a case_pattern emits `if (x case P)`', () {
      final body = _block([
        _exprStmt(
          _call('if', [
            _field('condition', _ref('x')),
            _field('case_pattern', _strLit('int n')),
            _field('then', _call('print', [_field('message', _ref('n'))])),
          ]),
        ),
      ]);
      final out = _flatBody(body);
      expect(out, contains('if (x case int n) {'));
    });
  });

  group('switch statement subjectless', () {
    test('std.switch with no subject emits `switch (null)`', () {
      // The switch STATEMENT lowering defaults a missing subject to `null`.
      final body = _block([
        _exprStmt(
          _stdCall('std', 'switch', [_field('cases', _listLit(const []))]),
        ),
      ]);
      final p = _program(members: [_fn('host', body: body)]);
      p.modules
          .firstWhere((m) => m.name == 'std')
          .functions
          .add(
            FunctionDefinition()
              ..name = 'switch'
              ..isBase = true,
          );
      final out = _flat(p);
      expect(out, contains('switch (null)'));
    });
  });

  group('list mutation assign elision', () {
    test('assign(x, list_push(list=x, value=v)) → x..add(v)', () {
      final body = _block([
        _exprStmt(
          _call('assign', [
            _field('target', _ref('xs')),
            _field(
              'value',
              _stdCall('std_collections', 'list_push', [
                _field('list', _ref('xs')),
                _field('value', _intLit(9)),
              ]),
            ),
          ]),
        ),
      ]);
      final out = _flatBody(body);
      // Re-binding elided: only the in-place mutation remains.
      expect(out, contains('xs..add(9)'));
      expect(out, isNot(contains('xs = xs')));
    });
  });

  group('cascade target / notSet expression', () {
    test('cascade field-assign section keeps `..field = v`', () {
      // cascade(target=b, sections=[ assign(target=__cascade_self__.f, value=1) ])
      final assignSection = _call('assign', [
        _field(
          'target',
          Expression()
            ..fieldAccess = (FieldAccess()
              ..object = _ref('__cascade_self__')
              ..field_2 = 'f'),
        ),
        _field('value', _intLit(1)),
      ]);
      final body = _paren(
        _call('cascade', [
          _field('target', _ref('b')),
          _field('sections', _listLit([assignSection])),
        ]),
      );
      // `cascade` must be registered as base.
      final p = _program(members: [_fn('host', body: body)]);
      p.modules
          .firstWhere((m) => m.name == 'std')
          .functions
          .add(
            FunctionDefinition()
              ..name = 'cascade'
              ..isBase = true,
          );
      final out = _flat(p);
      expect(out, contains('..f = 1'));
    });

    test('notSet expression compiles to the unknown-expression marker', () {
      // A let bound to an Expression with no oneof set.
      final body = _block([_letStmt('y', Expression())]);
      final out = _flatBody(body);
      expect(out, contains('/* unknown expression */'));
    });
  });

  group('generator-typed let (type rewrite)', () {
    test('let typed List<int> bound to a sync* call → Iterable<int>', () {
      // A user sync* function `gen` returning List<int>; a `let xs : List<int> =
      // gen()` rewrites the declared type to Iterable<int>.
      final genFn = _fn(
        'gen',
        outputType: 'List<int>',
        metadata: {'is_sync_star': true},
        body: _block([
          _exprStmt(_call('yield', [_field('value', _intLit(1))])),
        ]),
      );
      final hostBody = _block([
        _letStmt(
          'xs',
          _stdCall('main', 'gen', const []),
          meta: {'type': 'List<int>', 'keyword': 'var'},
        ),
      ]);
      final out = _flat(
        _program(
          members: [
            genFn,
            _fn('host', body: hostBody),
          ],
        ),
      );
      expect(out, contains('Iterable<int> xs ='));
    });
  });
}
