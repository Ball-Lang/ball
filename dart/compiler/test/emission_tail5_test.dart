/// Last reachable-tail emission tests (IR):
///   * an empty non-entry module is skipped by `compileAllModules`.
///   * a generic type via the proto `type_params` field (`_metaFromTd` lift).
///   * an abstract field on an extension type → abstract getter/setter.
///   * a cascade self-method-call section with no remaining args (`..m()`).
///   * `_compileLiteralValue` for a non-literal record name (the `_e` branch).
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_resolver/ball_resolver.dart';
import 'package:test/test.dart';

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

Expression _call(String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = fn
        ..input = _msg(fields));

Expression _paren(Expression e) => _call('paren', [_field('value', e)]);

const _stdFns = ['print', 'paren', 'cascade', 'record'];

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
    ..name = 'emission_tail5_test'
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

DartCompiler _compiler(Program p) => DartCompiler(p, noFormat: true);
String _flat(Program p) =>
    _compiler(p).compile().replaceAll(RegExp(r'\s+'), ' ');
String _flatBody(Expression body) =>
    _flat(_program(members: [_fn('host', body: body)]));

void main() {
  group('resolveImports static helper', () {
    test('a program with no imports resolves to the same modules', () async {
      final p = _program();
      final resolver = ModuleResolver();
      final resolved = await DartCompiler.resolveImports(p, resolver);
      // No ModuleImports ⇒ the resolved program carries the same modules.
      expect(
        resolved.modules.map((m) => m.name).toSet(),
        equals(p.modules.map((m) => m.name).toSet()),
      );
      // The resolved program is still compilable.
      expect(
        DartCompiler(resolved, noFormat: true).compile(),
        contains('void main()'),
      );
    });
  });

  group('compileAllModules skips an empty non-entry module', () {
    test('a declaration-free non-entry module is not emitted', () {
      final p = _program();
      p.modules.add(Module()..name = 'empty_stub');
      final all = _compiler(p).compileAllModules();
      expect(all.containsKey('empty_stub'), isFalse);
      expect(all.containsKey('main'), isTrue);
    });
  });

  group('generic type via proto type_params', () {
    test('typeParams on the TypeDefinition (not metadata) become <T>', () {
      final td = TypeDefinition()..name = 'main:Box';
      td.mergeFromProto3Json({
        'descriptor': {'name': 'Box'},
        // Generic param carried on the proto field, not in metadata, so
        // _metaFromTd lifts it into meta['type_params'].
        'typeParams': [
          {'name': 'T'},
        ],
        'metadata': {'doc': '/// box'},
      });
      final out = _flat(_program(typeDefs: [td]));
      expect(out, contains('class Box<T>'));
    });
  });

  group('extension type abstract field', () {
    test('abstract field on an extension type → abstract getter/setter', () {
      final td = TypeDefinition()..name = 'main:Et';
      td.mergeFromProto3Json({
        'descriptor': {
          'name': 'Et',
          'field': [
            {'name': 'v', 'type': 'TYPE_INT32', 'label': 'LABEL_OPTIONAL'},
          ],
        },
        'metadata': {
          'kind': 'extension_type',
          'rep_type': 'int',
          'rep_field': 'value',
          'fields': [
            {
              'name': 'v',
              'type': 'int',
              'is_abstract': true,
              'is_final': false,
            },
          ],
        },
      });
      final out = _flat(_program(typeDefs: [td]));
      expect(out, contains('int get v;'));
      expect(out, contains('set v(int value)'));
    });
  });

  group('cascade self-method with no remaining args', () {
    test('cascade `..method()` with no positional args', () {
      final methodSection = Expression()
        ..call = (FunctionCall()
          ..module = 'main'
          ..function = 'clear'
          ..input = _msg([_field('self', _ref('__cascade_self__'))]));
      final body = _paren(
        _call('cascade', [
          _field('target', _ref('b')),
          _field('sections', _listLit([methodSection])),
        ]),
      );
      final out = _flatBody(body);
      expect(out, contains('..clear()'));
    });
  });

  group('_compileLiteralValue non-literal record name', () {
    test('record legacy fields-list with a reference `name` falls to _e', () {
      final rec = _call('record', [
        _field(
          'fields',
          _listLit([
            _msg([
              _field('name', _ref('dynKey')),
              _field('value', _strLit('a')),
            ]),
          ]),
        ),
      ]);
      final out = _flatBody(_paren(rec));
      expect(out, contains("dynKey: 'a'"));
    });
  });
}
