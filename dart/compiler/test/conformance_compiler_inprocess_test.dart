/// In-process COMPILER round-trip: exercises the Dart compiler over the WHOLE
/// corpus and verifies it emits semantically-faithful Dart — without spawning a
/// single `dart run`.
///
///   tests/conformance/src/NN_name.dart
///       → DartEncoder   → Ball
///       → DartCompiler  → Dart source   (the compiler under test)
///       → DartEncoder   → Ball'         (re-read the compiled Dart)
///       → BallEngine    → stdout  ==  NN_name.expected_output.txt (golden)
///
/// Re-encoding + running the compiled Dart in-process is the same fidelity
/// check the `slow` harness performs with `dart run`, but with no subprocess —
/// so it runs in the normal suite (a real compiler-fidelity gate) and its
/// coverage of the compiler counts toward the ratchet (epic #59 / #61).
///
/// A failing leg here is a compiler (or encoder-of-generated-code) bug, never a
/// tolerated baseline. The two current skips are tracked, reproducing bugs —
/// remove each skip when its issue is fixed:
///   - 104_getter_setter          → #95 (re-encoded field ref resolves to the
///                                   object Map)
///   - 229_closure_loop_var_…     → #69 (C-style `for(var i)` closure capture
///                                   shares the loop var; also the Dart compiler)
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

String _norm(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

/// Known-failing fixtures → the issue tracking the bug. A skip here is honest
/// (the leg reproduces a real defect) and shrinks as bugs are fixed.
const _skips = <String, String>{
  '104_getter_setter': 'encoder round-trip bug — see #95',
  '229_closure_loop_var_semantics': 'closure loop-var capture — see #69',
};

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

typedef _Fixture = ({String name, File source, String expected});

List<_Fixture> _discover(Directory conformanceDir) {
  final srcDir = Directory('${conformanceDir.path}/src');
  if (!srcDir.existsSync()) throw StateError('missing ${srcDir.path}');
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

Future<String> _roundTrip(String source) async {
  final program = DartEncoder().encode(source);
  final dartSource = DartCompiler(program).compile();
  final reencoded = DartEncoder().encode(dartSource);
  final lines = <String>[];
  final engine = BallEngine(reencoded, stdout: lines.add);
  await engine.run();
  return _norm(lines.join('\n'));
}

void main() {
  final conformanceDir = _findConformanceDir();
  final fixtures = _discover(conformanceDir);

  group('compiler round-trip: src → encode → COMPILE → encode → engine ≡ golden',
      () {
    test('corpus discovered', () {
      expect(
        fixtures,
        isNotEmpty,
        reason: 'no src fixtures with goldens under ${conformanceDir.path}/src',
      );
    });

    for (final f in fixtures) {
      test(
        f.name,
        () async {
          final actual = await _roundTrip(f.source.readAsStringSync());
          expect(
            actual,
            equals(f.expected),
            reason:
                'compiler round-trip diverged from golden for ${f.name}\n'
                '--- expected (golden) ---\n${f.expected}\n'
                '--- actual (encode→compile→encode→engine) ---\n$actual',
          );
        },
        skip: _skips[f.name],
      );
    }
  });
}
