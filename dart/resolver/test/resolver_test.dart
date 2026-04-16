import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_resolver/ball_resolver.dart';
import 'package:test/test.dart';

Module _makeModule(String name, {List<String> functions = const []}) {
  final m = Module()..name = name;
  for (final fn in functions) {
    m.functions.add(FunctionDefinition()
      ..name = fn
      ..isBase = true);
  }
  return m;
}

void main() {
  group('integrity', () {
    test('computeIntegrity returns sha256 hash', () {
      final m = _makeModule('test', functions: ['foo']);
      final hash = computeIntegrity(m);
      expect(hash, startsWith('sha256:'));
      expect(hash.length, greaterThan(70));
    });

    test('same module produces same hash', () {
      final m1 = _makeModule('test', functions: ['foo']);
      final m2 = _makeModule('test', functions: ['foo']);
      expect(computeIntegrity(m1), computeIntegrity(m2));
    });

    test('different modules produce different hashes', () {
      final m1 = _makeModule('test', functions: ['foo']);
      final m2 = _makeModule('test', functions: ['bar']);
      expect(computeIntegrity(m1), isNot(computeIntegrity(m2)));
    });

    test('verifyIntegrity passes for matching hash', () {
      final m = _makeModule('test');
      final hash = computeIntegrity(m);
      expect(verifyIntegrity(m, hash), isTrue);
    });

    test('verifyIntegrity fails for wrong hash', () {
      final m = _makeModule('test');
      expect(verifyIntegrity(m, 'sha256:deadbeef'), isFalse);
    });

    test('verifyIntegrity passes for empty expected', () {
      final m = _makeModule('test');
      expect(verifyIntegrity(m, ''), isTrue);
    });
  });

  group('ContentAddressableCache', () {
    late Directory tempDir;
    late ContentAddressableCache cache;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('ball_cache_test_');
      cache = ContentAddressableCache(cacheDir: tempDir.path);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('put and get round-trip', () {
      final m = _makeModule('cached', functions: ['bar']);
      final hash = cache.put(m);
      expect(hash, startsWith('sha256:'));

      final retrieved = cache.get(hash);
      expect(retrieved, isNotNull);
      expect(retrieved!.name, 'cached');
      expect(retrieved.functions.first.name, 'bar');
    });

    test('has returns true after put', () {
      final m = _makeModule('test');
      final hash = cache.put(m);
      expect(cache.has(hash), isTrue);
    });

    test('has returns false for missing hash', () {
      expect(cache.has('sha256:0000'), isFalse);
    });

    test('get returns null for missing hash', () {
      expect(cache.get('sha256:0000'), isNull);
    });

    test('deduplication: same content stored once', () {
      final m1 = _makeModule('dedup');
      final m2 = _makeModule('dedup');
      final hash1 = cache.put(m1);
      final hash2 = cache.put(m2);
      expect(hash1, hash2);
    });
  });

  group('ModuleResolver', () {
    test('resolves InlineSource with proto bytes', () async {
      final module = _makeModule('inline_test', functions: ['fn1']);
      final import_ = ModuleImport()
        ..name = 'inline_test'
        ..inline = (InlineSource()..protoBytes = module.writeToBuffer());

      final resolver = ModuleResolver();
      final resolved = await resolver.resolve(import_);
      expect(resolved.name, 'inline_test');
      expect(resolved.functions.first.name, 'fn1');
    });

    test('resolves InlineSource with JSON', () async {
      final module = _makeModule('json_test', functions: ['fn2']);
      final json = jsonEncode(module.toProto3Json());
      final import_ = ModuleImport()
        ..name = 'json_test'
        ..inline = (InlineSource()..json = json);

      final resolver = ModuleResolver();
      final resolved = await resolver.resolve(import_);
      expect(resolved.name, 'json_test');
    });

    test('resolves FileSource', () async {
      final module = _makeModule('file_test', functions: ['fn3']);
      final tempDir = Directory.systemTemp.createTempSync('ball_file_test_');
      try {
        final file = File('${tempDir.path}/module.ball.bin');
        file.writeAsBytesSync(module.writeToBuffer());

        final import_ = ModuleImport()
          ..name = 'file_test'
          ..file = (FileSource()
            ..path = 'module.ball.bin'
            ..encoding = ModuleEncoding.MODULE_ENCODING_PROTO);

        final resolver = ModuleResolver(basePath: tempDir.path);
        final resolved = await resolver.resolve(import_);
        expect(resolved.name, 'file_test');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('integrity verification rejects tampered module', () async {
      final module = _makeModule('tampered');
      final import_ = ModuleImport()
        ..name = 'tampered'
        ..integrity = 'sha256:deadbeefdeadbeefdeadbeef'
        ..inline = (InlineSource()..protoBytes = module.writeToBuffer());

      final resolver = ModuleResolver();
      expect(
        () => resolver.resolve(import_),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Integrity check failed'),
        )),
      );
    });

    test('integrity verification passes for correct hash', () async {
      final module = _makeModule('verified', functions: ['x']);
      final hash = computeIntegrity(module);
      final import_ = ModuleImport()
        ..name = 'verified'
        ..integrity = hash
        ..inline = (InlineSource()..protoBytes = module.writeToBuffer());

      final resolver = ModuleResolver();
      final resolved = await resolver.resolve(import_);
      expect(resolved.name, 'verified');
    });

    test('cache hit skips fetch', () async {
      final tempDir = Directory.systemTemp.createTempSync('ball_cache_hit_');
      try {
        final cache = ContentAddressableCache(cacheDir: tempDir.path);
        final module = _makeModule('cached_mod', functions: ['a']);
        final hash = cache.put(module);

        // Import with integrity hash pointing to cached module.
        // No source set — would fail if cache miss.
        final import_ = ModuleImport()
          ..name = 'cached_mod'
          ..integrity = hash;

        final resolver = ModuleResolver(cache: cache);
        final resolved = await resolver.resolve(import_);
        expect(resolved.name, 'cached_mod');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('resolveAll inlines module imports', () async {
      final depModule = _makeModule('dep', functions: ['helper']);
      final program = Program()
        ..name = 'test_prog'
        ..version = '1.0.0'
        ..entryModule = 'main'
        ..entryFunction = 'main'
        ..modules.add(Module()
          ..name = 'main'
          ..moduleImports.add(ModuleImport()
            ..name = 'dep'
            ..inline = (InlineSource()..protoBytes = depModule.writeToBuffer())));

      final resolver = ModuleResolver();
      final resolved = await resolver.resolveAll(program);
      final moduleNames = resolved.modules.map((m) => m.name).toSet();
      expect(moduleNames, contains('dep'));
      expect(moduleNames, contains('main'));
    });

    test('RegistrySource without resolver throws', () async {
      final import_ = ModuleImport()
        ..name = 'reg_test'
        ..registry = (RegistrySource()
          ..registry = Registry.REGISTRY_PUB
          ..package = 'foo'
          ..version = '^1.0.0');

      final resolver = ModuleResolver();
      expect(
        () => resolver.resolve(import_),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('registry resolver'),
        )),
      );
    });
  });
}
