/// Structural TS compile smoke tests.
///
/// Verifies that [TsCompiler.compileStructural] (the new plan + ts-morph
/// pipeline) produces runnable TypeScript for the existing Dart fixture
/// corpus. This is the scaffolding end-to-end check; feature depth
/// grows per Phase 2.1–2.4.
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

Program _loadFixture(String name) {
  final path =
      '${_findRepoRoot()}/tests/fixtures/dart/_generated/$name.ball.json';
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return Program()..mergeFromProto3Json(json);
}

void main() {
  final skip = _nodeModulesAvailable()
      ? null
      : 'node_modules missing under dart/compiler/tool';

  group('TsCompiler.compileStructural', () {
    test('emits main() wrapper and call for 01_hello', () async {
      final program = _loadFixture('01_hello');
      final out = await TsCompiler(program).compileStructural();
      expect(out, contains('function main()'));
      expect(out, contains('main();'));
      // `print('hello')` lowers to console.log via the existing TS runtime
      // preamble helpers.
      expect(out, contains('console.log'));
    }, skip: skip);

    test('emits a top-level function + main for 02_arithmetic',
        () async {
      final program = _loadFixture('02_arithmetic');
      final out = await TsCompiler(program).compileStructural();
      expect(out, contains('function main()'));
    }, skip: skip);
  });
}
