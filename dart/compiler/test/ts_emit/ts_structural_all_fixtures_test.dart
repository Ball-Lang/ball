/// Stress-test: run [TsCompiler.compileStructural] against every
/// encoded fixture under `tests/fixtures/dart/_generated/`.
///
/// For each program:
///   - `compileStructural()` must produce TS without throwing
///   - The output (wrapped with tsRuntimePreamble) must load under
///     `node --experimental-strip-types`
///   - Stdout must match the fixture's `.expected_output.txt`
///
/// Establishes that the structural path is ready to replace the
/// string-based `compile()` for every existing fixture. Gaps
/// discovered here become Stop-Fix-Test-Resume targets.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/ts_compiler.dart';
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

  final root = _findRepoRoot();
  final fixturesDir = Directory('$root/tests/fixtures/dart/_generated');
  final fixtures = fixturesDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ball.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  group('structural TS compile: all Dart fixtures', () {
    for (final f in fixtures) {
      final name = f.uri.pathSegments.last.replaceAll('.ball.json', '');
      final expectedFile =
          File('$root/tests/fixtures/dart/_generated/${name}.expected_output.txt');

      test(name, () async {
        final program = Program()
          ..mergeFromProto3Json(
              jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
        final compileOut = await TsCompiler(program).compileStructural();

        final tmp =
            await Directory.systemTemp.createTemp('ball_ts_struct_$name');
        try {
          final ts = File('${tmp.path}/out.ts');
          await ts.writeAsString(tsRuntimePreamble + '\n' + compileOut);
          final node = await Process.run(
            Platform.isWindows ? 'node.exe' : 'node',
            ['--experimental-strip-types', ts.path],
            runInShell: true,
          );
          if (node.exitCode != 0) {
            fail('Node failed for $name (exit ${node.exitCode}):\n'
                'stderr:\n${node.stderr}\n\n'
                'First 200 lines:\n'
                '${compileOut.split('\n').take(200).join('\n')}');
          }
          if (expectedFile.existsSync()) {
            final expected = expectedFile.readAsStringSync();
            String norm(String s) =>
                s.replaceAll('\r\n', '\n').trimRight();
            expect(norm(node.stdout as String), equals(norm(expected)),
                reason: 'Stdout mismatch for $name');
          }
        } finally {
          await tmp.delete(recursive: true);
        }
      }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
    }
  });
}
