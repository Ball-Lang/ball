/// Self-host Phase 2.6 regression guard.
///
/// Encodes `dart/engine/lib/engine.dart` and runs the structural TS
/// compile on it. Asserts that Node can load the emitted output via
/// `--experimental-strip-types`. Runtime parity with the Dart engine
/// (Phase 2.7) is blocked on providing TS equivalents of the protobuf
/// runtime — not checked here.
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

  test('self-host 2.6: engine.dart compiles to TS that Node parses',
      () async {
    final root = _findRepoRoot();
    final source = File(
      '$root/dart/engine/lib/engine.dart',
    ).readAsStringSync();

    final program = DartEncoder().encode(source, name: 'engine');
    expect(program.modules.isNotEmpty, true);

    final out = await TsCompiler(program).compileStructural();
    expect(out.length, greaterThan(50 * 1024),
        reason: 'Expected engine TS to be >50KB — encoded engine is large');
    expect(out, contains('export class BallEngine'),
        reason: 'BallEngine class should be present');
    expect(out, contains('export type BallValue'),
        reason: 'BallValue typedef should be present');
    expect(out, contains('async '),
        reason: 'Engine uses async heavily — native async must be emitted');

    final tmp = await Directory.systemTemp.createTemp('ball_engine_ts');
    try {
      final engineTs = File('${tmp.path}/engine_rt.ts');
      await engineTs.writeAsString(tsRuntimePreamble + '\n' + out);
      final smoke = File('${tmp.path}/smoke.ts');
      await smoke.writeAsString('''
import './engine_rt.ts';
console.log('engine_rt loaded OK');
''');
      final result = await Process.run(
        Platform.isWindows ? 'node.exe' : 'node',
        ['--experimental-strip-types', smoke.path],
        runInShell: true,
      );
      expect(result.exitCode, 0,
          reason: 'Node failed to load engine_rt.ts:\n'
              'stderr:\n${result.stderr}\n\n'
              'Check dart/self_host/lib/engine_rt.ts for context.');
      expect((result.stdout as String).trim(), contains('engine_rt loaded OK'));
    } finally {
      await tmp.delete(recursive: true);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
