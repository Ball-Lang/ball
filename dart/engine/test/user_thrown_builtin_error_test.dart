/// What a USER-THROWN built-in Dart error READS AS on the reference engine
/// (issue #658).
///
/// **The bug.** `engine_std.dart`'s `to_string` had ONE arm for every
/// `__type__` ending in `Exception`/`Error`: return the `message` field. That is
/// right for a user's own exception class (Ball has no `Instance of '…'` form to
/// fall back to) and wrong for the handful of DART BUILT-IN errors a program can
/// construct itself, whose `toString()` prefixes the message —
/// `StateError('boom')` reads `Bad state: boom`, not `boom`. So the reference
/// engine, the implementation every self-hosted engine is COMPILED FROM, was not
/// one of the targets that matched real Dart.
///
/// **Why nothing caught it.** `463`/`464` print hardcoded literals or
/// `e.message`; `465` and `467` print the caught value but only for a
/// RUNTIME-raised error, whose payload already carries the canonical
/// `toString()` string. A literal `throw StateError('boom')` had never been in a
/// value position anywhere in the corpus. The cross-target guard is conformance
/// fixture `473_caught_user_thrown_builtin_error` (which gates every engine and
/// every compiled target in the matrix); this file is the reference-engine half,
/// and it adds the two things a fixture cannot state — that `.message` survives
/// UNPREFIXED alongside the prefixed `'$e'`, and that the table stays CLOSED.
///
/// Every expectation below is Dart's own, measured against the SDK (3.12.0).
@TestOn('vm')
library;

import 'package:ball_encoder/encoder.dart' show DartEncoder;
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Encode a Dart source and run it on the reference engine, capturing stdout.
Future<List<String>> _run(String source) async {
  final program = DartEncoder().encode(source);
  final lines = <String>[];
  await BallEngine(program, stdout: lines.add).run();
  return lines;
}

/// A `main` that throws `expr`, catches it untyped, and prints `'$e'`.
String _untypedCatch(String expr) =>
    '''
void main() {
  try {
    throw $expr;
  } catch (e) {
    print('\$e');
  }
}
''';

void main() {
  group('a user-thrown built-in Dart error stringifies as Dart toString()', () {
    // name -> (constructor expression, the string Dart's toString() produces).
    const cases = <String, List<String>>{
      'StateError': ["StateError('boom')", 'Bad state: boom'],
      'FormatException': ["FormatException('bad')", 'FormatException: bad'],
      'RangeError': ["RangeError('oops')", 'RangeError: oops'],
      'ArgumentError': ["ArgumentError('nope')", 'Invalid argument(s): nope'],
    };

    for (final entry in cases.entries) {
      test('${entry.key} — untyped catch', () async {
        expect(await _run(_untypedCatch(entry.value[0])), [entry.value[1]]);
      });
    }

    test('a typed `on T catch` binds the same value', () async {
      expect(
        await _run('''
void main() {
  try {
    throw ArgumentError('nope');
  } on ArgumentError catch (e) {
    print('\$e');
  }
}
'''),
        ['Invalid argument(s): nope'],
      );
    });

    // `.message` is the OTHER observable, and it is a DIFFERENT string: the raw
    // constructor argument, never the prefixed form. Conformance `464` reads it,
    // so a "fix" that rewrote the stored field to `Bad state: boom` would pass
    // the `'$e'` half above and silently break that one.
    test('`.message` stays the raw constructor argument', () async {
      expect(
        await _run('''
void main() {
  try {
    throw StateError('boom');
  } on StateError catch (e) {
    print('\$e');
    print(e.message);
  }
}
'''),
        ['Bad state: boom', 'boom'],
      );
    });
  });

  // The table is CLOSED over Dart's own built-in names. A user class is not a
  // Dart error just because its name ends in `Error` and it carries a `message`
  // field — widening the rule to "any Error-suffixed type" would have printed
  // `ValidationError: not a dart error` for the program below, changing the
  // observable output of every program that declares its own exception class.
  test('a user class named like an error keeps its own rendering', () async {
    expect(
      await _run('''
class ValidationError {
  final String message;
  ValidationError(this.message);
}

void main() {
  try {
    throw ValidationError('not a dart error');
  } catch (e) {
    print('\$e');
  }
}
'''),
      ['not a dart error'],
    );
  });
}
