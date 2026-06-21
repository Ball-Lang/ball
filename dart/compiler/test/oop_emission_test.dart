/// Unit tests for the compiler's metadata-driven OOP / type-declaration
/// emission: class modifiers (sealed/base/interface/final/mixin-class), doc
/// comments and annotations on classes/mixins/enums/extensions/extension-types,
/// mixin `on`/`base`/interfaces, enum docs/annotations/fields/value-args,
/// abstract fields (→ getter/setter), static fields, constructor doc/factory/
/// const/external/annotations, redirecting + super/assert initializers, super &
/// this constructor params, and type aliases with type parameters + docs.
///
/// The Dart encoder reaches many of these only through specific source shapes;
/// building the Ball IR `TypeDefinition`s directly (with their cosmetic
/// `metadata` struct populated via proto3-JSON) pins every branch
/// deterministically.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/gen/google/protobuf/descriptor.pb.dart' as google;
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

// ── IR builders ───────────────────────────────────────────────────

Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);

/// A `TypeDefinition` named `main:<shortName>` (the encoder's module-qualified
/// convention, so it matches member classKeys). Its descriptor carries [fields]
/// (name→proto type) and its cosmetic [metadata] is supplied as proto3-JSON.
TypeDefinition _typeDef(
  String shortName, {
  Map<String, Object?>? metadata,
  List<({String name, String type})> fields = const [],
  bool withDescriptor = true,
}) {
  final td = TypeDefinition()..name = 'main:$shortName';
  if (withDescriptor) {
    final json = <String, Object?>{
      'name': shortName,
      if (fields.isNotEmpty)
        'field': [
          for (final f in fields)
            {'name': f.name, 'type': f.type, 'label': 'LABEL_OPTIONAL'},
        ],
    };
    td.mergeFromProto3Json({'descriptor': json});
  }
  if (metadata != null) td.mergeFromProto3Json({'metadata': metadata});
  return td;
}

/// A class-member `FunctionDefinition` with name `main:Class.member`.
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

/// Build a program with the given declarations in module `main`. The entry
/// function `main` has a trivial body. [enums] and [typeAliases] are added
/// directly to the module.
Program _program({
  List<TypeDefinition> typeDefs = const [],
  List<FunctionDefinition> members = const [],
  List<google.EnumDescriptorProto> enums = const [],
  List<TypeAlias> typeAliases = const [],
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
                ..value = (Expression()
                  ..literal = (Literal()..stringValue = 'x')),
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
    ..typeDefs.addAll(typeDefs)
    ..enums.addAll(enums)
    ..typeAliases.addAll(typeAliases);
  return Program()
    ..name = 'oop_emission_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([std, main]);
}

String _compile(Program p) => DartCompiler(p, noFormat: true).compile();
String _flat(Program p) => _compile(p).replaceAll(RegExp(r'\s+'), ' ');

/// A google.protobuf.EnumDescriptorProto named `main:<shortName>` (so it lines
/// up with the matching `TypeDefinition` and member classKeys).
google.EnumDescriptorProto _enum(String shortName, List<String> values) {
  final e = google.EnumDescriptorProto();
  e.mergeFromProto3Json({
    'name': 'main:$shortName',
    'value': [
      for (var i = 0; i < values.length; i++) {'name': values[i], 'number': i},
    ],
  });
  return e;
}

void main() {
  group('class modifiers', () {
    test('sealed class', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('Shape', metadata: {'is_sealed': true}),
          ],
        ),
      );
      expect(out, contains('sealed class Shape'));
    });

    test('base class', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('Base', metadata: {'is_base': true}),
          ],
        ),
      );
      expect(out, contains('base class Base'));
    });

    test('interface class', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('Inter', metadata: {'is_interface': true}),
          ],
        ),
      );
      expect(out, contains('interface class Inter'));
    });

    test('final class', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('Fin', metadata: {'is_final': true}),
          ],
        ),
      );
      expect(out, contains('final class Fin'));
    });

    test('mixin class', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('MC', metadata: {'is_mixin_class': true}),
          ],
        ),
      );
      expect(out, contains('mixin class MC'));
    });

    test('abstract class with superclass, mixins and interfaces', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Dog',
              metadata: {
                'is_abstract': true,
                'superclass': 'Animal',
                'mixins': ['Walker', 'Runner'],
                'interfaces': ['Pet'],
              },
            ),
          ],
        ),
      );
      expect(out, contains('abstract class Dog extends Animal'));
      expect(out, contains('Walker'));
      expect(out, contains('Runner'));
      expect(out, contains('implements Pet'));
    });

    test('class doc comment and annotations', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Widget',
              metadata: {
                'doc': '/// A widget.',
                'annotations': ['immutable'],
              },
            ),
          ],
        ),
      );
      expect(out, contains('/// A widget.'));
      expect(out, contains('@immutable'));
    });
  });

  group('class fields', () {
    test('mutable, final, const, and late fields via metadata', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Box',
              fields: [
                (name: 'a', type: 'TYPE_INT32'),
                (name: 'b', type: 'TYPE_INT32'),
                (name: 'c', type: 'TYPE_INT32'),
                (name: 'd', type: 'TYPE_STRING'),
              ],
              metadata: {
                'doc': '/// box',
                'fields': [
                  {'name': 'a', 'type': 'int', 'is_final': false},
                  {'name': 'b', 'type': 'int', 'is_final': true},
                  {
                    'name': 'c',
                    'type': 'int',
                    'is_const': true,
                    'initializer': '0',
                  },
                  {'name': 'd', 'type': 'String?', 'is_final': false},
                ],
              },
            ),
          ],
        ),
      );
      expect(out, contains('int a'));
      expect(out, contains('final int b'));
      expect(out, contains('const int c = 0'));
      // Nullable mutable field: not late.
      expect(out, contains('String? d'));
    });

    test('non-nullable typed field without initializer becomes late', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'L',
              fields: [(name: 'x', type: 'TYPE_INT32')],
              // A `doc` forces the decorated (non-simple) class path so the
              // metadata-driven field emission (and its `late` inference) runs.
              metadata: {
                'doc': '/// l',
                'fields': [
                  {'name': 'x', 'type': 'int', 'is_final': false},
                ],
              },
            ),
          ],
        ),
      );
      expect(out, contains('late int x'));
    });

    test('abstract field emits abstract getter and setter', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'A',
              fields: [(name: 'v', type: 'TYPE_INT32')],
              metadata: {
                'is_abstract': true,
                'fields': [
                  {
                    'name': 'v',
                    'type': 'int',
                    'is_abstract': true,
                    'is_final': false,
                  },
                ],
              },
            ),
          ],
        ),
      );
      expect(out, contains('int get v;'));
      expect(out, contains('set v(int value)'));
    });

    test('abstract final field emits getter only (no setter)', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'A',
              fields: [(name: 'v', type: 'TYPE_INT32')],
              metadata: {
                'is_abstract': true,
                'fields': [
                  {
                    'name': 'v',
                    'type': 'int',
                    'is_abstract': true,
                    'is_final': true,
                  },
                ],
              },
            ),
          ],
        ),
      );
      expect(out, contains('int get v;'));
      expect(out, isNot(contains('set v(')));
    });
  });

  group('static members', () {
    test('static field with const value', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('M', metadata: {'doc': '/// m'}),
          ],
          members: [
            _member(
              'main:M.pi',
              outputType: 'double',
              metadata: {'kind': 'static_field', 'is_const': true},
              body: Expression()..literal = (Literal()..doubleValue = 3.14),
            ),
          ],
        ),
      );
      expect(out, contains('static const double pi = 3.14'));
    });
  });

  group('methods', () {
    test('getter, setter, static, operator, generic, doc, override', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef('K', metadata: {'doc': '/// k'}),
          ],
          members: [
            _member(
              'main:K.doubled',
              outputType: 'int',
              metadata: {'kind': 'method', 'is_getter': true, 'doc': '/// g'},
              body: _ref('x'),
            ),
            _member(
              'main:K.value',
              metadata: {'kind': 'method', 'is_setter': true},
              body: _ref('x'),
            ),
            _member(
              'main:K.plus',
              outputType: 'int',
              metadata: {
                'kind': 'method',
                'is_operator': true,
                'operator': '+',
              },
              body: _ref('x'),
            ),
            _member(
              'main:K.id',
              metadata: {
                'kind': 'method',
                'type_params': ['T'],
                'is_static': true,
              },
              body: _ref('x'),
            ),
          ],
        ),
      );
      expect(out, contains('/// g'));
      expect(out, contains('get doubled'));
      expect(out, contains('set value'));
      expect(out, contains('operator +'));
      expect(out, contains('static'));
      expect(out, contains('id<T>'));
    });
  });

  group('mixins', () {
    test('mixin with on, base, interfaces, doc, annotations, fields', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Walker',
              fields: [(name: 'speed', type: 'TYPE_INT32')],
              metadata: {
                'kind': 'mixin',
                'doc': '/// walks',
                'annotations': ['sealed'],
                'is_base': true,
                'on': ['Animal'],
                'interfaces': ['Movable'],
              },
            ),
          ],
          members: [
            _member(
              'main:Walker.walk',
              outputType: 'String',
              metadata: {'kind': 'method'},
              body: _ref('x'),
            ),
          ],
        ),
      );
      expect(out, contains('base mixin Walker'));
      expect(out, contains('on Animal'));
      expect(out, contains('implements Movable'));
      expect(out, contains('/// walks'));
      expect(out, contains('@sealed'));
      expect(out, contains('final int speed'));
      expect(out, contains('walk'));
    });
  });

  group('enums', () {
    test('enum with doc, interfaces, mixins, value docs/args, fields', () {
      final out = _flat(
        _program(
          enums: [
            _enum('Planet', ['earth', 'mars']),
          ],
          typeDefs: [
            _typeDef(
              'Planet',
              withDescriptor: false,
              metadata: {
                'kind': 'enum',
                'doc': '/// planets',
                'interfaces': ['Comparable'],
                'mixins': ['Mass'],
                'values': [
                  {'name': 'earth', 'doc': '/// home', 'args': "(9.8)"},
                  {'name': 'mars', 'args': '3.7'},
                ],
                'fields': [
                  {'name': 'gravity', 'type': 'double', 'is_final': true},
                  {'name': 'count', 'type': 'int', 'is_static': true},
                ],
              },
            ),
          ],
          members: [
            _member('main:Planet.new', metadata: {'kind': 'constructor'}),
            _member(
              'main:Planet.weight',
              outputType: 'double',
              metadata: {'kind': 'method'},
              body: _ref('x'),
            ),
          ],
        ),
      );
      expect(out, contains('enum Planet'));
      expect(out, contains('/// planets'));
      expect(out, contains('implements Comparable'));
      expect(out, contains('with Mass'));
      expect(out, contains('/// home'));
      expect(out, contains('earth(9.8)'));
      expect(out, contains('mars(3.7)'));
      expect(out, contains('final double gravity'));
      expect(out, contains('static int count'));
      expect(out, contains('weight'));
    });
  });

  group('extensions', () {
    test('named extension with doc + annotations on a type', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'IntX',
              withDescriptor: false,
              metadata: {
                'kind': 'extension',
                'on': 'int',
                'doc': '/// ext',
                'annotations': ['visibleForTesting'],
              },
            ),
          ],
          members: [
            _member(
              'main:IntX.doubled',
              outputType: 'int',
              metadata: {'kind': 'method', 'is_getter': true},
              body: _ref('x'),
            ),
          ],
        ),
      );
      expect(out, contains('extension IntX on int'));
      expect(out, contains('/// ext'));
      expect(out, contains('@visibleForTesting'));
    });
  });

  group('extension types', () {
    test('extension type with doc, annotations, interfaces, static + ctor', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Meters',
              withDescriptor: false,
              metadata: {
                'kind': 'extension_type',
                'rep_type': 'double',
                'rep_field': 'value',
                'is_const': true,
                'doc': '/// meters',
                'annotations': ['immutable'],
                'interfaces': ['Comparable'],
              },
            ),
          ],
          members: [
            _member('main:Meters.named', metadata: {'kind': 'constructor'}),
            _member(
              'main:Meters.K',
              outputType: 'int',
              metadata: {'kind': 'static_field', 'is_const': true},
              body: Expression()..literal = (Literal()..intValue = Int64(1000)),
            ),
            _member(
              'main:Meters.feet',
              outputType: 'double',
              metadata: {'kind': 'method', 'is_getter': true},
              body: _ref('x'),
            ),
          ],
        ),
      );
      expect(out, contains('extension type const Meters'));
      expect(out, contains('/// meters'));
      expect(out, contains('@immutable'));
      expect(out, contains('implements Comparable'));
      expect(out, contains('feet'));
    });
  });

  group('type aliases', () {
    test('typedef with type parameters and doc', () {
      final ta = TypeAlias()
        ..name = 'IntList'
        ..targetType = 'List<int>';
      ta.mergeFromProto3Json({
        'typeParams': [
          {'name': 'T'},
        ],
        'metadata': {'doc': '/// alias'},
      });
      final out = _compile(_program(typeAliases: [ta]));
      expect(out, contains('/// alias'));
      expect(out, contains('typedef IntList<T> = List<int>;'));
    });

    test('plain typedef without metadata', () {
      final ta = TypeAlias()
        ..name = 'Json'
        ..targetType = 'Map<String, dynamic>';
      final out = _compile(_program(typeAliases: [ta]));
      expect(out, contains('typedef Json = Map<String, dynamic>;'));
    });
  });
}
