/// Tests for `package_encoder.dart` — encoding a whole Dart package directory
/// (pubspec.yaml + lib/bin/test files) into a single Ball [Program].
///
/// All packages are synthesised in temp directories. External-dependency
/// resolution is exercised with a [MockClient]-backed [PubClient] so no
/// network is required.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Create a file (with parent dirs) under [root].
void _write(Directory root, String rel, String content) {
  final f = File('${root.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

List<int> _buildTarGz(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.add(ArchiveFile(e.key, bytes.length, bytes));
  }
  return GZipEncoder().encode(TarEncoder().encode(archive));
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ball_pkg_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('static helpers', () {
    test('filePathToModuleName maps paths to dotted module names', () {
      expect(
        PackageEncoder.filePathToModuleName('lib/src/utils.dart'),
        equals('lib.src.utils'),
      );
      expect(
        PackageEncoder.filePathToModuleName('bin/main.dart'),
        equals('bin.main'),
      );
      // Backslashes and dashes are normalised.
      expect(
        PackageEncoder.filePathToModuleName(r'lib\my-pkg.dart'),
        equals('lib.my_pkg'),
      );
    });

    test('moduleNameToFilePath is the inverse for simple names', () {
      expect(
        PackageEncoder.moduleNameToFilePath('lib.src.utils'),
        equals('lib/src/utils.dart'),
      );
      expect(
        PackageEncoder.moduleNameToFilePath('bin.main'),
        equals('bin/main.dart'),
      );
    });
  });

  group('PackageEncoder.encode', () {
    test('encodes a minimal package with lib + bin into modules', () {
      _write(tmp, 'pubspec.yaml', 'name: demo\nversion: 1.2.3\n');
      _write(tmp, 'lib/util.dart', 'int triple(int n) => n * 3;\n');
      _write(tmp, 'bin/main.dart', '''
import 'package:demo/util.dart';
void main() {
  print(triple(7));
}
''');
      final enc = PackageEncoder(tmp);
      expect(enc.packageName, equals('demo'));
      expect(enc.packageVersion, equals('1.2.3'));

      final program = enc.encode();
      expect(program.name, equals('demo'));
      expect(program.version, equals('1.2.3'));
      // Entry module should be bin.main.
      expect(program.entryModule, equals('bin.main'));
      expect(program.entryFunction, equals('main'));

      final moduleNames = program.modules.map((m) => m.name).toSet();
      expect(moduleNames, contains('std'));
      expect(moduleNames, contains('lib.util'));
      expect(moduleNames, contains('bin.main'));

      // The file-to-module map is exposed and unmodifiable.
      final fileMap = enc.fileToModuleMap;
      expect(fileMap['lib/util.dart'], equals('lib.util'));
      expect(() => fileMap['x'] = 'y', throwsUnsupportedError);
    });

    test('auto-detects an entry file that is not bin/main.dart', () {
      _write(tmp, 'pubspec.yaml', 'name: app\nversion: 0.1.0\n');
      _write(tmp, 'bin/server.dart', '''
Future<void> main() async {
  print('server');
}
''');
      final program = PackageEncoder(tmp).encode();
      expect(program.entryModule, equals('bin.server'));
    });

    test('respects an explicit entryFile / entryFunction', () {
      _write(tmp, 'pubspec.yaml', 'name: app\nversion: 0.1.0\n');
      _write(tmp, 'bin/tool.dart', 'void run() {}\n');
      final program = PackageEncoder(
        tmp,
      ).encode(entryFile: 'bin/tool.dart', entryFunction: 'run');
      expect(program.entryModule, equals('bin.tool'));
      expect(program.entryFunction, equals('run'));
    });

    test('excludes part-of files from the module map', () {
      _write(tmp, 'pubspec.yaml', 'name: parts\nversion: 1.0.0\n');
      _write(tmp, 'lib/lib.dart', '''
library parts;
part 'frag.dart';
int root() => 0;
''');
      _write(tmp, 'lib/frag.dart', '''
part of 'lib.dart';
int frag() => 1;
''');
      final enc = PackageEncoder(tmp);
      final fileMap = enc.fileToModuleMap;
      // The part-of file must NOT be a standalone module.
      expect(fileMap.containsKey('lib/frag.dart'), isFalse);
      expect(fileMap.containsKey('lib/lib.dart'), isTrue);
    });

    test('keeps external package imports as empty stub modules', () {
      _write(tmp, 'pubspec.yaml', '''
name: withdeps
version: 1.0.0
dependencies:
  meta: ^1.0.0
''');
      _write(tmp, 'lib/uses.dart', '''
import 'package:meta/meta.dart';
int answer() => 42;
''');
      final program = PackageEncoder(tmp).encode();
      final stub = program.modules.firstWhere(
        (m) => m.name.contains('meta'),
        orElse: () => throw StateError('no meta stub'),
      );
      // Stub modules carry no functions.
      expect(stub.functions, isEmpty);
    });

    test('collects pubspec.yaml and resources into an __assets__ module', () {
      _write(tmp, 'pubspec.yaml', 'name: assets\nversion: 1.0.0\n');
      _write(
        tmp,
        'analysis_options.yaml',
        'include: package:lints/core.yaml\n',
      );
      _write(tmp, 'lib/code.dart', 'int x() => 1;\n');
      // A non-source directory whose files become resources.
      _write(tmp, 'assets/data.json', '{"k": 1}\n');
      final program = PackageEncoder(tmp).encode();
      final assets = program.modules.firstWhere(
        (m) => m.name == '__assets__',
        orElse: () => throw StateError('no __assets__ module'),
      );
      final paths = assets.assets.map((a) => a.path).toSet();
      expect(paths, contains('pubspec.yaml'));
      expect(paths, contains('analysis_options.yaml'));
      expect(paths, contains('assets/data.json'));
    });

    test('includes test/ files and resources when includeTests is true', () {
      _write(tmp, 'pubspec.yaml', 'name: tested\nversion: 1.0.0\n');
      _write(tmp, 'lib/code.dart', 'int x() => 1;\n');
      _write(tmp, 'test/code_test.dart', 'void main() {}\n');
      _write(tmp, 'test/fixtures/data.txt', 'fixture\n');
      final enc = PackageEncoder(tmp, includeTests: true);
      final program = enc.encode();
      final moduleNames = program.modules.map((m) => m.name).toSet();
      expect(moduleNames, contains('test.code_test'));
      final assets = program.modules.firstWhere((m) => m.name == '__assets__');
      final paths = assets.assets.map((a) => a.path).toSet();
      expect(paths, contains('test/fixtures/data.txt'));
    });

    test('resolves relative imports across files', () {
      _write(tmp, 'pubspec.yaml', 'name: rel\nversion: 1.0.0\n');
      _write(tmp, 'lib/a.dart', '''
import 'src/b.dart';
int useB() => fromB();
''');
      _write(tmp, 'lib/src/b.dart', 'int fromB() => 9;\n');
      final program = PackageEncoder(tmp).encode();
      final moduleNames = program.modules.map((m) => m.name).toSet();
      expect(moduleNames, contains('lib.a'));
      expect(moduleNames, contains('lib.src.b'));
    });
  });

  group('PackageEncoder.encodeAsync', () {
    test('returns plain program when resolveExternalDeps is false', () async {
      _write(tmp, 'pubspec.yaml', 'name: simple\nversion: 1.0.0\n');
      _write(tmp, 'bin/main.dart', 'void main() {}\n');
      final program = await PackageEncoder(tmp).encodeAsync();
      expect(program.name, equals('simple'));
    });

    test('downloads and inlines an external dependency', () async {
      _write(tmp, 'pubspec.yaml', '''
name: host
version: 1.0.0
dependencies:
  leftpad: ^1.0.0
''');
      _write(tmp, 'lib/host.dart', '''
import 'package:leftpad/leftpad.dart';
String use() => pad('x');
''');

      final depArchive = _buildTarGz({
        'pubspec.yaml': 'name: leftpad\nversion: 1.0.0\n',
        'lib/leftpad.dart': "String pad(String s) => ' \$s';\n",
      });

      final pubClient = PubClient(
        httpClient: MockClient((req) async {
          final path = req.url.path;
          if (path.contains('/api/packages/leftpad') &&
              !path.contains('archive')) {
            return http.Response(
              jsonEncode({
                'name': 'leftpad',
                'versions': [
                  {
                    'version': '1.0.0',
                    'archive_url':
                        'https://pub.dev/api/packages/leftpad/versions/1.0.0/archive',
                  },
                ],
              }),
              200,
            );
          }
          // Archive download.
          return http.Response.bytes(Uint8List.fromList(depArchive), 200);
        }),
      );

      final enc = PackageEncoder(
        tmp,
        resolveExternalDeps: true,
        pubClient: pubClient,
      );
      final program = await enc.encodeAsync();
      pubClient.close();

      // The leftpad library module should now be present (its `pad` function).
      final hasLeftpadFn = program.modules.any(
        (m) => m.functions.any((f) => f.name == 'pad'),
      );
      expect(hasLeftpadFn, isTrue);
    });

    test(
      'reuses an already-encoded dependency from the shared cache',
      () async {
        _write(tmp, 'pubspec.yaml', '''
name: host
version: 1.0.0
dependencies:
  cached_dep: ^1.0.0
''');
        _write(tmp, 'lib/host.dart', '''
import 'package:cached_dep/cached_dep.dart';
int x() => 1;
''');

        // Pre-populate the shared cache with an already-encoded dep program.
        final cachedProgram = Program()
          ..name = 'cached_dep'
          ..version = '1.0.0'
          ..modules.add(
            Module()
              ..name = 'lib.cached_dep'
              ..functions.add(FunctionDefinition()..name = 'cachedFn'),
          );
        final cache = <String, Program>{'cached_dep': cachedProgram};

        final enc = PackageEncoder(
          tmp,
          resolveExternalDeps: true,
          // A non-null client is required to enter _resolveExternalDeps; it is
          // never actually called because the cache short-circuits the lookup.
          pubClient: PubClient(
            httpClient: MockClient(
              (req) async =>
                  throw StateError('should not download: ${req.url}'),
            ),
          ),
          encodedCache: cache,
        );
        final program = await enc.encodeAsync();
        final hasCachedFn = program.modules.any(
          (m) => m.functions.any((f) => f.name == 'cachedFn'),
        );
        expect(hasCachedFn, isTrue);
      },
    );

    test('skips resolution and warns once the max depth is reached', () async {
      _write(tmp, 'pubspec.yaml', '''
name: host
version: 1.0.0
dependencies:
  deep_dep: ^1.0.0
''');
      _write(tmp, 'lib/host.dart', '''
import 'package:deep_dep/deep_dep.dart';
int x() => 1;
''');
      final enc = PackageEncoder(
        tmp,
        resolveExternalDeps: true,
        pubClient: PubClient(
          httpClient: MockClient(
            (req) async => throw StateError('should not download'),
          ),
        ),
        // currentDepth == maxDepth → depth limit hit immediately.
        maxDepth: 0,
        currentDepth: 0,
      );
      final program = await enc.encodeAsync();
      expect(enc.warnings.any((w) => w.contains('max depth')), isTrue);
      expect(program.name, equals('host'));
    });

    test('records a warning when a dependency cannot be resolved', () async {
      _write(tmp, 'pubspec.yaml', '''
name: host
version: 1.0.0
dependencies:
  broken: ^1.0.0
''');
      _write(tmp, 'lib/host.dart', '''
import 'package:broken/broken.dart';
int x() => 1;
''');
      final pubClient = PubClient(
        httpClient: MockClient((req) async => http.Response('error', 500)),
      );
      final enc = PackageEncoder(
        tmp,
        resolveExternalDeps: true,
        pubClient: pubClient,
      );
      final program = await enc.encodeAsync();
      pubClient.close();
      // Resolution failed → a warning is recorded and the program still returns.
      expect(enc.warnings, isNotEmpty);
      expect(program.name, equals('host'));
    });
  });
}
