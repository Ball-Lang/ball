/// Directory- and lock-file-based tests for `pubspec_parser.dart`.
///
/// The existing `pubspec_parser_test.dart` covers `fromString`; this file
/// covers [PubspecParser.fromDirectory] and the `pubspec.lock` merge path
/// (`_withLockVersions`), which require real files on disk.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_encoder/pubspec_parser.dart';
import 'package:test/test.dart';

void main() {
  group('PubspecParser.fromDirectory', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ball_pubspec_');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('returns an "unknown" manifest when pubspec.yaml is absent', () {
      final manifest = PubspecParser.fromDirectory(tmp);
      expect(manifest.name, equals('unknown'));
      expect(manifest.dependencies, isEmpty);
      expect(manifest.resolvedVersions, isEmpty);
    });

    test('parses pubspec.yaml from a directory (no lock file)', () {
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('''
name: dir_pkg
version: 4.5.6
description: From a directory
dependencies:
  http: ^1.0.0
''');
      final manifest = PubspecParser.fromDirectory(tmp);
      expect(manifest.name, equals('dir_pkg'));
      expect(manifest.version, equals('4.5.6'));
      expect(manifest.description, equals('From a directory'));
      expect(manifest.dependencies['http'], equals('^1.0.0'));
      // No lock file → no resolved versions.
      expect(manifest.resolvedVersions, isEmpty);
    });

    test('merges resolved versions from pubspec.lock when present', () {
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('''
name: locked_pkg
version: 1.0.0
dependencies:
  http: ^1.0.0
  path: ^1.8.0
''');
      File('${tmp.path}/pubspec.lock').writeAsStringSync('''
packages:
  http:
    dependency: "direct main"
    source: hosted
    version: "1.2.2"
  path:
    dependency: "direct main"
    source: hosted
    version: "1.9.0"
sdks:
  dart: ">=3.0.0 <4.0.0"
''');
      final manifest = PubspecParser.fromDirectory(tmp);
      expect(manifest.name, equals('locked_pkg'));
      expect(manifest.resolvedVersions['http'], equals('1.2.2'));
      expect(manifest.resolvedVersions['path'], equals('1.9.0'));
      // Original dependency constraints are preserved alongside resolutions.
      expect(manifest.dependencies['http'], equals('^1.0.0'));
    });

    test('ignores a lock file that is not a YAML map', () {
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('''
name: weird_lock
version: 1.0.0
''');
      // A lock file whose top-level node is a scalar, not a map.
      File('${tmp.path}/pubspec.lock').writeAsStringSync('just a string\n');
      final manifest = PubspecParser.fromDirectory(tmp);
      expect(manifest.name, equals('weird_lock'));
      expect(manifest.resolvedVersions, isEmpty);
    });

    test('ignores a lock file with no packages map', () {
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('''
name: no_packages
version: 1.0.0
''');
      File('${tmp.path}/pubspec.lock').writeAsStringSync('''
sdks:
  dart: ">=3.0.0 <4.0.0"
''');
      final manifest = PubspecParser.fromDirectory(tmp);
      expect(manifest.resolvedVersions, isEmpty);
    });

    test('skips lock packages that omit a version field', () {
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('''
name: partial_lock
version: 1.0.0
''');
      File('${tmp.path}/pubspec.lock').writeAsStringSync('''
packages:
  good:
    source: hosted
    version: "2.0.0"
  bad:
    source: hosted
''');
      final manifest = PubspecParser.fromDirectory(tmp);
      expect(manifest.resolvedVersions['good'], equals('2.0.0'));
      expect(manifest.resolvedVersions.containsKey('bad'), isFalse);
    });
  });

  group('PubspecParser.fromString edge cases', () {
    test('returns "unknown" manifest for non-map YAML input', () {
      final manifest = PubspecParser.fromString('- just\n- a\n- list\n');
      expect(manifest.name, equals('unknown'));
    });

    test('coerces non-string dependency scalar values to strings', () {
      // A dependency value that is a YAML scalar but not a String (a number)
      // is coerced via toString().
      final manifest = PubspecParser.fromString('''
name: coerce
version: 1.0.0
dependencies:
  weird: 5
''');
      expect(manifest.dependencies['weird'], equals('5'));
    });

    test('parses nested lists inside a dependency map', () {
      final manifest = PubspecParser.fromString('''
name: nested
version: 1.0.0
dependencies:
  custom:
    items:
      - one
      - two
''');
      final dep = manifest.dependencies['custom'] as Map;
      expect(dep['items'], isA<List>());
      expect((dep['items'] as List), containsAll(['one', 'two']));
    });
  });
}
