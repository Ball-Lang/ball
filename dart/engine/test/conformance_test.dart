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
  // Two fixture sources:
  //   1. tests/conformance/ — hand-written ball.json files (the 21-24
  //      series) that exercise specific IR shapes the encoder doesn't
  //      currently generate. Engine-layer tests.
  //   2. tests/fixtures/dart/_generated/ — auto-generated from Dart
  //      sources by the cross-language harness. Encoder-layer tests.
  //
  // Each entry needs a matching `.expected_output.txt` — for the
  // generated directory we fall back to running `dart` on the source
  // if no precomputed expected file exists.
  final handDir = Directory('../../tests/conformance');
  final genDir = Directory('../../tests/fixtures/dart/_generated');

  final handFiles = handDir.existsSync()
      ? (handDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.ball.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  final genFiles = genDir.existsSync()
      ? (genDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.ball.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  group('conformance (hand-written IR)', () {
    for (final testFile in handFiles) {
      final name = testFile.uri.pathSegments.last.replaceAll('.ball.json', '');
      final expectedFile = File(
        testFile.path.replaceAll('.ball.json', '.expected_output.txt'),
      );
      if (!expectedFile.existsSync()) continue;

      test(name, () async {
        final jsonMap =
            jsonDecode(testFile.readAsStringSync()) as Map<String, dynamic>;
        final program = Program()
          ..mergeFromProto3Json(jsonMap, ignoreUnknownFields: true);

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

  // The generated directory is populated when the cross-language test
  // runs first. If it's empty (tests run in isolation, or a fresh
  // checkout), skip — the cross-language test owns the ground-truth.
  group('conformance (encoder-generated IR)', () {
    for (final testFile in genFiles) {
      final name = testFile.uri.pathSegments.last.replaceAll('.ball.json', '');
      final sourceFile = File(
        '../../tests/fixtures/dart/$name.dart',
      );
      if (!sourceFile.existsSync()) continue;

      test(name, () async {
        final jsonMap =
            jsonDecode(testFile.readAsStringSync()) as Map<String, dynamic>;
        final program = Program()
          ..mergeFromProto3Json(jsonMap, ignoreUnknownFields: true);

        final lines = <String>[];
        await BallEngine(program, stdout: lines.add).run();
        final engineOut = lines.join('\n').trimRight();

        // Compare against `dart run` on the original source.
        final r = Process.runSync(
          Platform.resolvedExecutable,
          ['run', sourceFile.absolute.path],
          stdoutEncoding: utf8,
        );
        final dartOut = (r.stdout as String)
            .replaceAll('\r\n', '\n')
            .trimRight();
        expect(engineOut, equals(dartOut));
      });
    }
  });
}
