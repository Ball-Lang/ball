/// Self-test for the Tier A coverage-study harness (issue #493, slice 1).
///
/// A new gate must not repeat the blind spot it exists to close. The gap #493
/// documents is that every existing check is scoped to the project's own
/// single-file, `main`-shaped conformance fixtures, so real library code — no
/// entry point, declarations split across files — was never looked at. The
/// cheapest way for this harness to inherit that same blind spot would be to
/// SKIP such files (e.g. by reaching for `DartCompiler.compile()`, which needs
/// an entry point) and then report a flattering number over whatever is left.
///
/// This test therefore asserts, against the real pipeline:
///
///   1. every file of a synthetic two-file package shaped like the #491/#492
///      failure mode — cross-file class reference, no top-level `main` — is
///      SCORED, none silently skipped (this is what proves the load-bearing
///      per-module `compileModule` setting is still in place: `compile()`
///      cannot produce a verdict for a `main`-less file at all);
///   2. a straightforward file is reported `clean`, so the harness cannot pass
///      by calling everything dirty;
///   3. a real-code shape the pipeline does NOT survive is reported NOT clean
///      WITH a taxonomy reason, rather than skipped or silently passed;
///   4. the #494 Bug A shape — a user-defined zero-argument method whose name
///      collides with a std route (`split()`) — is clean, i.e. the harness
///      would have gone red on it before that fix and stays green after.
///
/// Run from the repo root:
///   dart run tools/coverage-study/test/rq1_study_self_test.dart
library;

import 'dart:io';

import '../rq1_study.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _passed++;
    stdout.writeln('PASS  $name');
  } else {
    _failed++;
    stdout.writeln('FAIL  $name${detail.isEmpty ? '' : ' — $detail'}');
  }
}

/// `b.dart` — a plain helper library. No `main`; nothing exotic.
const _helperSource = '''
class Helper {
  int twice(int value) {
    return value * 2;
  }
}
''';

/// `a.dart` — references `Helper` from the sibling file, so it cannot be
/// understood in isolation, and has no top-level `main`.
const _consumerSource = '''
import 'b.dart';

class Consumer {
  bool remember(Set<String> seen, String name) {
    return seen.add(name);
  }

  int doubled(int value) {
    return Helper().twice(value);
  }
}
''';

/// A real-code shape the pipeline does not currently survive: `await for` over
/// a Stream does not reach a second-generation fixpoint. Used as the harness's
/// negative control — it must be REPORTED, not skipped.
const _notSurvivingSource = '''
import 'dart:async';

class Summer {
  Future<int> total(Stream<int> values) async {
    var sum = 0;
    await for (final v in values) {
      sum += v;
    }
    return sum;
  }
}
''';

/// The #494 Bug A shape, distilled from dart-lang/async's
/// `lib/src/stream_splitter.dart`: a user-defined ZERO-argument method named
/// `split`, called through a lambda. Before the arity gate this encoded to
/// `std.string_split` with no `separator`, and the compiler emitted the literal
/// `/* invalid split() */` into an expression position — `compile-error` here.
const _arityCollisionSource = '''
class Splitter {
  final List<int> items;

  Splitter(this.items);

  List<int> split() {
    return items;
  }
}

class Fanout {
  List<List<int>> all(Splitter splitter, int count) {
    return List<List<int>>.generate(count, (_) => splitter.split());
  }
}
''';

void main() {
  final tempDir = Directory.systemTemp.createTempSync('rq1_self_test');
  try {
    File('${tempDir.path}/b.dart').writeAsStringSync(_helperSource);
    File('${tempDir.path}/a.dart').writeAsStringSync(_consumerSource);

    final results = studyDirectory('synthetic', tempDir);

    check(
      'both files of a main-less package are scored, none skipped',
      results.length == 2 && results.every((r) => r.scored),
      'got ${results.map((r) => '${r.file}(scored=${r.scored})').join(', ')}',
    );

    final consumer = results.where((r) => r.file == 'a.dart').toList();
    check(
      'the cross-file, main-less consumer file gets a real verdict',
      consumer.length == 1 && consumer.single.reason.isNotEmpty,
    );

    final helper = results.where((r) => r.file == 'b.dart').toList();
    check(
      'a straightforward main-less file IS reported clean',
      helper.length == 1 && helper.single.clean,
      helper.isEmpty ? 'not scored' : 'reason was "${helper.single.reason}"',
    );
  } finally {
    tempDir.deleteSync(recursive: true);
  }

  final notSurviving = studyFile(
    'synthetic',
    'stream.dart',
    _notSurvivingSource,
  );
  check(
    'a real-code shape the pipeline does not survive is scored and NOT clean',
    notSurviving.scored && !notSurviving.clean,
    'scored=${notSurviving.scored} clean=${notSurviving.clean} '
        'reason="${notSurviving.reason}"',
  );
  check(
    'that failure carries a taxonomy reason, not a bare verdict',
    notSurviving.reason.contains(':'),
    'reason was "${notSurviving.reason}"',
  );

  final arity = studyFile('synthetic', 'splitter.dart', _arityCollisionSource);
  check(
    'the #494 arity-collision shape survives the pipeline',
    arity.scored && arity.clean,
    'reason was "${arity.reason}"',
  );

  final total = _passed + _failed;
  stdout.writeln('Results: $_passed passed, $_failed failed, $total total');
  if (total < 1) {
    stderr.writeln('ERROR: the self-test asserted nothing.');
    exit(1);
  }
  if (_failed > 0) exit(1);
}
