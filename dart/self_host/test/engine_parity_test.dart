/// Self-host Phase 1 parity test.
///
/// Runs every Ball program in [tests/conformance/] through BOTH:
///   - the live `package:ball_engine/engine.dart`
///   - the round-tripped `package:ball_self_host_tests/engine_roundtrip.dart`
/// and asserts they produce identical stdout.
///
/// This is the hard proof that the encoder + compiler preserve engine
/// semantics: if the round-tripped engine executes the conformance programs
/// with byte-identical output, the self-host round-trip is faithful.
///
/// Regenerate the round-tripped engine first via:
///   dart run dart/encoder/tool/roundtrip_engine.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart' as live;
import 'package:ball_self_host_tests/engine_roundtrip.dart' as rt;
import 'package:test/test.dart';

void main() {
  final repoRoot = _findRepoRoot();
  final conformanceDir = Directory('$repoRoot/tests/conformance');

  final programs = conformanceDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ball.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  group('self-host parity — conformance suite', () {
    for (final f in programs) {
      final name = f.uri.pathSegments.last.replaceAll('.ball.json', '');
      test(name, () async {
        final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final program = Program()..mergeFromProto3Json(json);

        final liveOut = await _runLive(program);
        final rtOut = await _runRoundTripped(program);

        expect(rtOut, equals(liveOut),
            reason: 'Round-tripped engine output differs from live engine '
                'on $name. If this test fails after regeneration, a '
                'Stop-Fix-Test-Resume cycle is needed on encoder or compiler.');
      });
    }
  });
}

Future<List<String>> _runLive(Program program) async {
  final out = <String>[];
  final engine = live.BallEngine(program, stdout: out.add);
  await engine.run();
  return out;
}

Future<List<String>> _runRoundTripped(Program program) async {
  final out = <String>[];
  final engine = rt.BallEngine(program, stdout: out.add);
  await engine.run();
  return out;
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
