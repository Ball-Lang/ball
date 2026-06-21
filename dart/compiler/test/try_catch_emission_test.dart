/// Round-trip tests for the compiler's try/catch lowering (`_generateTry`):
/// the "tag catch" path (a catch on a user-thrown type, dispatched via
/// `e['__type']`) including stack-trace aliasing, the catch-all that mixes a
/// tag catch with an untyped fallback (and its stack alias), and a bare
/// rethrow when only tag catches are present.
///
/// These shapes are produced by the Dart encoder for `on UserType catch`, so a
/// round-trip is the most faithful way to drive them.
@TestOn('vm')
library;

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

String _flat(String source) => DartCompiler(
  DartEncoder().encode(source),
  noFormat: true,
).compile().replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('tag-catch dispatch (user-thrown type)', () {
    test('tag catch with stack trace + untyped fallback with stack', () {
      final out = _flat('''
class MyError {}
void main() {
  try {
    throw MyError();
  } on MyError catch (e, st) {
    print(e.toString());
    print(st.toString());
  } catch (e2, st2) {
    print(e2.toString());
    print(st2.toString());
  }
}
''');
      // A single catch-all binds the catch-level stack name.
      expect(out, contains('catch (__ball_e, __ball_st)'));
      // Tag dispatch on the Ball `__type` discriminator.
      expect(
        out,
        contains("__ball_e is Map && __ball_e['__type'] == 'MyError'"),
      );
      // Per-branch stack aliases for both the tag and untyped catches.
      expect(out, contains('final st = __ball_st;'));
      expect(out, contains('final st2 = __ball_st;'));
      // Untyped fallback after the tag branch.
      expect(out, contains('else {'));
      expect(out, contains('final dynamic e2 = __ball_e;'));
    });

    test('tag catch only (no untyped) rethrows unmatched exceptions', () {
      final out = _flat('''
class MyError {}
void main() {
  try {
    throw MyError();
  } on MyError catch (e) {
    print(e.toString());
  }
}
''');
      expect(out, contains("__ball_e['__type'] == 'MyError'"));
      // No untyped fallback ⇒ rethrow so other exceptions propagate.
      expect(out, contains('else { rethrow; }'));
    });

    test('builtin Dart exception keeps a real `on T catch` clause', () {
      final out = _flat('''
void main() {
  try {
    throw FormatException('x');
  } on FormatException catch (e) {
    print(e.toString());
  }
}
''');
      expect(out, contains('on FormatException catch (e)'));
    });
  });
}
