import 'package:ball_encoder/pubspec_parser.dart';
import 'package:test/test.dart';

void main() {
  group('PubspecParser', () {
    test('extracts name, version, description', () {
      final manifest = PubspecParser.fromString('''
name: my_package
version: 1.2.3
description: A test package
''');
      expect(manifest.name, 'my_package');
      expect(manifest.version, '1.2.3');
      expect(manifest.description, 'A test package');
    });

    test('parses hosted dependencies with version constraints', () {
      final manifest = PubspecParser.fromString('''
name: my_app
version: 1.0.0
dependencies:
  http: ^1.2.0
  path: ">=1.8.0 <2.0.0"
  meta: any
''');
      expect(manifest.dependencies, hasLength(3));
      expect(manifest.dependencies['http'], '^1.2.0');
      expect(manifest.dependencies['path'], '>=1.8.0 <2.0.0');
      expect(manifest.dependencies['meta'], 'any');
    });

    test('parses path dependencies', () {
      final manifest = PubspecParser.fromString('''
name: my_app
version: 1.0.0
dependencies:
  my_lib:
    path: ../my_lib
''');
      expect(manifest.dependencies['my_lib'], isA<Map>());
      final dep = manifest.dependencies['my_lib'] as Map;
      expect(dep['path'], '../my_lib');
    });

    test('parses git dependencies', () {
      final manifest = PubspecParser.fromString('''
name: my_app
version: 1.0.0
dependencies:
  my_lib:
    git:
      url: https://github.com/foo/bar.git
      ref: main
''');
      expect(manifest.dependencies['my_lib'], isA<Map>());
      final dep = manifest.dependencies['my_lib'] as Map;
      expect(dep['git'], isA<Map>());
      expect((dep['git'] as Map)['url'], 'https://github.com/foo/bar.git');
    });

    test('parses dev_dependencies', () {
      final manifest = PubspecParser.fromString('''
name: my_app
version: 1.0.0
dev_dependencies:
  test: ^1.25.0
  lints: ^2.0.0
''');
      expect(manifest.devDependencies, hasLength(2));
      expect(manifest.devDependencies['test'], '^1.25.0');
      expect(manifest.devDependencies['lints'], '^2.0.0');
    });

    test('handles missing dependencies gracefully', () {
      final manifest = PubspecParser.fromString('''
name: minimal
version: 0.0.1
''');
      expect(manifest.dependencies, isEmpty);
      expect(manifest.devDependencies, isEmpty);
    });

    test('handles mixed dependency types', () {
      final manifest = PubspecParser.fromString('''
name: complex
version: 2.0.0
dependencies:
  http: ^1.0.0
  local_pkg:
    path: ../local_pkg
  git_pkg:
    git:
      url: https://github.com/foo/bar.git
      ref: v1.0.0
      path: packages/bar
''');
      expect(manifest.dependencies, hasLength(3));
      expect(manifest.dependencies['http'], '^1.0.0');
      expect(manifest.dependencies['local_pkg'], isA<Map>());
      expect(manifest.dependencies['git_pkg'], isA<Map>());
      final gitDep = (manifest.dependencies['git_pkg'] as Map)['git'] as Map;
      expect(gitDep['path'], 'packages/bar');
    });

    test('resolvedVersions is empty without lock file', () {
      final manifest = PubspecParser.fromString('''
name: test
version: 1.0.0
dependencies:
  http: ^1.0.0
''');
      expect(manifest.resolvedVersions, isEmpty);
    });
  });
}
