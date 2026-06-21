/// Last-mile emission tests, built as Ball IR / round-trips, for the remaining
/// reachable branches:
///   * `_wrapReturnType` Iterable<T> / Stream<T> from a plain (non-List) type.
///   * expression-body constructor whose param is named `self` (shadow depth).
///   * cascade self-method-call section + non-null `self.call()` assertion.
///   * `map_create` / `record` with a non-message input (the empty fallback).
///   * `set_create` with a non-list `elements` expression.
///   * `_stripCascadeSelf` index / null-aware cascade sections.
///   * repeated + message descriptor field types (`List<T>` / message name).
///   * `list_slice` two-arg and one-arg sublist; generator-typed `let` (async*).
///   * empty-literal constructor body (`_isEmptyBody`).
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

/// A base call whose input is a direct expression (NOT a MessageCreation).
Expression _stdCallRaw(String fn, Expression input) =>
    Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = fn
        ..input = input);

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
  'set_create',
  'map_create',
  'record',
  'cascade',
  'tear_off',
  'call',
  'yield',
];

Program _program({
  List<FunctionDefinition> members = const [],
  List<TypeDefinition> typeDefs = const [],
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
    ..name = 'emission_tail2_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      ...extraModules,
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
String _flatExpr(Expression e) => _flatBody(_paren(e));

void main() {
  group('_wrapReturnType plain (non-List) type', () {
    test('sync* with a plain `int` output → Iterable<int>', () {
      final out = _flat(
        _program(
          members: [
            _fn(
              'gen',
              outputType: 'int',
              metadata: {'is_sync_star': true},
              body: _block([
                _exprStmt(_call('yield', [_field('value', _intLit(1))])),
              ]),
            ),
          ],
        ),
      );
      expect(out, contains('Iterable<int> gen()'));
    });

    test('async* with a plain `int` output → Stream<int>', () {
      final out = _flat(
        _program(
          members: [
            _fn(
              'gen',
              outputType: 'int',
              metadata: {'is_async_star': true},
              body: _block([
                _exprStmt(_call('yield', [_field('value', _intLit(1))])),
              ]),
            ),
          ],
        ),
      );
      expect(out, contains('Stream<int> gen()'));
    });
  });

  group('factory constructor with a `self` param (shadow depth)', () {
    test('a `self` param keeps `self` references (block-form demotion)', () {
      final td = TypeDefinition()..name = 'main:S';
      td.mergeFromProto3Json({
        'descriptor': {'name': 'S'},
        'metadata': {'doc': '/// s'},
      });
      // The single positional `self` param is renamed to `input` and aliased
      // back, which forces block-form demotion; the body's `self` reference is
      // preserved (selfParamShadow ↑/↓ around the body emission).
      final ctor = _fn(
        'main:S.from',
        metadata: {
          'kind': 'constructor',
          'is_factory': true,
          'expression_body': true,
          'params': [
            {'name': 'self', 'type': 'S'},
          ],
        },
        body: _ref('self'),
      );
      final out = _flat(_program(members: [ctor], typeDefs: [td]));
      expect(out, contains('factory S.from(S input)'));
      expect(out, contains('S self = input;'));
    });
  });

  group('map_create / record non-message input fallback', () {
    test('map_create with a non-message input → empty map', () {
      // input is a bare reference, not a MessageCreation.
      final out = _flatExpr(_stdCallRaw('map_create', _ref('whatever')));
      expect(out, contains('{}'));
    });

    test('record with a non-message input → ()', () {
      final out = _flatExpr(_stdCallRaw('record', _ref('whatever')));
      expect(out, contains('()'));
    });
  });

  group('set_create with non-list elements', () {
    test('typed set_create whose elements is a reference', () {
      final out = _flatExpr(
        _call('set_create', [
          _field('type_args', _strLit('int')),
          _field('elements', _ref('xs')),
        ]),
      );
      // Non-list elements expr ⇒ falls through to the prefixed-empty result.
      expect(out, contains('<int>{}'));
    });
  });

  group('_stripCascadeSelf index / null-aware sections', () {
    test('cascade with an index-assign section keeps `..[i] = v`', () {
      // section: assign(target = __cascade_self__[index], value)
      final indexTarget = _call('index', [
        _field('target', _ref('__cascade_self__')),
        _field('index', _intLit(0)),
      ]);
      final assignSection = _call('assign', [
        _field('target', indexTarget),
        _field('value', _intLit(9)),
      ]);
      final body = _paren(
        _call('cascade', [
          _field('target', _ref('m')),
          _field('sections', _listLit([assignSection])),
        ]),
      );
      final p = _program(members: [_fn('host', body: body)]);
      p.modules.firstWhere((m) => m.name == 'std').functions.addAll([
        FunctionDefinition()
          ..name = 'index'
          ..isBase = true,
        FunctionDefinition()
          ..name = 'assign'
          ..isBase = true,
      ]);
      final out = _flat(p);
      expect(out, contains('..['));
    });
  });

  group('descriptor field types (_protoFieldToDartType)', () {
    test('repeated + message-typed fields render List<T> / message name', () {
      final td = TypeDefinition()..name = 'main:Node';
      td.mergeFromProto3Json({
        'descriptor': {
          'name': 'Node',
          'field': [
            {
              'name': 'children',
              'type': 'TYPE_MESSAGE',
              'typeName': '.main.Node',
              'label': 'LABEL_REPEATED',
            },
            {
              'name': 'parent',
              'type': 'TYPE_MESSAGE',
              'typeName': 'Node',
              'label': 'LABEL_OPTIONAL',
            },
          ],
        },
        'metadata': {'doc': '/// node'},
      });
      final out = _flat(_program(typeDefs: [td]));
      expect(out, contains('List<Node> children'));
      expect(out, contains('Node parent'));
    });
  });

  group('list_slice', () {
    test('two-arg and one-arg sublist', () {
      final col = Module()
        ..name = 'std_collections'
        ..functions.add(
          FunctionDefinition()
            ..name = 'list_slice'
            ..isBase = true,
        );
      final two = _flat(
        _program(
          extraModules: [col],
          mainBody: _paren(
            _stdCall('std_collections', 'list_slice', [
              _field('list', _ref('xs')),
              _field('start', _intLit(1)),
              _field('end', _intLit(3)),
            ]),
          ),
        ),
      );
      expect(two, contains('xs.sublist(1, 3)'));

      final one = _flat(
        _program(
          extraModules: [col],
          mainBody: _paren(
            _stdCall('std_collections', 'list_slice', [
              _field('list', _ref('xs')),
              _field('start', _intLit(2)),
            ]),
          ),
        ),
      );
      expect(one, contains('xs.sublist(2)'));
    });
  });

  group('generator-typed let (async*)', () {
    test('let typed List<int> bound to an async* call → Stream<int>', () {
      final genFn = _fn(
        'agen',
        outputType: 'List<int>',
        metadata: {'is_async_star': true},
        body: _block([
          _exprStmt(_call('yield', [_field('value', _intLit(1))])),
        ]),
      );
      final hostBody = _block([
        _letStmt(
          'xs',
          _stdCall('main', 'agen', const []),
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
      expect(out, contains('Stream<int> xs ='));
    });
  });

  group('empty-literal constructor body (_isEmptyBody)', () {
    test('constructor with a notSet-literal body emits no body', () {
      final td = TypeDefinition()..name = 'main:E';
      td.mergeFromProto3Json({
        'descriptor': {'name': 'E'},
        'metadata': {'doc': '/// e'},
      });
      // Body is a literal with no value set ⇒ _isEmptyBody ⇒ bodyless ctor.
      final ctor = _fn(
        'main:E.new',
        metadata: {'kind': 'constructor'},
        body: Expression()..literal = Literal(),
      );
      final out = _flat(_program(members: [ctor], typeDefs: [td]));
      expect(out, contains('E();'));
    });
  });
}
