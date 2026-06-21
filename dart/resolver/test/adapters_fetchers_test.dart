/// Unit tests for the registry adapters (npm, pub) and the file/inline
/// fetchers. The adapters were exercised by no test (0% coverage); they take an
/// injectable `http.Client`, so these drive them with an in-memory MockClient
/// and archive fixtures — no real network. (#59/#61 coverage climb.)
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ball_base/ball_base.dart'
    show encodeBallFileBinary, encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_resolver/ball_resolver.dart';
import 'package:ball_resolver/fetchers/file_fetcher.dart';
import 'package:ball_resolver/fetchers/http_fetcher.dart';
import 'package:ball_resolver/fetchers/inline_fetcher.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Builds a gzipped tar (the inverse of the adapters' GZip+Tar decode) from a
/// {path: bytes} map.
List<int> _gzTar(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach(
    (name, content) =>
        archive.addFile(ArchiveFile(name, content.length, content)),
  );
  final tar = TarEncoder().encode(archive);
  return GZipEncoder().encode(tar);
}

Module _module(String name) => Module()..name = name;

/// Minimal in-memory [RegistryAdapter] for exercising [RegistryBridge] without
/// network. `fetchThrows` simulates "no pre-built Ball artifact" so the bridge's
/// on-the-fly fallback path can be tested.
class _FakeAdapter extends RegistryAdapter {
  _FakeAdapter({this.module, this.fetchThrows = false});

  final ResolvedRegistryModule? module;
  final bool fetchThrows;

  @override
  Registry get registryType => Registry.REGISTRY_PUB;
  @override
  String get defaultUrl => 'https://fake.example';
  @override
  Future<String> resolveVersion(
    String package,
    String constraint, {
    String? registryUrl,
    Map<String, String>? headers,
  }) async => '1.0.0';
  @override
  Future<ResolvedRegistryModule> fetchModule(
    String package,
    String version, {
    String? modulePath,
    ModuleEncoding encoding = ModuleEncoding.MODULE_ENCODING_UNSPECIFIED,
    String? registryUrl,
    Map<String, String>? headers,
  }) async {
    if (fetchThrows) throw StateError('no pre-built Ball artifact');
    return module!;
  }
}

void main() {
  final moduleBytes = utf8.encode('{"name":"m"}');

  group('NpmAdapter.resolveVersion', () {
    NpmAdapter npmWith(String body, int status) => NpmAdapter(
      httpClient: MockClient((_) async => http.Response(body, status)),
    );

    test('picks the highest version matching the constraint', () async {
      final npm = npmWith(
        jsonEncode({
          'versions': {'1.0.0': {}, '1.5.0': {}, '2.0.0': {}},
        }),
        200,
      );
      expect(await npm.resolveVersion('leftpad', '^1.0.0'), '1.5.0');
    });

    test('empty constraint resolves to the highest version (any)', () async {
      final npm = npmWith(
        jsonEncode({
          'versions': {'1.0.0': {}, '3.0.0': {}},
        }),
        200,
      );
      expect(await npm.resolveVersion('leftpad', ''), '3.0.0');
    });

    test('skips invalid semver versions', () async {
      final npm = npmWith(
        jsonEncode({
          'versions': {'1.0.0': {}, 'not-a-version': {}, '1.2.0': {}},
        }),
        200,
      );
      expect(await npm.resolveVersion('leftpad', 'any'), '1.2.0');
    });

    test('throws on a non-200 response', () {
      expect(npmWith('nope', 404).resolveVersion('x', 'any'), throwsStateError);
    });

    test('throws when no version matches the constraint', () {
      final npm = npmWith(
        jsonEncode({
          'versions': {'1.0.0': {}},
        }),
        200,
      );
      expect(npm.resolveVersion('x', '^2.0.0'), throwsStateError);
    });
  });

  group('NpmAdapter.fetchModule', () {
    // metadata request path ends with /<version>; everything else is the tarball.
    MockClient client(
      List<int>? tarball, {
      int metaStatus = 200,
      int tarStatus = 200,
    }) => MockClient((req) async {
      if (req.url.path.endsWith('/1.0.0')) {
        return http.Response(
          jsonEncode({
            'dist': {'tarball': 'https://reg.example/x.tgz'},
          }),
          metaStatus,
        );
      }
      return http.Response.bytes(tarball ?? const [], tarStatus);
    });

    test('returns the embedded module bytes from the tarball', () async {
      final npm = NpmAdapter(
        httpClient: client(_gzTar({'package/module.ball.json': moduleBytes})),
      );
      final res = await npm.fetchModule('leftpad', '1.0.0');
      expect(res.bytes, moduleBytes);
      expect(res.encoding, ModuleEncoding.MODULE_ENCODING_JSON);
      expect(res.resolvedVersion, '1.0.0');
      expect(res.sourceUrl, 'https://reg.example/x.tgz');
    });

    test('honors a modulePath override', () async {
      final npm = NpmAdapter(
        httpClient: client(_gzTar({'custom/path.ball.json': moduleBytes})),
      );
      final res = await npm.fetchModule(
        'leftpad',
        '1.0.0',
        modulePath: 'custom/path.ball.json',
      );
      expect(res.bytes, moduleBytes);
    });

    test('throws when metadata fetch fails', () {
      final npm = NpmAdapter(httpClient: client(null, metaStatus: 500));
      expect(npm.fetchModule('x', '1.0.0'), throwsStateError);
    });

    test('throws when the tarball download fails', () {
      final npm = NpmAdapter(httpClient: client(null, tarStatus: 404));
      expect(npm.fetchModule('x', '1.0.0'), throwsStateError);
    });

    test('throws when no Ball module is in the archive', () {
      final npm = NpmAdapter(
        httpClient: client(_gzTar({'package/README.md': utf8.encode('hi')})),
      );
      expect(npm.fetchModule('x', '1.0.0'), throwsStateError);
    });
  });

  group('PubAdapter.resolveVersion', () {
    PubAdapter pubWith(String body, int status) => PubAdapter(
      httpClient: MockClient((_) async => http.Response(body, status)),
    );

    test('picks the highest version matching the constraint', () async {
      final pub = pubWith(
        jsonEncode({
          'versions': [
            {'version': '1.0.0'},
            {'version': '1.4.0'},
            {'version': '2.0.0'},
          ],
        }),
        200,
      );
      expect(await pub.resolveVersion('ball', '>=1.0.0 <2.0.0'), '1.4.0');
    });

    test('throws on a non-200 response', () {
      expect(pubWith('nope', 503).resolveVersion('x', 'any'), throwsStateError);
    });

    test('throws when no version matches', () {
      final pub = pubWith(
        jsonEncode({
          'versions': [
            {'version': '1.0.0'},
          ],
        }),
        200,
      );
      expect(pub.resolveVersion('x', '^9.0.0'), throwsStateError);
    });
  });

  group('PubAdapter.fetchModule', () {
    test('strips the top-level dir and returns the module bytes', () async {
      // pub archives wrap files in a <pkg>-<version>/ top-level directory.
      final tarball = _gzTar({'ball-1.0.0/lib/module.ball.json': moduleBytes});
      final pub = PubAdapter(
        httpClient: MockClient((_) async => http.Response.bytes(tarball, 200)),
      );
      final res = await pub.fetchModule('ball', '1.0.0');
      expect(res.bytes, moduleBytes);
      expect(res.encoding, ModuleEncoding.MODULE_ENCODING_JSON);
      expect(res.resolvedVersion, '1.0.0');
      expect(res.sourceUrl, contains('ball-1.0.0.tar.gz'));
    });

    test('throws when the archive request fails', () {
      final pub = PubAdapter(
        httpClient: MockClient((_) async => http.Response('gone', 404)),
      );
      expect(pub.fetchModule('x', '1.0.0'), throwsStateError);
    });

    test('throws when no Ball module is in the archive', () {
      final tarball = _gzTar({'x-1.0.0/README.md': utf8.encode('hi')});
      final pub = PubAdapter(
        httpClient: MockClient((_) async => http.Response.bytes(tarball, 200)),
      );
      expect(pub.fetchModule('x', '1.0.0'), throwsStateError);
    });
  });

  group('fetchFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ball_ff_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('loads a JSON module file', () {
      final f = File('${tmp.path}/m.ball.json')
        ..writeAsStringSync(
          const JsonEncoder().convert(encodeBallFileJson(_module('jsonmod'))),
        );
      final src = FileSource()..path = f.path;
      expect(fetchFile(src).name, 'jsonmod');
    });

    test('loads a binary module file via PROTO encoding', () {
      final f = File('${tmp.path}/m.ball.bin')
        ..writeAsBytesSync(encodeBallFileBinary(_module('binmod')));
      final src = FileSource()
        ..path = f.path
        ..encoding = ModuleEncoding.MODULE_ENCODING_PROTO;
      expect(fetchFile(src).name, 'binmod');
    });

    test('resolves a relative path against basePath', () {
      File('${tmp.path}/rel.ball.json').writeAsStringSync(
        const JsonEncoder().convert(encodeBallFileJson(_module('relmod'))),
      );
      final src = FileSource()..path = 'rel.ball.json';
      expect(fetchFile(src, basePath: tmp.path).name, 'relmod');
    });

    test('throws when the file is missing', () {
      final src = FileSource()..path = '${tmp.path}/nope.ball.json';
      expect(() => fetchFile(src), throwsStateError);
    });
  });

  group('fetchInline', () {
    test('decodes a JSON inline module', () {
      final src = InlineSource()
        ..json = jsonEncode(encodeBallFileJson(_module('inlinejson')));
      expect(fetchInline(src).name, 'inlinejson');
    });

    test('decodes a proto-bytes inline module', () {
      final src = InlineSource()
        ..protoBytes = encodeBallFileBinary(_module('inlinebin'));
      expect(fetchInline(src).name, 'inlinebin');
    });

    test('throws when neither protoBytes nor json is set', () {
      expect(() => fetchInline(InlineSource()), throwsStateError);
    });
  });

  group('fetchHttp', () {
    test('downloads + decodes a JSON module', () async {
      final body = jsonEncode(encodeBallFileJson(_module('httpmod')));
      final client = MockClient((_) async => http.Response(body, 200));
      final src = HttpSource()..url = 'https://x.example/m.ball.json';
      expect((await fetchHttp(src, client: client)).name, 'httpmod');
    });

    test('decodes a binary module when the url ends with .ball.bin', () async {
      final bytes = encodeBallFileBinary(_module('httpbin'));
      final client = MockClient((_) async => http.Response.bytes(bytes, 200));
      final src = HttpSource()..url = 'https://x.example/m.ball.bin';
      expect((await fetchHttp(src, client: client)).name, 'httpbin');
    });

    test('forwards custom headers from the source', () async {
      String? seen;
      final client = MockClient((req) async {
        seen = req.headers['x-token'];
        return http.Response(jsonEncode(encodeBallFileJson(_module('h'))), 200);
      });
      final src = HttpSource()
        ..url = 'https://x.example/m.ball.json'
        ..headers['x-token'] = 'secret';
      await fetchHttp(src, client: client);
      expect(seen, 'secret');
    });

    test('throws on a non-200 response', () {
      final client = MockClient((_) async => http.Response('nope', 404));
      final src = HttpSource()..url = 'https://x.example/m.ball.json';
      expect(fetchHttp(src, client: client), throwsStateError);
    });
  });

  group('RegistryBridge', () {
    RegistrySource src() => RegistrySource()
      ..registry = Registry.REGISTRY_PUB
      ..package = 'p'
      ..version = 'any';

    test('routes to the registered adapter (JSON bytes)', () async {
      final bytes = utf8.encode(jsonEncode(_module('bridged').toProto3Json()));
      final bridge = RegistryBridge()
        ..register(
          _FakeAdapter(
            module: ResolvedRegistryModule(
              bytes: bytes,
              encoding: ModuleEncoding.MODULE_ENCODING_JSON,
              resolvedVersion: '1.0.0',
              sourceUrl: 'u',
            ),
          ),
        );
      expect((await bridge.resolve(src())).name, 'bridged');
    });

    test('routes to the registered adapter (PROTO bytes)', () async {
      final bytes = _module('bridgedbin').writeToBuffer();
      final bridge = RegistryBridge()
        ..register(
          _FakeAdapter(
            module: ResolvedRegistryModule(
              bytes: bytes,
              encoding: ModuleEncoding.MODULE_ENCODING_PROTO,
              resolvedVersion: '1.0.0',
              sourceUrl: 'u',
            ),
          ),
        );
      expect((await bridge.resolve(src())).name, 'bridgedbin');
    });

    test('throws when no adapter is registered for the registry', () {
      expect(RegistryBridge().resolve(src()), throwsStateError);
    });

    test(
      'falls back to onTheFlyEncoder when the adapter has no artifact',
      () async {
        RegistrySource? gotSource;
        String? gotVersion;
        final bridge = RegistryBridge()
          ..register(_FakeAdapter(fetchThrows: true))
          ..onTheFlyEncoder = (s, v) async {
            gotSource = s;
            gotVersion = v;
            return _module('onthefly');
          };
        expect((await bridge.resolve(src())).name, 'onthefly');
        // The resolved version + original source must reach the encoder.
        expect(gotVersion, '1.0.0');
        expect(gotSource?.package, 'p');
      },
    );
  });
}
