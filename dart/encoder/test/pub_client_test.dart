/// Tests for `pub_client.dart` — the minimal pub.dev API client used to
/// resolve version constraints and download/extract package archives.
///
/// All HTTP traffic is faked with `package:http`'s [MockClient] so the tests
/// are hermetic (no network access). Archives are built in-memory with
/// `package:archive` (gzip + tar) so [PubClient.downloadPackage] exercises the
/// real decode + extract path.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ball_encoder/pub_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Build a gzip-compressed tar archive containing [files] (path → contents).
List<int> _buildTarGz(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.add(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final tar = TarEncoder().encode(archive);
  return GZipEncoder().encode(tar);
}

/// A canned `/api/packages/<name>` JSON body.
String _packageJson(String name, List<String> versions) => jsonEncode({
  'name': name,
  'versions': [
    for (final v in versions)
      {
        'version': v,
        'archive_url':
            'https://pub.dev/api/packages/$name/versions/$v/archive.tar.gz',
      },
  ],
});

void main() {
  group('PubClient construction', () {
    test('constructs with a default http.Client when none is supplied', () {
      // Exercises the `httpClient ?? http.Client()` default branch. We close
      // immediately without making a request so no network access occurs.
      final client = PubClient();
      expect(client.registryUrl, equals('https://pub.dev'));
      client.close();
    });
  });

  group('PubClient.getVersions', () {
    test('parses the versions list from the API', () async {
      final client = PubClient(
        httpClient: MockClient((req) async {
          expect(req.url.path, contains('/api/packages/foo'));
          return http.Response(_packageJson('foo', ['1.0.0', '1.2.0']), 200);
        }),
      );
      final versions = await client.getVersions('foo');
      expect(versions, hasLength(2));
      expect(versions.map((v) => v.version), containsAll(['1.0.0', '1.2.0']));
      expect(versions.first.archiveUrl, contains('archive.tar.gz'));
      client.close();
    });

    test('falls back to a derived archive URL when none is provided', () async {
      final client = PubClient(
        httpClient: MockClient((req) async {
          return http.Response(
            jsonEncode({
              'name': 'bar',
              'versions': [
                {'version': '2.0.0'}, // no archive_url key
              ],
            }),
            200,
          );
        }),
      );
      final versions = await client.getVersions('bar');
      expect(versions.single.version, '2.0.0');
      expect(
        versions.single.archiveUrl,
        equals('https://pub.dev/api/packages/bar/versions/2.0.0/archive'),
      );
      client.close();
    });

    test('returns empty list when the API omits the versions field', () async {
      final client = PubClient(
        httpClient: MockClient(
          (req) async => http.Response(jsonEncode({'name': 'baz'}), 200),
        ),
      );
      final versions = await client.getVersions('baz');
      expect(versions, isEmpty);
      client.close();
    });

    test('throws StateError on a non-200 response', () async {
      final client = PubClient(
        httpClient: MockClient((req) async => http.Response('not found', 404)),
      );
      expect(() => client.getVersions('missing'), throwsA(isA<StateError>()));
      client.close();
    });

    test('uses a custom registry URL', () async {
      Uri? requested;
      final client = PubClient(
        registryUrl: 'https://my.registry',
        httpClient: MockClient((req) async {
          requested = req.url;
          return http.Response(_packageJson('foo', ['1.0.0']), 200);
        }),
      );
      await client.getVersions('foo');
      expect(requested.toString(), startsWith('https://my.registry'));
      client.close();
    });
  });

  group('PubClient.resolveVersion', () {
    test('picks the highest version matching a caret constraint', () async {
      final client = PubClient(
        httpClient: MockClient(
          (req) async => http.Response(
            _packageJson('foo', ['1.0.0', '1.5.0', '2.0.0']),
            200,
          ),
        ),
      );
      final resolved = await client.resolveVersion('foo', '^1.0.0');
      expect(resolved.version, equals('1.5.0'));
      client.close();
    });

    test('resolves "any" to the highest available version', () async {
      final client = PubClient(
        httpClient: MockClient(
          (req) async => http.Response(
            _packageJson('foo', ['1.0.0', '3.1.0', '2.2.0']),
            200,
          ),
        ),
      );
      final resolved = await client.resolveVersion('foo', 'any');
      expect(resolved.version, equals('3.1.0'));
      client.close();
    });

    test('throws when no version satisfies the constraint', () async {
      final client = PubClient(
        httpClient: MockClient(
          (req) async => http.Response(_packageJson('foo', ['1.0.0']), 200),
        ),
      );
      expect(
        () => client.resolveVersion('foo', '^2.0.0'),
        throwsA(isA<StateError>()),
      );
      client.close();
    });
  });

  group('PubClient.downloadPackage', () {
    test('downloads, decodes and extracts a tar.gz archive', () async {
      final archiveBytes = _buildTarGz({
        'pubspec.yaml': 'name: foo\nversion: 1.0.0\n',
        'lib/foo.dart': 'int answer = 42;\n',
      });
      final client = PubClient(
        httpClient: MockClient((req) async {
          expect(req.url.path, contains('versions/1.0.0/archive'));
          return http.Response.bytes(Uint8List.fromList(archiveBytes), 200);
        }),
      );
      final dir = await client.downloadPackage('foo', '1.0.0');
      try {
        expect(dir.existsSync(), isTrue);
        final pubspec = File('${dir.path}/pubspec.yaml').readAsStringSync();
        expect(pubspec, contains('name: foo'));
        final lib = File('${dir.path}/lib/foo.dart').readAsStringSync();
        expect(lib, contains('int answer = 42;'));
      } finally {
        dir.deleteSync(recursive: true);
        client.close();
      }
    });

    test('honors an explicit archiveUrl override', () async {
      final archiveBytes = _buildTarGz({'pubspec.yaml': 'name: bar\n'});
      Uri? requested;
      final client = PubClient(
        httpClient: MockClient((req) async {
          requested = req.url;
          return http.Response.bytes(Uint8List.fromList(archiveBytes), 200);
        }),
      );
      final dir = await client.downloadPackage(
        'bar',
        '9.9.9',
        archiveUrl: 'https://cdn.example/bar.tar.gz',
      );
      try {
        expect(requested.toString(), equals('https://cdn.example/bar.tar.gz'));
        expect(dir.existsSync(), isTrue);
      } finally {
        dir.deleteSync(recursive: true);
        client.close();
      }
    });

    test('throws StateError on a failed download', () async {
      final client = PubClient(
        httpClient: MockClient((req) async => http.Response('gone', 410)),
      );
      expect(
        () => client.downloadPackage('foo', '1.0.0'),
        throwsA(isA<StateError>()),
      );
      client.close();
    });
  });
}
