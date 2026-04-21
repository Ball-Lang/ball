/// Integration test with a mock pub.dev-like HTTP server.
///
/// Tests PubAdapter + RegistryBridge directly against a local server,
/// verifying version resolution, module fetching, and lockfile generation.
///
/// Run: cd dart/cli && dart test test/mock_registry_test.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_resolver/ball_resolver.dart';
import 'package:test/test.dart';

List<int> buildMockModuleJson(String name) {
  final module = Module()
    ..name = name
    ..functions.add(FunctionDefinition()
      ..name = 'hello'
      ..isBase = true);
  return utf8.encode(jsonEncode(module.toProto3Json()));
}

List<int> buildMockArchive(String packageName) {
  final moduleBytes = buildMockModuleJson(packageName);
  final archive = Archive();
  archive.addFile(ArchiveFile(
    '$packageName/lib/module.ball.json',
    moduleBytes.length,
    Uint8List.fromList(moduleBytes),
  ));
  final tarBytes = TarEncoder().encode(archive);
  return GZipEncoder().encode(tarBytes);
}

void main() {
  late HttpServer server;
  late String baseUrl;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://localhost:${server.port}';

    server.listen((request) async {
      final path = request.uri.path;

      if (path.startsWith('/api/packages/') && !path.contains('/archive')) {
        final name = path.split('/').last;
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'name': name,
            'versions': [
              {'version': '1.0.0'},
              {'version': '1.1.0'},
              {'version': '2.0.0'},
            ],
          }));
        await request.response.close();
        return;
      }

      if (path.startsWith('/api/archives/')) {
        final filename = path.split('/').last;
        final match = RegExp(r'^(.+)-(\d+\.\d+\.\d+)\.tar\.gz$').firstMatch(filename);
        if (match != null) {
          final name = match.group(1)!;
          final archiveBytes = buildMockArchive(name);
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.binary
            ..add(archiveBytes);
          await request.response.close();
          return;
        }
      }

      request.response
        ..statusCode = 404
        ..write('Not found: $path');
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('PubAdapter resolves version from mock registry', () async {
    final adapter = PubAdapter();
    final version = await adapter.resolveVersion(
      'test_pkg',
      '^1.0.0',
      registryUrl: baseUrl,
    );
    expect(version, equals('1.1.0'));
  });

  test('PubAdapter resolves exact version', () async {
    final adapter = PubAdapter();
    final version = await adapter.resolveVersion(
      'test_pkg',
      '2.0.0',
      registryUrl: baseUrl,
    );
    expect(version, equals('2.0.0'));
  });

  test('PubAdapter fetches module from mock archive', () async {
    final adapter = PubAdapter();
    final result = await adapter.fetchModule(
      'test_pkg',
      '1.0.0',
      registryUrl: baseUrl,
    );
    expect(result.encoding, ModuleEncoding.MODULE_ENCODING_JSON);
    expect(result.resolvedVersion, '1.0.0');
    expect(result.bytes, isNotEmpty);
    final json = jsonDecode(utf8.decode(result.bytes));
    expect(json['name'], 'test_pkg');
  });

  test('RegistryBridge resolves module from mock registry', () async {
    final bridge = RegistryBridge()..register(PubAdapter());
    final source = RegistrySource()
      ..package = 'bridge_pkg'
      ..version = '^1.0.0'
      ..registry = Registry.REGISTRY_PUB
      ..registryUrl = baseUrl;

    final module = await bridge.resolve(source);
    expect(module.name, 'bridge_pkg');
    expect(module.functions, isNotEmpty);
    expect(module.functions.first.name, 'hello');
    expect(module.functions.first.isBase, isTrue);
  });

  test('ModuleResolver resolves and verifies integrity', () async {
    final bridge = RegistryBridge()..register(PubAdapter());
    final resolver = ModuleResolver(registryResolver: bridge.resolve);

    final source = RegistrySource()
      ..package = 'resolver_pkg'
      ..version = '^1.0.0'
      ..registry = Registry.REGISTRY_PUB
      ..registryUrl = baseUrl;

    final import_ = ModuleImport()
      ..name = 'resolver_pkg'
      ..registry = source;

    final module = await resolver.resolve(import_);
    expect(module.name, 'resolver_pkg');

    final integrity = computeIntegrity(module);
    expect(integrity, startsWith('sha256:'));
    expect(integrity.length, greaterThan(10));
  });

  test('version constraint excludes non-matching versions', () async {
    final adapter = PubAdapter();
    expect(
      () => adapter.resolveVersion('pkg', '<0.5.0', registryUrl: baseUrl),
      throwsStateError,
    );
  });

  test('lockfile structure from resolved modules', () async {
    final bridge = RegistryBridge()..register(PubAdapter());
    final resolver = ModuleResolver(registryResolver: bridge.resolve);

    final entries = <Map<String, Object?>>[];
    for (final name in ['pkg_a', 'pkg_b']) {
      final source = RegistrySource()
        ..package = name
        ..version = '^1.0.0'
        ..registry = Registry.REGISTRY_PUB
        ..registryUrl = baseUrl;

      final import_ = ModuleImport()
        ..name = name
        ..registry = source;

      final module = await resolver.resolve(import_);
      entries.add({
        'name': name,
        'resolved_version': '1.1.0',
        'integrity': computeIntegrity(module),
      });
    }

    final lockJson = jsonEncode({
      'lock_version': '1',
      'packages': entries,
    });
    final lock = jsonDecode(lockJson) as Map<String, dynamic>;
    expect(lock['lock_version'], '1');
    expect(lock['packages'], isList);
    expect((lock['packages'] as List).length, 2);
    for (final pkg in lock['packages'] as List) {
      final p = pkg as Map<String, dynamic>;
      expect(p['integrity'] as String, startsWith('sha256:'));
    }
  });
}
