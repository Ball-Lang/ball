/// In-process conformance round-trip: encoder + engine fidelity over the
/// WHOLE corpus.
///
///   tests/conformance/src/NN_name.dart
///       → [DartEncoder]  (the package under test)
///       → [BallEngine]   (in-process, no subprocess)
///       → captured stdout  ==  NN_name.expected_output.txt (golden)
///
/// This is the same source-of-truth path that `generate_conformance.dart`
/// uses to PRODUCE each `NN_name.ball.json`, so every fixture with a golden
/// must reproduce it. Unlike the engine conformance suite (which loads the
/// *already-encoded* `.ball.json`), this drives the **encoder** on every one
/// of the corpus programs — any divergence means the encoder dropped or
/// mis-encoded semantics the engine would otherwise reproduce.
///
/// Deliberately NOT tagged `slow`: it spawns no child processes, so it runs
/// in the normal suite and its coverage of the encoder/engine/std builders is
/// counted by the coverage ratchet (epic #59 / #61).
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

String _norm(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

/// Locates `tests/conformance/` by walking up from the CWD to the repo root,
/// so the suite runs identically from `dart/encoder/`, the repo root, or via
/// the workspace runner.
Directory _findConformanceDir() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory('${dir.path}/tests/conformance');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'could not locate tests/conformance walking up from '
        '${Directory.current.absolute.path}',
      );
    }
    dir = parent;
  }
}

/// One corpus entry: a Dart source fixture paired with its golden output.
typedef _Fixture = ({String name, File source, String expected});

/// Discovers every `src/*.dart` fixture that has a sibling golden. Fixtures
/// without a golden (none today) are skipped; carve-out `.ball.json` programs
/// that have no `src/` sibling are intentionally out of scope here.
List<_Fixture> _discover(Directory conformanceDir) {
  final srcDir = Directory('${conformanceDir.path}/src');
  if (!srcDir.existsSync()) {
    throw StateError('missing ${srcDir.path}');
  }
  final fixtures = <_Fixture>[];
  final files =
      srcDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final name = f.uri.pathSegments.last.replaceAll('.dart', '');
    final golden = File('${conformanceDir.path}/$name.expected_output.txt');
    if (!golden.existsSync()) continue;
    fixtures.add((
      name: name,
      source: f,
      expected: _norm(golden.readAsStringSync()),
    ));
  }
  return fixtures;
}

Future<String> _runViaEngine(String source) async {
  final program = DartEncoder().encode(source);
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add);
  await engine.run();
  return _norm(lines.join('\n'));
}

void main() {
  final conformanceDir = _findConformanceDir();
  final fixtures = _discover(conformanceDir);

  group('in-process round-trip: src → encoder → engine ≡ golden', () {
    // Guard against the corpus silently vanishing (a glob/path regression
    // must fail loudly, not pass vacuously).
    test('corpus discovered', () {
      expect(
        fixtures,
        isNotEmpty,
        reason: 'no src fixtures with goldens under ${conformanceDir.path}/src',
      );
    });

    for (final f in fixtures) {
      test(f.name, () async {
        final actual = await _runViaEngine(f.source.readAsStringSync());
        expect(
          actual,
          equals(f.expected),
          reason:
              'encoder/engine output diverged from golden for ${f.name}\n'
              '--- expected (golden) ---\n${f.expected}\n'
              '--- actual (src→encode→engine) ---\n$actual',
        );
      });
    }
  });
}
