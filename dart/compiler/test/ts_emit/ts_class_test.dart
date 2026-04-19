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

  group('TS class emission', () {
    test('class_basics — Point class round-trips Dart → Ball → TS → Node',
        () async {
      final root = _findRepoRoot();
      final sourcePath = '$root/tests/fixtures/compiler/ts/class_basics.dart';
      final source = File(sourcePath).readAsStringSync();
      final program = DartEncoder().encode(source, name: 'class_basics');
      final out = await TsCompiler(program).compileStructural();

      // Structural checks.
      expect(out, contains('class Point'));
      expect(out, contains('distanceSquared'));
      expect(out, contains('new Point(3, 4)'));
      expect(out, contains('p.distanceSquared(q)'));
      expect(out, contains('this.x'));

      final tmp = await Directory.systemTemp.createTemp('ball_ts_class');
      try {
        // Wrap with the existing TS runtime preamble so __ball_to_string
        // resolves. The old TsCompiler's preamble string is accessible
        // via the constant at the bottom of ts_compiler.dart.
        final ts = File('${tmp.path}/out.ts');
        await ts.writeAsString(tsRuntimePreamble + '\n' + out);
        final nodeRun = await Process.run(
          Platform.isWindows ? 'node.exe' : 'node',
          ['--experimental-strip-types', ts.path],
          runInShell: true,
        );
        expect(nodeRun.exitCode, 0,
            reason: 'Node failed:\n'
                'stderr:\n${nodeRun.stderr}\n\n'
                'stdout:\n${nodeRun.stdout}\n\n'
                'emitted:\n$out');

        // Reference: run the original Dart source for comparison.
        final dartRun = await Process.run(
          Platform.isWindows ? 'dart.bat' : 'dart',
          ['run', sourcePath],
          runInShell: true,
        );
        expect(dartRun.exitCode, 0);
        // Dart on Windows emits \r\n; Node uses \n. Normalize before
        // comparing so the test is platform-agnostic.
        String normalize(String s) => s.replaceAll('\r\n', '\n').trim();
        expect(
          normalize(nodeRun.stdout as String),
          equals(normalize(dartRun.stdout as String)),
          reason: 'Node output differs from Dart',
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    }, skip: skip);
  });
}
