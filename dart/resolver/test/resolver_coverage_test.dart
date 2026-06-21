/// Coverage-focused resolver tests: the git fetcher (real local repo), the
/// ModuleResolver git/http _fetch dispatch + transitive resolution, the cache's
/// default-dir + integrity-from-bytes helpers, and the npm/pub adapter getters,
/// close(), and the pub modulePath / top-level-strip branches.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ball_base/ball_base.dart'
    show encodeBallFileBinary, encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_resolver/ball_resolver.dart';
import 'package:ball_resolver/fetchers/git_fetcher.dart';
import 'package:ball_resolver/integrity.dart' show verifyIntegrityFromBytes;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Module _module(String name, {List<String> functions = const []}) {
  final m = Module()..name = name;
  for (final fn in functions) {
    m.functions.add(
      FunctionDefinition()
        ..name = fn
        ..isBase = true,
    );
  }
  return m;
}

/// Builds a gzipped tar from a {path: bytes} map.
List<int> _gzTar(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach(
    (name, content) =>
        archive.addFile(ArchiveFile(name, content.length, content)),
  );
  return GZipEncoder().encode(TarEncoder().encode(archive));
}

/// Initializes a git repo at [dir] with one commit containing [files], on a
/// branch named [branch], and returns nothing (the caller clones it by URL).
Future<void> _initGitRepo(
  Directory dir,
  Map<String, List<int>> files, {
  String branch = 'main',
}) async {
  Future<ProcessResult> git(List<String> args) =>
      Process.run('git', args, workingDirectory: dir.path);
  await git(['init', '-q', '-b', branch]);
  await git(['config', 'user.email', 'test@example.com']);
  await git(['config', 'user.name', 'Test']);
  await git(['config', 'commit.gpgsign', 'false']);
  files.forEach((name, content) {
    final f = File('${dir.path}/$name');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(content);
  });
  await git(['add', '.']);
  await git(['commit', '-q', '-m', 'init']);
}

void main() {
  group('git fetcher (real local repo)', () {
    late Directory repo;

    setUp(() => repo = Directory.systemTemp.createTempSync('ball_git_src_'));
    tearDown(() {
      try {
        repo.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('clones a branch and decodes a JSON module', () async {
      final json = jsonEncode(
        encodeBallFileJson(_module('gitmod', functions: ['g'])),
      );
      await _initGitRepo(repo, {'module.ball.json': utf8.encode(json)});

      final src = GitSource()
        ..url = repo.uri.toFilePath()
        ..ref = 'main'
        ..path = 'module.ball.json';
      final m = await fetchGit(src);
      expect(m.name, 'gitmod');
      expect(m.functions.first.name, 'g');
    }, testOn: 'vm');

    test('clones a branch and decodes a binary module', () async {
      await _initGitRepo(repo, {
        'module.ball.bin': encodeBallFileBinary(_module('gitbin')),
      });
      final src = GitSource()
        ..url = repo.uri.toFilePath()
        ..ref = 'main'
        ..path = 'module.ball.bin'
        ..encoding = ModuleEncoding.MODULE_ENCODING_PROTO;
      expect((await fetchGit(src)).name, 'gitbin');
    });

    test('throws when the module file is missing in the repo', () async {
      await _initGitRepo(repo, {'other.txt': utf8.encode('hi')});
      final src = GitSource()
        ..url = repo.uri.toFilePath()
        ..ref = 'main'
        ..path = 'module.ball.json';
      await expectLater(
        fetchGit(src),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'm',
            contains('not found'),
          ),
        ),
      );
    });

    test('throws when the clone fails (bad url)', () async {
      final src = GitSource()
        ..url = '${repo.path}/does-not-exist-xyz'
        ..ref = 'main'
        ..path = 'module.ball.json';
      await expectLater(fetchGit(src), throwsA(isA<StateError>()));
    });
  });

  group('ModuleResolver _fetch dispatch', () {
    test('GitSource routes through the git fetcher', () async {
      final repo = Directory.systemTemp.createTempSync('ball_git_res_');
      try {
        await _initGitRepo(repo, {
          'm.ball.json': utf8.encode(
            jsonEncode(encodeBallFileJson(_module('resgit'))),
          ),
        });
        final import_ = ModuleImport()
          ..name = 'resgit'
          ..git = (GitSource()
            ..url = repo.uri.toFilePath()
            ..ref = 'main'
            ..path = 'm.ball.json');
        final resolved = await ModuleResolver().resolve(import_);
        expect(resolved.name, 'resgit');
      } finally {
        try {
          repo.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test(
      'HttpSource routes through the http fetcher (injected client)',
      () async {
        final body = jsonEncode(encodeBallFileJson(_module('reshttp')));
        final client = MockClient((_) async => http.Response(body, 200));
        final import_ = ModuleImport()
          ..name = 'reshttp'
          ..http = (HttpSource()..url = 'https://x.example/m.ball.json');
        final resolved = await ModuleResolver(
          httpClient: client,
        ).resolve(import_);
        expect(resolved.name, 'reshttp');
      },
    );

    test('a ModuleImport with no source set throws', () async {
      final import_ = ModuleImport()..name = 'nosrc';
      await expectLater(
        ModuleResolver().resolve(import_),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'm',
            contains('no source set'),
          ),
        ),
      );
    });

    test(
      'RegistrySource routes through the registry resolver callback',
      () async {
        final import_ = ModuleImport()
          ..name = 'regmod'
          ..registry = (RegistrySource()
            ..registry = Registry.REGISTRY_PUB
            ..package = 'p'
            ..version = 'any');
        final resolver = ModuleResolver(
          registryResolver: (s) async => _module('fromregistry'),
        );
        expect((await resolver.resolve(import_)).name, 'fromregistry');
      },
    );
  });

  group('resolveAll transitive resolution', () {
    test('recursively resolves a module that itself imports another', () async {
      final leaf = _module('leaf', functions: ['l']);
      // `mid` imports `leaf` inline; `main` imports `mid` inline.
      final mid = _module('mid')
        ..moduleImports.add(
          ModuleImport()
            ..name = 'leaf'
            ..inline = (InlineSource()
              ..protoBytes = encodeBallFileBinary(leaf)),
        );
      final program = Program()
        ..name = 'p'
        ..entryModule = 'main'
        ..entryFunction = 'main'
        ..modules.add(
          Module()
            ..name = 'main'
            ..moduleImports.add(
              ModuleImport()
                ..name = 'mid'
                ..inline = (InlineSource()
                  ..protoBytes = encodeBallFileBinary(mid)),
            ),
        );

      final resolved = await ModuleResolver().resolveAll(program);
      final names = resolved.modules.map((m) => m.name).toSet();
      expect(names, containsAll(['main', 'mid']));
    });

    test(
      'resolveAll leaves an unresolvable import out without throwing',
      () async {
        final program = Program()
          ..name = 'p'
          ..modules.add(
            Module()
              ..name = 'main'
              ..moduleImports.add(
                ModuleImport()
                  ..name = 'broken'
                  ..http = (HttpSource()
                    ..url = 'https://nope.invalid/x.ball.json'),
              ),
          );
        // Inject a client that always fails so the catch in resolveAll runs.
        final client = MockClient((_) async => http.Response('boom', 500));
        final resolved = await ModuleResolver(
          httpClient: client,
        ).resolveAll(program);
        expect(resolved.modules.map((m) => m.name), contains('main'));
        expect(resolved.modules.map((m) => m.name), isNot(contains('broken')));
      },
    );
  });

  group('ContentAddressableCache extra branches', () {
    test('default cache dir is used when none is supplied', () {
      // Exercises _defaultCacheDir (HOME/USERPROFILE lookup).
      final cache = ContentAddressableCache();
      expect(cache.cacheDir, isNotEmpty);
      expect(cache.cacheDir, contains('.ball'));
    });

    test('put is idempotent for identical content (second put is a no-op)', () {
      final tmp = Directory.systemTemp.createTempSync('ball_cache_idem_');
      try {
        final cache = ContentAddressableCache(cacheDir: tmp.path);
        final m = _module('idem');
        final h1 = cache.put(m);
        final h2 = cache.put(m); // file already exists -> early return
        expect(h1, h2);
        expect(cache.has(h1), isTrue);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('integrity from-bytes', () {
    test('verifyIntegrityFromBytes matches / mismatches / empty', () {
      final bytes = utf8.encode('hello-ball');
      final cache = ContentAddressableCache(
        cacheDir: Directory.systemTemp.createTempSync('ball_int_').path,
      );
      final hash = cache.put(_module('x')); // any valid sha256:.. shape
      // Empty expected always passes.
      expect(verifyIntegrityFromBytes(bytes, ''), isTrue);
      // A wrong hash fails.
      expect(verifyIntegrityFromBytes(bytes, hash), isFalse);
      // The matching hash passes.
      expect(
        verifyIntegrityFromBytes(bytes, computeIntegrityFromBytes(bytes)),
        isTrue,
      );
    });
  });

  group('adapter getters + close + pub branches', () {
    test(
      'NpmAdapter exposes registryType / defaultUrl and close() is safe',
      () {
        final npm = NpmAdapter(
          httpClient: MockClient((_) async => http.Response('', 200)),
        );
        expect(npm.registryType, Registry.REGISTRY_NPM);
        expect(npm.defaultUrl, 'https://registry.npmjs.org');
        npm.close(); // closes the (mock) client
      },
    );

    test(
      'PubAdapter exposes registryType / defaultUrl and close() is safe',
      () {
        final pub = PubAdapter(
          httpClient: MockClient((_) async => http.Response('', 200)),
        );
        expect(pub.registryType, Registry.REGISTRY_PUB);
        expect(pub.defaultUrl, 'https://pub.dev');
        pub.close();
      },
    );

    test('PubAdapter.fetchModule honors a modulePath override', () async {
      final moduleBytes = utf8.encode('{"name":"m"}');
      // A flat archive (no top-level dir) so the no-slash name branch runs.
      final tarball = _gzTar({'custom.ball.json': moduleBytes});
      final pub = PubAdapter(
        httpClient: MockClient((_) async => http.Response.bytes(tarball, 200)),
      );
      final res = await pub.fetchModule(
        'ball',
        '1.0.0',
        modulePath: 'custom.ball.json',
      );
      expect(res.bytes, moduleBytes);
      expect(res.encoding, ModuleEncoding.MODULE_ENCODING_JSON);
    });

    test(
      'PubAdapter.fetchModule resolves a .ball.bin to PROTO encoding',
      () async {
        final moduleBytes = encodeBallFileBinary(_module('pb'));
        final tarball = _gzTar({'ball-1.0.0/lib/module.ball.bin': moduleBytes});
        final pub = PubAdapter(
          httpClient: MockClient(
            (_) async => http.Response.bytes(tarball, 200),
          ),
        );
        final res = await pub.fetchModule('ball', '1.0.0');
        expect(res.encoding, ModuleEncoding.MODULE_ENCODING_PROTO);
      },
    );
  });
}
