/// Integration test for `ball init → add → resolve → build` pipeline.
///
/// Run: cd dart/cli && dart test test/integration_test.dart
library;

import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;
  late String ballCli;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('ball_pkg_test_');
    ballCli = '${Directory.current.path}/bin/ball.dart';
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  Future<ProcessResult> ball(List<String> args) async {
    return Process.run(
      'dart',
      ['run', ballCli, ...args],
      workingDirectory: tmpDir.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  test('ball init creates ball.yaml', () async {
    final result = await ball(['init']);
    expect(result.exitCode, 0);
    final yaml = File('${tmpDir.path}/ball.yaml');
    expect(yaml.existsSync(), isTrue);
    final content = yaml.readAsStringSync();
    expect(content, contains('name:'));
    expect(content, contains('entry_module: main'));
    expect(content, contains('dependencies:'));
  });

  test('ball add appends dependency', () async {
    await ball(['init']);
    final result = await ball(['add', 'pub:path@^1.0.0']);
    expect(result.exitCode, 0);
    final yaml = File('${tmpDir.path}/ball.yaml');
    final content = yaml.readAsStringSync();
    expect(content, contains('path'));
  });

  test('full pipeline: init → add → resolve', () async {
    await ball(['init']);
    await ball(['add', 'pub:path@^1.0.0']);

    final resolveResult = await ball(['resolve']);
    // resolve may succeed or fail depending on network — check it doesn't crash
    expect(resolveResult.exitCode, anyOf(0, 1));
    if (resolveResult.exitCode == 0) {
      final lockFile = File('${tmpDir.path}/ball.lock.json');
      expect(lockFile.existsSync(), isTrue);
      final lock = jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
      expect(lock.containsKey('packages'), isTrue);
    }
  }, timeout: Timeout(Duration(seconds: 60)));
}
