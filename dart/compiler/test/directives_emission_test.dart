/// Unit tests for the compiler's directive emission (`_buildDirectives`) and
/// the import-alias / relative-module resolution helpers
/// (`_buildDartModuleAliases`, `_resolveRelativeModule`, `_uriToModuleName`):
/// conditional (`if (...)`) imports & exports, deferred imports, library-level
/// annotations, and relative/package import URIs.
///
/// The module's cosmetic `metadata` carries `dart_imports` / `dart_exports` /
/// `library_annotations`; we set them directly and assert the emitted source.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:test/test.dart';

/// Build a program whose entry module carries [moduleMetadata] (the
/// `dart_imports`/`dart_exports`/`library_annotations` cosmetics). [moduleName]
/// lets relative-import resolution see a dotted package path.
Program _program(
  Map<String, Object?> moduleMetadata, {
  String moduleName = 'lib.src.foo',
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
                ..name = 'message'
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
    ..name = moduleName
    ..functions.add(mainFn);
  main.mergeFromProto3Json({'metadata': moduleMetadata});
  return Program()
    ..name = 'directives_emission_test'
    ..version = '1.0.0'
    ..entryModule = moduleName
    ..entryFunction = 'main'
    ..modules.addAll([std, main]);
}

String _compile(
  Map<String, Object?> meta, {
  String moduleName = 'lib.src.foo',
}) => DartCompiler(
  _program(meta, moduleName: moduleName),
  noFormat: true,
).compile();

void main() {
  group('conditional imports', () {
    test('conditional import with value, prefix, show, hide', () {
      final out = _compile({
        'dart_imports': [
          {
            'uri': 'src_io.dart',
            'prefix': 'io',
            'show': ['A'],
            'hide': ['B'],
            'configurations': [
              {
                'name': 'dart.library.io',
                'value': 'true',
                'uri': 'src_io.dart',
              },
            ],
          },
        ],
      });
      expect(out, contains("import 'src_io.dart'"));
      expect(out, contains("if (dart.library.io == 'true') 'src_io.dart'"));
      expect(out, contains('as io'));
      expect(out, contains('show A'));
      expect(out, contains('hide B'));
    });

    test('conditional import without value (bare flag)', () {
      final out = _compile({
        'dart_imports': [
          {
            'uri': 'stub.dart',
            'configurations': [
              {'name': 'dart.library.html', 'uri': 'web.dart'},
            ],
          },
        ],
      });
      expect(out, contains('if (dart.library.html)'));
    });

    test('deferred import as prefix', () {
      final out = _compile({
        'dart_imports': [
          {'uri': 'dart:convert', 'prefix': 'conv', 'deferred': true},
        ],
      });
      expect(out, contains("import 'dart:convert'"));
      expect(out, contains('deferred'));
      expect(out, contains('as conv'));
    });
  });

  group('conditional exports', () {
    test('conditional export with value, show, hide', () {
      final out = _compile({
        'dart_exports': [
          {
            'uri': 'api.dart',
            'show': ['Foo'],
            'hide': ['Bar'],
            'configurations': [
              {
                'name': 'dart.library.io',
                'value': 'true',
                'uri': 'api_io.dart',
              },
            ],
          },
        ],
      });
      expect(out, contains("export 'api.dart'"));
      expect(out, contains("if (dart.library.io == 'true') 'api_io.dart'"));
      expect(out, contains('show Foo'));
      expect(out, contains('hide Bar'));
    });

    test('conditional export without value (bare flag)', () {
      final out = _compile({
        'dart_exports': [
          {
            'uri': 'base.dart',
            'configurations': [
              {'name': 'dart.library.html', 'uri': 'base_web.dart'},
            ],
          },
        ],
      });
      expect(out, contains('if (dart.library.html)'));
    });

    test('plain export', () {
      final out = _compile({
        'dart_exports': [
          {
            'uri': 'dart:math',
            'show': ['pi'],
          },
        ],
      });
      expect(out, contains("export 'dart:math'"));
    });
  });

  group('library annotations', () {
    test('library_annotations emit @-prefixed annotations', () {
      final out = _compile({
        'library_annotations': ['JS()'],
      });
      expect(out, contains('@JS()'));
    });
  });

  group('import alias / relative-module resolution', () {
    test('relative import alias resolves to a dotted module name', () {
      // A relative import is registered both under its bare and resolved name;
      // it compiles cleanly (the resolution helper runs without throwing).
      final out = _compile({
        'dart_imports': [
          {'uri': 'algorithms.dart', 'prefix': 'algo'},
        ],
      }, moduleName: 'lib.src.list_extensions');
      expect(out, contains("import 'algorithms.dart'"));
      expect(out, contains('as algo'));
    });

    test('package import alias is registered', () {
      final out = _compile({
        'dart_imports': [
          {'uri': 'package:collection/collection.dart', 'prefix': 'c'},
        ],
      });
      expect(out, contains("import 'package:collection/collection.dart'"));
      expect(out, contains('as c'));
    });
  });
}
