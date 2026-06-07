/// Conformance test suite — runs all .ball.json programs from
/// tests/conformance/ and checks output against expected_output.txt.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart' show decodeProgramJson;
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

void main() {
  // Single unified conformance directory — all .ball.json programs live in
  // tests/conformance/ (hand-written, encoder-generated, and cross-language
  // fixtures). Each needs a matching .expected_output.txt (except the 4
  // sandbox/security tests which validate error behavior instead).
  final confDir = Directory('../../tests/conformance');

  final testFiles = confDir.existsSync()
      ? (confDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.ball.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  group('conformance', () {
    for (final testFile in testFiles) {
      final name = testFile.uri.pathSegments.last.replaceAll('.ball.json', '');
      final expectedFile = File(
        testFile.path.replaceAll('.ball.json', '.expected_output.txt'),
      );
      if (name == '197_memory_limit') {
        test(name, () async {
          final program = decodeProgramJson(
            jsonDecode(testFile.readAsStringSync()),
          );

          await expectLater(
            BallEngine(program, maxMemoryBytes: 1000).run(),
            throwsA(
              isA<BallRuntimeError>().having(
                (error) => error.message,
                'message',
                contains('Memory limit exceeded'),
              ),
            ),
          );
        });
        continue;
      }
      if (name == '200_resource_exhaustion_protection') {
        test(name, () async {
          final program = decodeProgramJson(
            jsonDecode(testFile.readAsStringSync()),
          );

          await expectLater(
            BallEngine(program, maxMemoryBytes: 1000).run(),
            throwsA(
              isA<BallRuntimeError>().having(
                (error) => error.message,
                'message',
                contains('Memory limit exceeded'),
              ),
            ),
          );
        });
        continue;
      }
      if (name == '196_timeout') {
        test(name, () async {
          final program = decodeProgramJson(
            jsonDecode(testFile.readAsStringSync()),
          );

          await expectLater(
            BallEngine(program, timeoutMs: 1).run(),
            throwsA(
              isA<BallRuntimeError>().having(
                (error) => error.message,
                'message',
                contains('Execution timeout exceeded'),
              ),
            ),
          );
        });
        continue;
      }
      if (name == '202_sandbox_mode') {
        test(name, () async {
          final program = decodeProgramJson(
            jsonDecode(testFile.readAsStringSync()),
          );

          await expectLater(
            BallEngine(program, sandbox: true).run(),
            throwsA(
              isA<BallRuntimeError>().having(
                (error) => error.message,
                'message',
                equals('Sandbox violation: file_read is not allowed'),
              ),
            ),
          );
        });
        continue;
      }
      if (name == '201_input_validation') {
        test(name, () async {
          final program = decodeProgramJson(
            jsonDecode(testFile.readAsStringSync()),
          );

          expect(
            () => BallEngine(program),
            throwsA(
              isA<BallRuntimeError>().having(
                (error) => error.message,
                'message',
                equals('Too many modules: 102 (max 100)'),
              ),
            ),
          );

          expect(
            () => BallEngine(program, maxModules: 200, maxExpressionDepth: 3),
            throwsA(
              isA<BallRuntimeError>().having(
                (error) => error.message,
                'message',
                equals('Expression too deep: 4 levels (max 3)'),
              ),
            ),
          );

          expect(
            () => BallEngine(program, maxModules: 200, maxProgramSizeBytes: 1),
            throwsA(
              isA<BallRuntimeError>().having(
                (error) => error.message,
                'message',
                allOf(
                  startsWith('Program too large: '),
                  contains(' bytes (max 1)'),
                ),
              ),
            ),
          );
        });
        continue;
      }
      if (!expectedFile.existsSync()) continue;

      test(name, () async {
        final program = decodeProgramJson(
          jsonDecode(testFile.readAsStringSync()),
        );

        final lines = <String>[];
        await BallEngine(program, stdout: lines.add).run();
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
