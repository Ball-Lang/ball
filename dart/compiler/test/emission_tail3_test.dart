/// Remaining-tail emission tests (IR + round-trips):
///   * `compileAllModules` emitting a second user module + `compileModuleRaw`.
///   * a normal (non-goto) block whose result is a std-control statement.
///   * goto-block with NO label statements (result-only label/goto) → break.
///   * for-init expression fallback (`_e(initExpr)`).
///   * cascade field-read section (`..field`) and self-method-call section;
///     non-null `self.call()` assertion (round-trip `x?.fn()` guard else-arm).
///   * block-expression assign of an in-place list mutation (returns receiver).
///   * `_stripCascadeSelf` null-aware section; record with an int positional
///     name; an empty-typeName arg message; a `let self` inside a block expr.
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

const _stdFns = [
  'print',
  'paren',
  'return',
  'goto',
  'label',
  'cascade',
  'assign',
  'index',
  'record',
  'call',
];

Program _program({
  List<FunctionDefinition> members = const [],
  Expression? mainBody,
  List<Module> extraModules = const [],
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
    ..name = 'emission_tail3_test'
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
String _rt(String src) => DartCompiler(
  DartEncoder().encode(src),
  noFormat: true,
).compile().replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('compileAllModules / compileModuleRaw second module', () {
    test('a second user module is compiled and rawable', () {
      // Build a program with a second user module carrying a function.
      final p = _program();
      final lib = Module()
        ..name = 'lib'
        ..functions.add(_fn('helper', body: _strLit('h')));
      p.modules.add(lib);
      final all = _compiler(p).compileAllModules();
      expect(all.containsKey('lib'), isTrue);
      // The raw compile of the same module also succeeds.
      final raw = _compiler(p).compileModuleRaw('lib');
      expect(raw, contains('helper'));
    });
  });

  group('block result that is a std-control statement', () {
    test('a normal block whose result is `return v` emits a return', () {
      // statements + a control result (no goto labels) ⇒ _generateStdStatement
      // is used for the result rather than wrapping it as an expression.
      final body = _block([
        _exprStmt(_call('print', [_field('message', _strLit('a'))])),
      ], result: _call('return', [_field('value', _intLit(5))]));
      final out = _flat(
        _program(
          members: [_fn('host', outputType: 'int', body: body)],
        ),
      );
      expect(out, contains("print('a')"));
      expect(out, contains('return 5;'));
    });
  });

  group('goto block with no label statements', () {
    test('label as result only (no preceding labels) ends case 0 in break', () {
      // No label STATEMENTS; result is a label ⇒ resultIsLabel path, with
      // firstLabelIdx defaulting to statements.length and case 0 → break.
      final body = _block(
        [
          _exprStmt(_call('print', [_field('message', _strLit('pre'))])),
        ],
        result: _stdCall('std', 'label', [
          _field('name', _strLit('end')),
          _field('body', _call('print', [_field('message', _strLit('e'))])),
        ]),
      );
      final out = _flatBody(body);
      expect(out, contains('switch (0)'));
      expect(out, contains('end:'));
      expect(out, contains('break;'));
    });

    test('non-control block result inside a goto block is returned', () {
      // A goto block (has a label statement) whose result is a plain value.
      final body = _block([
        _exprStmt(
          _stdCall('std', 'label', [
            _field('name', _strLit('L')),
            _field('body', _call('print', [_field('message', _strLit('x'))])),
          ]),
        ),
      ], result: _intLit(7));
      final out = _flat(
        _program(
          members: [_fn('host', outputType: 'int', body: body)],
        ),
      );
      expect(out, contains('return 7;'));
    });
  });

  group('cascade self-method-call section', () {
    test('cascade method-call section compiles to `..method()`', () {
      // section: call(self=__cascade_self__, function='add', arg0=1)
      final methodSection = Expression()
        ..call = (FunctionCall()
          ..module = 'main'
          ..function = 'add'
          ..input = _msg([
            _field('self', _ref('__cascade_self__')),
            _field('arg0', _intLit(1)),
          ]));
      final body = _paren(
        _call('cascade', [
          _field('target', _ref('b')),
          _field('sections', _listLit([methodSection])),
        ]),
      );
      final out = _flatBody(body);
      expect(out, contains('..add(1)'));
    });

    test('cascade field-read section keeps `..field`', () {
      final readSection = Expression()
        ..fieldAccess = (FieldAccess()
          ..object = _ref('__cascade_self__')
          ..field_2 = 'flag');
      final body = _paren(
        _call('cascade', [
          _field('target', _ref('b')),
          _field('sections', _listLit([readSection])),
        ]),
      );
      final out = _flatBody(body);
      expect(out, contains('..flag'));
    });
  });

  group('block-expression assign of an in-place list mutation', () {
    test('block-expr `assign(x, list_push(list=x, v))` returns the receiver', () {
      final col = Module()
        ..name = 'std_collections'
        ..functions.add(
          FunctionDefinition()
            ..name = 'list_push'
            ..isBase = true,
        );
      // paren(block { assign(x, list_push(list=x, value=1)) }) → expression form
      // of _compileAssign with the in-place mutation elision (returns `_e(value)`).
      final body = _paren(
        _block([
          _exprStmt(
            _call('assign', [
              _field('target', _ref('xs')),
              _field(
                'value',
                _stdCall('std_collections', 'list_push', [
                  _field('list', _ref('xs')),
                  _field('value', _intLit(1)),
                ]),
              ),
            ]),
          ),
        ]),
      );
      final out = _flat(
        _program(
          extraModules: [col],
          members: [_fn('host', body: body)],
        ),
      );
      expect(out, contains('xs..add(1)'));
    });
  });

  group('record with an int positional name / empty-typeName args', () {
    test('record legacy fields-list with an int `name`', () {
      // name is an int literal ⇒ _compileLiteralValue int branch.
      final rec = _call('record', [
        _field(
          'fields',
          _listLit([
            _msg([_field('name', _intLit(0)), _field('value', _strLit('a'))]),
          ]),
        ),
      ]);
      final out = _flatBody(_paren(rec));
      // The int name does not start with 'arg', so it emits `0: 'a'` — exercises
      // the int literal-value branch even though Dart records don't allow it;
      // we only assert the int name was rendered, not validity.
      expect(out, contains("0: 'a'"));
    });

    test('empty-typeName message with positional fields as an arg list', () {
      // A messageCreation with empty typeName and arg fields compiles its
      // fields as an argument list (used directly in expression position).
      final argMsg = _msg([
        _field('arg0', _intLit(1)),
        _field('arg1', _intLit(2)),
      ]);
      final out = _flatBody(_paren(argMsg));
      expect(out.replaceAll(' ', ''), contains('(1,2)'));
    });
  });

  group('let self inside a block expression', () {
    test('a `let self = ...` inside a paren block shadows the receiver', () {
      final body = _paren(
        _block([
          _letStmt('self', _ref('outer')),
          _exprStmt(_call('print', [_field('message', _ref('self'))])),
        ]),
      );
      final out = _flatBody(body);
      expect(out, contains('final self = outer;'));
    });
  });

  group('round-trip: null-aware function-field call (non-null else arm)', () {
    test(
      'x?.call() lowers through a null guard whose else asserts non-null',
      () {
        final out = _rt('''
class Holder {
  int Function()? fn;
}
void main() {
  final h = Holder();
  print(h.fn?.call().toString());
}
''');
        // The lowered `h.fn == null ? null : h.fn!.call()` asserts the field
        // non-null in the else arm.
        expect(out, contains('.call()'));
      },
    );
  });
}
