/// Unit tests for [PackageCompiler] — the package-level Ball→Dart compiler
/// that turns a multi-module [Program] (as produced by `PackageEncoder`) back
/// into a Dart package directory.
///
/// Programs are built from proto3 JSON (concise for nested metadata/assets) and
/// driven through `compileToMap` / `writeToDirectory`, asserting the file layout,
/// base/stub skipping, export-facade emission, and embedded-asset extraction.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/package_compiler.dart';
import 'package:test/test.dart';

/// A std module marked entirely base (so it's skipped by the package compiler).
Map<String, dynamic> _stdModule() => {
  'name': 'std',
  'functions': [
    {'name': 'print', 'isBase': true},
  ],
};

/// A `print('<msg>')` body expression.
Map<String, dynamic> _printBody(String msg) => {
  'call': {
    'module': 'std',
    'function': 'print',
    'input': {
      'messageCreation': {
        'typeName': '',
        'fields': [
          {
            'name': 'message',
            'value': {
              'literal': {'stringValue': msg},
            },
          },
        ],
      },
    },
  },
};

/// A standalone function `<name>()` whose body prints [msg].
Map<String, dynamic> _fn(String name, String msg) => {
  'name': name,
  'outputType': 'void',
  'body': _printBody(msg),
};

Program _program(Map<String, dynamic> json) =>
    Program()..mergeFromProto3Json(json);

void main() {
  group('compileToMap', () {
    test('entry + library modules map to file paths; std skipped', () {
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'bin.main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'bin.main',
            'functions': [_fn('main', 'hi')],
          },
          {
            'name': 'lib.src.models',
            'functions': [_fn('helper', 'help')],
          },
        ],
      });

      final files = PackageCompiler(program).compileToMap();
      expect(files.keys, containsAll(['bin/main.dart', 'lib/src/models.dart']));
      // std is a base module → not emitted.
      expect(files.keys.any((k) => k.contains('std')), isFalse);
      // Entry module gets a `main()`.
      expect(files['bin/main.dart'], contains('void main()'));
      // Library module compiled without an entry point but with its function.
      expect(files['lib/src/models.dart'], contains('helper'));
    });

    test('external stub modules are skipped', () {
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'main',
            'functions': [_fn('main', 'hi')],
          },
          // A bare stub (no functions/types/enums/aliases/assets): skipped.
          {'name': 'package_x'},
        ],
      });

      final files = PackageCompiler(program).compileToMap();
      expect(files.keys, contains('main.dart'));
      expect(files.keys.any((k) => k.contains('package_x')), isFalse);
    });

    test('empty user module is treated as an external stub and skipped', () {
      // An empty `lib.*` module is a user-namespaced placeholder. The
      // constructor does not add it to the base set (it's a user module), so it
      // reaches `_isExternalStub`, which returns true → skipped.
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'main',
            'functions': [_fn('main', 'hi')],
          },
          {'name': 'lib.empty_placeholder'},
        ],
      });

      final files = PackageCompiler(program).compileToMap();
      expect(files.keys, contains('main.dart'));
      expect(files.keys.any((k) => k.contains('empty_placeholder')), isFalse);
    });

    test('export-facade module (dart_exports metadata) is emitted', () {
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'main',
            'functions': [_fn('main', 'hi')],
          },
          // A facade module: no Dart code, but carries dart_exports — must be
          // emitted so downstream imports resolve.
          {
            'name': 'lib.facade',
            'metadata': {
              'dart_exports': [
                {'uri': 'src/impl.dart', 'show': [], 'hide': []},
              ],
            },
          },
        ],
      });

      final files = PackageCompiler(program).compileToMap();
      expect(files.keys, contains('lib/facade.dart'));
      expect(files['lib/facade.dart'], contains("export 'src/impl.dart'"));
    });
  });

  group('writeToDirectory', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ball_pkgc_');
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('writes compiled modules + embedded assets to disk', () {
      final pubspec = 'name: pkg\nversion: 1.0.0\n';
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'bin.main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'bin.main',
            'functions': [_fn('main', 'hi')],
          },
          // Embedded assets module — content is base64 in proto3 JSON.
          {
            'name': '__assets__',
            'assets': [
              {
                'path': 'pubspec.yaml',
                'content': base64.encode(utf8.encode(pubspec)),
              },
            ],
          },
        ],
      });

      final written = PackageCompiler(program).writeToDirectory(tmp);
      expect(written, contains('bin/main.dart'));
      expect(written, contains('pubspec.yaml'));

      final mainFile = File('${tmp.path}/bin/main.dart');
      expect(mainFile.existsSync(), isTrue);
      expect(mainFile.readAsStringSync(), contains('void main()'));

      final pubspecFile = File('${tmp.path}/pubspec.yaml');
      expect(pubspecFile.existsSync(), isTrue);
      expect(pubspecFile.readAsStringSync(), contains('name: pkg'));
    });

    test('duplicate asset paths are de-duplicated (first wins)', () {
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'main',
            'functions': [_fn('main', 'hi')],
          },
          {
            'name': '__assets__',
            'assets': [
              {
                'path': 'data.txt',
                'content': base64.encode(utf8.encode('first')),
              },
              {
                'path': 'data.txt',
                'content': base64.encode(utf8.encode('second')),
              },
              // Empty-path asset is skipped.
              {'path': '', 'content': base64.encode(utf8.encode('x'))},
            ],
          },
        ],
      });

      final written = PackageCompiler(program).writeToDirectory(tmp);
      // data.txt appears once.
      expect(written.where((p) => p == 'data.txt').length, 1);
      expect(File('${tmp.path}/data.txt').readAsStringSync(), 'first');
    });

    test('sub-directory pubspec path: deps are rewritten', () {
      // A nested pubspec whose `path:` climbs above the package root should be
      // rewritten to `../` so it resolves inside the compiled output.
      final nested = 'name: sub\ndependencies:\n  dep:\n    path: ../../dep\n';
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'main',
            'functions': [_fn('main', 'hi')],
          },
          {
            'name': '__assets__',
            'assets': [
              {
                'path': 'example/pubspec.yaml',
                'content': base64.encode(utf8.encode(nested)),
              },
            ],
          },
        ],
      });

      PackageCompiler(program).writeToDirectory(tmp);
      final sub = File('${tmp.path}/example/pubspec.yaml');
      expect(sub.existsSync(), isTrue);
      final content = sub.readAsStringSync();
      // `../../dep` (2 ups) at depth 1 → rewritten to `../`.
      expect(content, contains('path: ../'));
    });

    test('parent dependency_overrides are propagated to sub pubspec', () {
      // Write a parent pubspec with a path override; a nested resource pubspec
      // without its own dependency_overrides should inherit a depth-adjusted one.
      File('${tmp.path}/pubspec.yaml').writeAsStringSync(
        'name: pkg\n'
        'dependency_overrides:\n'
        '  dep:\n'
        '    path: ../local_dep\n',
      );
      final nested = 'name: sub\ndependencies:\n  dep: ^1.0.0\n';
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'main',
            'functions': [_fn('main', 'hi')],
          },
          {
            'name': '__assets__',
            'assets': [
              {
                'path': 'tool/pubspec.yaml',
                'content': base64.encode(utf8.encode(nested)),
              },
            ],
          },
        ],
      });

      PackageCompiler(program).writeToDirectory(tmp);
      final sub = File('${tmp.path}/tool/pubspec.yaml').readAsStringSync();
      expect(sub, contains('dependency_overrides:'));
      expect(sub, contains('dep:'));
    });

    test('non-path dependency_override propagates as `any`', () {
      // A parent override that is an inline version constraint (not a path)
      // copies into the sub pubspec as `name: any` (line: non-path branch).
      File('${tmp.path}/pubspec.yaml').writeAsStringSync(
        'name: pkg\n'
        'dependency_overrides:\n'
        '  dep: ^2.0.0\n',
      );
      final nested = 'name: sub\ndependencies:\n  dep: ^1.0.0\n';
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'main',
            'functions': [_fn('main', 'hi')],
          },
          {
            'name': '__assets__',
            'assets': [
              {
                'path': 'tool/pubspec.yaml',
                'content': base64.encode(utf8.encode(nested)),
              },
            ],
          },
        ],
      });

      PackageCompiler(program).writeToDirectory(tmp);
      final sub = File('${tmp.path}/tool/pubspec.yaml').readAsStringSync();
      expect(sub, contains('dep: any'));
    });

    test(
      'dependency_overrides at EOF (empty captured block) takes fallback',
      () {
        // The first override line has no trailing newline, so the line-capturing
        // regex captures an empty block and the EOF fallback in
        // _extractDependencyOverrides runs. The compile must still succeed and
        // emit the sub pubspec without crashing.
        File(
          '${tmp.path}/pubspec.yaml',
        ).writeAsStringSync('name: pkg\ndependency_overrides:\n  dep: ^2.0.0');
        final nested = 'name: sub\ndependencies:\n  dep: ^1.0.0\n';
        final program = _program({
          'name': 'pkg',
          'version': '1.0.0',
          'entryModule': 'main',
          'entryFunction': 'main',
          'modules': [
            _stdModule(),
            {
              'name': 'main',
              'functions': [_fn('main', 'hi')],
            },
            {
              'name': '__assets__',
              'assets': [
                {
                  'path': 'tool/pubspec.yaml',
                  'content': base64.encode(utf8.encode(nested)),
                },
              ],
            },
          ],
        });

        PackageCompiler(program).writeToDirectory(tmp);
        final sub = File('${tmp.path}/tool/pubspec.yaml');
        expect(sub.existsSync(), isTrue);
        expect(sub.readAsStringSync(), contains('name: sub'));
      },
    );

    test('pubspec path with fewer ups than depth is left unchanged', () {
      // At depth 2 (`a/b/pubspec.yaml`): `../shallow` has 1 up which is < depth,
      // so it stays unchanged (the `ups < depth` branch); `../../deep` has 2 ups
      // (>= depth) so it's rewritten to `../`.
      final nested =
          'name: sub\n'
          'dependencies:\n'
          '  shallow:\n'
          '    path: ../shallow\n'
          '  deep:\n'
          '    path: ../../deep\n';
      final program = _program({
        'name': 'pkg',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': [
          _stdModule(),
          {
            'name': 'main',
            'functions': [_fn('main', 'hi')],
          },
          {
            'name': '__assets__',
            'assets': [
              {
                'path': 'a/b/pubspec.yaml',
                'content': base64.encode(utf8.encode(nested)),
              },
            ],
          },
        ],
      });

      PackageCompiler(program).writeToDirectory(tmp);
      final sub = File('${tmp.path}/a/b/pubspec.yaml').readAsStringSync();
      // shallow (1 up < depth 2) unchanged; deep (2 ups >= depth 2) → `../`.
      expect(sub, contains('path: ../shallow'));
      expect(sub, contains('path: ../\n'));
    });
  });
}
