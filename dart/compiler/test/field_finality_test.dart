/// Instance-field finality: when does the Dart compiler have to emit `late`?
///
/// A non-nullable instance field with no inline initializer needs `late` only
/// when nothing PROVES it is assigned by the time construction finishes. The
/// compiler used to infer that from the field declaration alone, so it marked
/// every such field `late` — including fields the constructor's own initializer
/// list (or a required initializing formal) definitely assigns.
///
/// That over-approximation is not cosmetic. A plain `final` field contributes a
/// getter and nothing else; a `late final` field is assignable after
/// construction, so it also contributes an implicit SETTER. Next to a
/// user-declared setter of the same name — `collection`'s `ListSlice` is the
/// real-world case (issue #651) — the implicit one collides:
///
///     ERROR|COMPILE_TIME_ERROR|DUPLICATE_DEFINITION|...|
///       The name 'length' is already defined.
///
/// These tests pin both directions: the shapes that must LOSE `late` (an
/// initializer-list assignment, a required initializing formal) and the shapes
/// that must KEEP it (assignment in a constructor BODY, an optional formal with
/// no default, a source-declared `late`), plus a real `dart analyze` over the
/// compiled output of the reported source shape.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

/// A `TypeDefinition main:<shortName>` carrying descriptor fields + metadata.
TypeDefinition _typeDef(
  String shortName, {
  required List<Map<String, Object?>> fieldsMeta,
  List<({String name, String type})> descriptorFields = const [],
}) {
  final td = TypeDefinition()..name = 'main:$shortName';
  td.mergeFromProto3Json({
    'descriptor': {
      'name': shortName,
      'field': [
        for (final f in descriptorFields)
          {'name': f.name, 'type': f.type, 'label': 'LABEL_OPTIONAL'},
      ],
    },
  });
  td.mergeFromProto3Json({
    'metadata': {'kind': 'class', 'fields': fieldsMeta},
  });
  return td;
}

FunctionDefinition _member(
  String qualifiedName, {
  required Map<String, Object?> metadata,
  Expression? body,
}) {
  final fn = FunctionDefinition()..name = qualifiedName;
  if (body != null) fn.body = body;
  fn.mergeFromProto3Json({'metadata': metadata});
  return fn;
}

Program _program({
  required List<TypeDefinition> typeDefs,
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
    ..typeDefs.addAll(typeDefs);
  return Program()
    ..name = 'field_finality_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([std, main]);
}

String _flat(Program p) =>
    DartCompiler(p, noFormat: true).compile().replaceAll(RegExp(r'\s+'), ' ');

/// Walks up from the test's CWD to the repo's `tests/conformance` directory,
/// the same way `conformance_compiler_inprocess_test.dart` locates the corpus.
Directory _findConformanceDir() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory('${dir.path}/tests/conformance');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'could not locate tests/conformance walking up from '
        '${Directory.current.absolute.path}',
      );
    }
    dir = parent;
  }
}

void main() {
  group('a field the constructor definitely assigns drops `late` (#651)', () {
    test('assigned by the constructor\'s own initializer list', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'FixedSlice',
              descriptorFields: [(name: 'length', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'length', 'type': 'int', 'is_final': true},
              ],
            ),
          ],
          members: [
            _member(
              'main:FixedSlice.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'end', 'type': 'int'},
                ],
                'initializers': [
                  {'kind': 'field', 'name': 'length', 'value': 'end'},
                ],
              },
            ),
          ],
        ),
      );
      expect(out, contains('final int length;'));
      expect(out, isNot(contains('late final int length')));
    });

    test('assigned by a required initializing formal', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Holder',
              descriptorFields: [(name: 'value', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'value', 'type': 'int', 'is_final': true},
              ],
            ),
          ],
          members: [
            _member(
              'main:Holder.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'value', 'type': 'int', 'is_this': true},
                ],
              },
            ),
          ],
        ),
      );
      expect(out, contains('final int value;'));
      expect(out, isNot(contains('late final int value')));
    });

    test('assigned by a required-NAMED initializing formal', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Holder',
              descriptorFields: [(name: 'value', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'value', 'type': 'int', 'is_final': true},
              ],
            ),
          ],
          members: [
            _member(
              'main:Holder.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {
                    'name': 'value',
                    'type': 'int',
                    'is_this': true,
                    'is_named': true,
                    'is_required_named': true,
                  },
                ],
              },
            ),
          ],
        ),
      );
      expect(out, isNot(contains('late final int value')));
    });

    test('every generative constructor must assign it — one that does not '
        'keeps `late`', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'TwoWays',
              descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'n', 'type': 'int'},
              ],
            ),
          ],
          members: [
            _member(
              'main:TwoWays.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'n', 'type': 'int'},
                ],
                'initializers': [
                  {'kind': 'field', 'name': 'n', 'value': 'n'},
                ],
              },
            ),
            // A second constructor that assigns `n` in its BODY instead.
            _member('main:TwoWays.empty', metadata: {'kind': 'constructor'}),
          ],
        ),
      );
      expect(out, contains('late int n;'));
    });

    test('a redirecting constructor does not have to assign it itself', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Redirects',
              descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'n', 'type': 'int', 'is_final': true},
              ],
            ),
          ],
          members: [
            _member(
              'main:Redirects.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'n', 'type': 'int', 'is_this': true},
                ],
              },
            ),
            _member(
              'main:Redirects.zero',
              metadata: {'kind': 'constructor', 'redirects_to': 'Redirects(0)'},
            ),
          ],
        ),
      );
      expect(out, isNot(contains('late final int n')));
    });

    test('a constructor redirecting through its INITIALIZER LIST does not '
        'have to assign it either', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'ThisRedirects',
              descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'n', 'type': 'int', 'is_final': true},
              ],
            ),
          ],
          members: [
            _member(
              'main:ThisRedirects.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'n', 'type': 'int', 'is_this': true},
                ],
              },
            ),
            _member(
              'main:ThisRedirects.zero',
              metadata: {
                'kind': 'constructor',
                'initializers': [
                  {'kind': 'redirect', 'args': '(0)'},
                ],
              },
            ),
          ],
        ),
      );
      expect(out, isNot(contains('late final int n')));
    });

    test('a factory constructor does not have to assign it either', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Factoried',
              descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'n', 'type': 'int', 'is_final': true},
              ],
            ),
            _typeDef('Other', fieldsMeta: const []),
          ],
          members: [
            _member(
              'main:Factoried.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'n', 'type': 'int', 'is_this': true},
                ],
              },
            ),
            _member(
              'main:Factoried.make',
              metadata: {'kind': 'constructor', 'is_factory': true},
            ),
          ],
        ),
      );
      expect(out, isNot(contains('late final int n')));
    });
  });

  group('a field nothing proves assigned keeps `late`', () {
    test('the only constructor assigns it in its BODY (#305, the case the '
        'heuristic gets right)', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'BodyAssigned',
              descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'n', 'type': 'int'},
              ],
            ),
          ],
          members: [
            _member(
              'main:BodyAssigned.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {'name': 'seed', 'type': 'int'},
                ],
              },
            ),
          ],
        ),
      );
      expect(out, contains('late int n;'));
    });

    test('an OPTIONAL initializing formal proves nothing', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Optional',
              descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'n', 'type': 'int'},
              ],
            ),
          ],
          members: [
            _member(
              'main:Optional.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {
                    'name': 'n',
                    'type': 'int',
                    'is_this': true,
                    'is_named': true,
                    'is_optional_named': true,
                  },
                ],
              },
            ),
          ],
        ),
      );
      expect(out, contains('late int n;'));
    });

    test(
      'an optional POSITIONAL initializing formal proves nothing either',
      () {
        final out = _flat(
          _program(
            typeDefs: [
              _typeDef(
                'OptionalPositional',
                descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
                fieldsMeta: [
                  {'name': 'n', 'type': 'int'},
                ],
              ),
            ],
            members: [
              _member(
                'main:OptionalPositional.new',
                metadata: {
                  'kind': 'constructor',
                  'params': [
                    {
                      'name': 'n',
                      'type': 'int',
                      'is_this': true,
                      'is_optional': true,
                    },
                  ],
                },
              ),
            ],
          ),
        );
        expect(out, contains('late int n;'));
      },
    );

    test('an optional initializing formal WITH a default does prove it', () {
      final out = _flat(
        _program(
          typeDefs: [
            _typeDef(
              'Defaulted',
              descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
              fieldsMeta: [
                {'name': 'n', 'type': 'int'},
              ],
            ),
          ],
          members: [
            _member(
              'main:Defaulted.new',
              metadata: {
                'kind': 'constructor',
                'params': [
                  {
                    'name': 'n',
                    'type': 'int',
                    'is_this': true,
                    'is_named': true,
                    'is_optional_named': true,
                    'default': '0',
                  },
                ],
              },
            ),
          ],
        ),
      );
      expect(out, isNot(contains('late int n')));
    });

    test(
      'a source-declared `late` survives an initializer-list assignment',
      () {
        final out = _flat(
          _program(
            typeDefs: [
              _typeDef(
                'ExplicitLate',
                descriptorFields: [(name: 'n', type: 'TYPE_INT32')],
                fieldsMeta: [
                  {'name': 'n', 'type': 'int', 'is_late': true},
                ],
              ),
            ],
            members: [
              _member(
                'main:ExplicitLate.new',
                metadata: {
                  'kind': 'constructor',
                  'initializers': [
                    {'kind': 'field', 'name': 'n', 'value': '1'},
                  ],
                },
              ),
            ],
          ),
        );
        expect(out, contains('late int n;'));
      },
    );
  });

  group('end-to-end: the reported `collection` shape', () {
    // The source is the conformance fixture itself, not a copy of it:
    // `466_initializer_list_field_with_setter` IS the reduced `ListSlice`
    // shape, and reading it here is what makes that fixture a PR gate for the
    // compiler-lowering point. The corpus runs on every engine, but no engine
    // has a notion of `late` — only the Dart target does, and only the
    // slow-tagged `dart-compiled` leg would otherwise ever try to ANALYZE what
    // this compiler emits for it.
    late String compiled;

    setUpAll(() {
      final fixture = File(
        '${_findConformanceDir().path}/src/'
        '466_initializer_list_field_with_setter.dart',
      );
      if (!fixture.existsSync()) {
        throw StateError('missing conformance fixture: ${fixture.path}');
      }
      compiled = DartCompiler(
        DartEncoder().encode(
          fixture.readAsStringSync(),
          name: 'field_finality',
        ),
      ).compile();
    });

    test('the field is emitted without `late`', () {
      expect(compiled, contains('final int windowSize;'));
      expect(compiled, isNot(contains('late final int windowSize')));
    });

    test(
      'the compiled source passes a real `dart analyze`',
      () async {
        final dir = Directory.systemTemp.createTempSync('ball_field_finality');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/compiled.dart')
          ..writeAsStringSync(compiled);

        // The real analyzer, not a substring check: DUPLICATE_DEFINITION is a
        // COMPILE_TIME_ERROR, so `--no-fatal-warnings` still surfaces it while
        // letting the compiler's cosmetic `unused_local_variable` prologue pass.
        final result = await Process.run(Platform.resolvedExecutable, [
          'analyze',
          '--no-fatal-warnings',
          file.path,
        ]);

        expect(
          result.exitCode,
          0,
          reason:
              'dart analyze rejected the compiled output:\n'
              '${result.stdout}\n${result.stderr}',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
