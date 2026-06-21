/// Unit tests for the compiler's constructor emission (`_buildConstructor` /
/// `_buildInitializerList` / `_buildParamList`) and the plain-data-class path
/// (`_buildSimpleClass`).
///
/// Constructor cosmetics (doc, const, factory, external, annotations, named,
/// redirecting `:this.x()`, super/field/assert initializers, super & this
/// formal parameters with defaults and required-named) are carried on the
/// member function's `metadata` struct; we build the Ball IR directly to pin
/// each branch.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:test/test.dart';

Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);

Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);

/// A `TypeDefinition main:<shortName>` with descriptor fields + metadata.
TypeDefinition _typeDef(
  String shortName, {
  Map<String, Object?>? metadata,
  List<({String name, String type})> fields = const [],
}) {
  final td = TypeDefinition()..name = 'main:$shortName';
  td.mergeFromProto3Json({
    'descriptor': {
      'name': shortName,
      if (fields.isNotEmpty)
        'field': [
          for (final f in fields)
            {'name': f.name, 'type': f.type, 'label': 'LABEL_OPTIONAL'},
        ],
    },
  });
  if (metadata != null) td.mergeFromProto3Json({'metadata': metadata});
  return td;
}

FunctionDefinition _member(
  String qualifiedName, {
  Map<String, Object?>? metadata,
  Expression? body,
  String outputType = '',
}) {
  final fn = FunctionDefinition()..name = qualifiedName;
  if (outputType.isNotEmpty) fn.outputType = outputType;
  if (body != null) fn.body = body;
  if (metadata != null) fn.mergeFromProto3Json({'metadata': metadata});
  return fn;
}

Program _program({
  List<TypeDefinition> typeDefs = const [],
  List<FunctionDefinition> members = const [],
}) {
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = (Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = 'print'
        ..input = (Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = ''
            ..fields.add(
              FieldValuePair()
                ..name = 'value'
                ..value = _strLit('x'),
            )))));
  final std = Module()
    ..name = 'std'
    ..functions.add(
      FunctionDefinition()
        ..name = 'print'
        ..isBase = true,
    );
  final main = Module()
    ..name = 'main'
    ..functions.addAll([...members, mainFn])
    ..typeDefs.addAll(typeDefs);
  return Program()
    ..name = 'constructors_emission_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([std, main]);
}

String _flat(Program p) =>
    DartCompiler(p, noFormat: true).compile().replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('simple data class (no metadata)', () {
    test('plain class with fields emits fields, ctor and toString', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Point',
              fields: [
                (name: 'x', type: 'TYPE_INT32'),
                (name: 'y', type: 'TYPE_INT32'),
              ],
            ),
          ],
        ),
      );
      expect(out, contains('class Point'));
      expect(out, contains('final int x'));
      expect(out, contains('final int y'));
      // Named-required `this.x` initializing formals.
      expect(out, contains('required this.x'));
      expect(out, contains('required this.y'));
      expect(out, contains("'Point(x: \$x, y: \$y)'"));
    });
  });

  group('constructor cosmetics', () {
    test('const + doc + annotations named constructor', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('V', metadata: {'doc': '/// v'}),
          ],
          members: [
            _member(
              'main:V.origin',
              metadata: {
                'kind': 'constructor',
                'doc': '/// the origin',
                'is_const': true,
                'annotations': ['pragma'],
              },
            ),
          ],
        ),
      );
      expect(out, contains('/// the origin'));
      expect(out, contains('@pragma'));
      expect(out, contains('const V.origin('));
    });

    test('factory constructor', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('F', metadata: {'doc': '/// f'}),
          ],
          members: [
            _member(
              'main:F.make',
              metadata: {'kind': 'constructor', 'is_factory': true},
              body: _ref('input'),
            ),
          ],
        ),
      );
      expect(out, contains('factory F.make('));
    });

    test('external constructor', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('E', metadata: {'doc': '/// e'}),
          ],
          members: [
            _member(
              'main:E.new',
              metadata: {'kind': 'constructor', 'is_external': true},
            ),
          ],
        ),
      );
      expect(out, contains('external E('));
    });

    test('redirecting constructor (redirects_to)', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('R', metadata: {'doc': '/// r'}),
          ],
          members: [
            _member(
              'main:R.alias',
              metadata: {'kind': 'constructor', 'redirects_to': 'R.primary'},
            ),
          ],
        ),
      );
      expect(out, contains('R.alias('));
      expect(out, contains('= R.primary'));
    });
  });

  group('initializer list', () {
    test('field, super, redirect-this and assert initializers', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('I', metadata: {'doc': '/// i'}),
          ],
          members: [
            _member(
              'main:I.new',
              metadata: {
                'kind': 'constructor',
                'initializers': [
                  {'kind': 'field', 'name': 'x', 'value': '0'},
                  {'kind': 'super', 'name': 'named', 'args': '(1)'},
                  {'kind': 'assert', 'condition': 'x >= 0', 'message': "'bad'"},
                ],
              },
              body: _ref('input'),
            ),
          ],
        ),
      );
      expect(out, contains('x = 0'));
      expect(out, contains('super.named(1)'));
      expect(out, contains("assert(x >= 0, 'bad')"));
    });

    test('bare super and bare this redirect + assert without message', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('J', metadata: {'doc': '/// j'}),
          ],
          members: [
            _member(
              'main:J.r',
              metadata: {
                'kind': 'constructor',
                'initializers': [
                  {'kind': 'super', 'args': '(2)'},
                  {'kind': 'redirect', 'args': '(3)'},
                  {'kind': 'assert', 'condition': 'true'},
                ],
              },
              body: _ref('input'),
            ),
          ],
        ),
      );
      expect(out, contains('super(2)'));
      expect(out, contains('this(3)'));
      expect(out, contains('assert(true)'));
    });

    test('redirect-this initializer with named target', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('N', metadata: {'doc': '/// n'}),
          ],
          members: [
            _member(
              'main:N.x',
              metadata: {
                'kind': 'constructor',
                'initializers': [
                  {'kind': 'redirect', 'name': 'other', 'args': '()'},
                ],
              },
              body: _ref('input'),
            ),
          ],
        ),
      );
      expect(out, contains('this.other()'));
    });
  });

  group('constructor parameters', () {
    test('this, super, named, required-named, optional, defaults', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('P', metadata: {'doc': '/// p'}),
          ],
          members: [
            _member(
              'main:P.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'a', 'is_this': true},
                  {'name': 'b', 'is_super': true},
                  {'name': 'c', 'type': 'int', 'is_required_named': true},
                  {
                    'name': 'd',
                    'type': 'int',
                    'is_optional': true,
                    'default': '5',
                  },
                  {'name': 'e', 'type': 'String', 'is_named': true},
                ],
              },
              body: _ref('input'),
            ),
          ],
        ),
      );
      expect(out, contains('this.a'));
      expect(out, contains('super.b'));
      expect(out, contains('required int c'));
      expect(out, contains('int d = 5'));
      expect(out, contains('String e'));
    });

    test('single-input convention rewrites to this.field formals', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'S',
              fields: [(name: 'name', type: 'TYPE_STRING')],
              metadata: {
                'doc': '/// s',
                'fields': [
                  {'name': 'name', 'type': 'String', 'is_final': true},
                ],
              },
            ),
          ],
          members: [
            _member(
              'main:S.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'input', 'type': 'String'},
                ],
              },
              body: _ref('input'),
            ),
          ],
        ),
      );
      expect(out, contains('S(this.name)'));
    });
  });
}
