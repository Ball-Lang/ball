/// Phase 2.2 class emission tests.
///
/// Encodes small Dart programs with classes, compiles them via the
/// structural TS pipeline, and verifies the resulting TS:
///   - declares the class with correct fields + methods
///   - captures method bodies with this.x references where appropriate
///   - runs under Node with --experimental-strip-types and produces
///     matching output to `dart run`
library;

import 'dart:io';

import 'package:ball_compiler/ts_compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

bool _nodeModulesAvailable() {
  var dir = Directory.current;
  while (true) {
    final nm = Directory('${dir.path}/dart/compiler/tool/node_modules');
    if (nm.existsSync()) return true;
    final parent = dir.parent;
    if (parent.path == dir.path) return false;
    dir = parent;
  }
}

String _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path.replaceAll('\\', '/');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate repo root');
    }
    dir = parent;
  }
}

void main() {
  final skip = _nodeModulesAvailable()
      ? null
      : 'node_modules missing under dart/compiler/tool';

  Future<void> _runFixtureRoundTrip(
    String fixture,
    List<String> mustContain,
  ) async {
    final root = _findRepoRoot();
    final sourcePath = '$root/tests/fixtures/compiler/ts/$fixture.dart';
    final source = File(sourcePath).readAsStringSync();
    final program = DartEncoder().encode(source, name: fixture);
    final out = await TsCompiler(program).compileStructural();
    for (final m in mustContain) {
      expect(out, contains(m), reason: 'missing `$m` in TS output:\n$out');
    }
    final tmp = await Directory.systemTemp.createTemp('ball_ts_$fixture');
    try {
      final ts = File('${tmp.path}/out.ts');
      await ts.writeAsString(tsRuntimePreamble + '\n' + out);
      final nodeRun = await Process.run(
        Platform.isWindows ? 'node.exe' : 'node',
        ['--experimental-strip-types', ts.path],
        runInShell: true,
      );
      expect(nodeRun.exitCode, 0,
          reason: 'Node failed:\nstderr:\n${nodeRun.stderr}\n\nemitted:\n$out');
      final dartRun = await Process.run(
        Platform.isWindows ? 'dart.bat' : 'dart',
        ['run', sourcePath],
        runInShell: true,
      );
      expect(dartRun.exitCode, 0);
      String normalize(String s) => s.replaceAll('\r\n', '\n').trim();
      expect(
        normalize(nodeRun.stdout as String),
        equals(normalize(dartRun.stdout as String)),
        reason: 'Node output differs from Dart',
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  group('TS class emission', () {
    test('class_basics — Point class round-trips Dart → Ball → TS → Node',
        () => _runFixtureRoundTrip('class_basics', [
              'class Point',
              'distanceSquared',
              'new Point(3, 4)',
              'p.distanceSquared(q)',
              'this.x',
            ]),
        skip: skip);

    test('async_basics — await chain round-trips to native TS async',
        () => _runFixtureRoundTrip('async_basics', [
              'async function compute',
              'async function chain',
              'async function main',
              'await compute',
              'await chain',
            ]),
        skip: skip);

    test('collections — List polyfills (add/removeLast/first/last/where)',
        () => _runFixtureRoundTrip('collections', [
              'list.add(1)',
              'list.removeLast()',
              'list.first',
              'list.last',
              'big.where',
              'big.contains(3)',
            ]),
        skip: skip);

    test('inheritance — abstract Shape, Circle/Square extending, implicit-this',
        () => _runFixtureRoundTrip('inheritance', [
              'abstract class Shape',
              'class Circle extends Shape',
              'class Square extends Shape',
              'this.describe()',
              'this.radius',
              'this.side',
            ]),
        skip: skip);

    test('exceptions — typed catch, rethrow, DomainError class',
        () => _runFixtureRoundTrip('exceptions', [
              'class DomainError',
              'throw new DomainError',
              'instanceof DomainError',
              'e.reason',
              'throw __ball_active_error',
            ]),
        skip: skip);
  });
}
