/// Conformance test suite — runs all .ball.json programs from
/// tests/conformance/ and checks output against expected_output.txt.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

void main() {
  final conformanceDir = Directory('../../tests/conformance');
  if (!conformanceDir.existsSync()) {
    // Skip gracefully when running from a different working directory.
    return;
  }

  final testFiles =
      conformanceDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.ball.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  group('conformance', () {
    for (final testFile in testFiles) {
      final name = testFile.uri.pathSegments.last.replaceAll('.ball.json', '');
      final expectedFile = File(
        testFile.path.replaceAll('.ball.json', '.expected_output.txt'),
      );

      if (!expectedFile.existsSync()) continue;

      test(name, () {
        final jsonStr = testFile.readAsStringSync();
        final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        final program = Program()
          ..mergeFromProto3Json(jsonMap, ignoreUnknownFields: true);

        final lines = <String>[];
        final engine = BallEngine(program, stdout: lines.add);
        engine.run();
        final output = lines.join('\n').trimRight();
        final expected = expectedFile
            .readAsStringSync()
            .replaceAll('\r\n', '\n')
            .trimRight();

        expect(output, equals(expected));
      });
    }
  });
}
