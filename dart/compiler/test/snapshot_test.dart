/// Snapshot tests: pin the exact compiled Dart output for each fixture.
///
/// On first run (or when BALL_UPDATE_SNAPSHOTS=1) the test rewrites the
/// checked-in snapshot file under tests/snapshots/dart/. On subsequent
/// runs it diffs the compiler output against the snapshot and fails on
/// any drift.
///
/// Purpose: any compiler change that re-orders output, changes
/// whitespace, or restructures emission patterns shows up as a
/// reviewable diff in the snapshot file. Combined with the e2e tests
/// (which check runtime behavior), this gives us both "the compiled
/// source still runs" and "the compiled source didn't change shape"
/// — the latter is hard to catch any other way.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

void main() {
  final fixturesDir = Directory('../../tests/fixtures/dart');
  final snapshotDir = Directory('../../tests/snapshots/dart');
  if (!fixturesDir.existsSync()) return;
  if (!snapshotDir.existsSync()) snapshotDir.createSync(recursive: true);

  final updateMode = Platform.environment['BALL_UPDATE_SNAPSHOTS'] == '1';

  final fixtures = fixturesDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  group('snapshot: DartCompiler output', () {
    for (final fixture in fixtures) {
      final name = fixture.uri.pathSegments.last.replaceAll('.dart', '');
      test(name, () {
        final program = DartEncoder().encode(fixture.readAsStringSync());
        final actual = DartCompiler(program).compile();
        final snapshotFile = File('${snapshotDir.path}/$name.snapshot.dart');

        if (updateMode || !snapshotFile.existsSync()) {
          snapshotFile.writeAsStringSync(actual);
          // Skip the diff when rebuilding — first run establishes the
          // baseline, subsequent runs verify it.
          return;
        }

        final expected = snapshotFile.readAsStringSync();
        // Normalize CRLF to LF; checked-in files must diff consistently
        // regardless of line-ending strategy.
        String norm(String s) => s.replaceAll('\r\n', '\n');
        expect(
          norm(actual),
          equals(norm(expected)),
          reason:
              'DartCompiler output for $name changed. If intended, rerun '
              'with BALL_UPDATE_SNAPSHOTS=1 and review the diff.',
        );
      });
    }
  });
}
