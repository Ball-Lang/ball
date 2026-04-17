/// Regression tests for specific round-trip gaps identified during
/// pub-package validation (pool, matcher, args, shelf, etc.).
///
/// Each test encodes a small Dart snippet, recompiles it, and asserts
/// that the emitted Dart source contains the feature that was
/// previously being dropped. These focus on the COMPILER's emission —
/// the engine's ability to execute the output is covered separately.
@TestOn('vm')
library;

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

String _roundTrip(String source) {
  final program = DartEncoder().encode(source);
  return DartCompiler(program, noFormat: true).compile();
}

void main() {
  group('round-trip compiler gaps', () {
    test('catch (e, stack) preserves both bindings', () {
      final out = _roundTrip('''
void main() {
  try {
    throw 'boom';
  } catch (e, stack) {
    print(e.toString());
    print(stack.toString());
  }
}
''');
      // The untyped catch must expose the stack-trace variable so
      // references like `stack` in the body resolve.
      expect(out, contains('catch (__ball_e, stack)'));
      expect(out, contains('final e = __ball_e;'));
    });

    test('typed catch on Exception keeps stack variable', () {
      final out = _roundTrip('''
void main() {
  try {
    throw Exception('x');
  } on Exception catch (err, st) {
    print(err.toString());
    print(st.toString());
  }
}
''');
      expect(out, contains('on Exception catch (err, st)'));
    });

    test('spread in list literal survives round-trip', () {
      final out = _roundTrip('''
void main() {
  var a = [1, 2];
  var b = [0, ...a, 3];
  print(b.toString());
}
''');
      expect(out, contains('...a'));
    });

    test('null-aware spread in list literal survives round-trip', () {
      final out = _roundTrip('''
void main() {
  List<int>? a;
  var b = [0, ...?a, 3];
  print(b.toString());
}
''');
      expect(out, contains('...?a'));
    });

    test('spread in set literal survives round-trip', () {
      final out = _roundTrip('''
void main() {
  var a = <int>{1, 2};
  var b = <int>{0, ...a, 3};
  print(b.toString());
}
''');
      expect(out, contains('...a'));
    });

    test('spread in map literal survives round-trip', () {
      final out = _roundTrip('''
void main() {
  var a = {'a': 1};
  var b = {'z': 0, ...a};
  print(b.toString());
}
''');
      expect(out, contains('...a'));
    });

    test('named parameter defaults survive round-trip', () {
      final out = _roundTrip('''
void foo({int x = 5, String? y, bool b = true}) {
  print(x.toString());
  print(y.toString());
  print(b.toString());
}
void main() { foo(); }
''');
      expect(out, contains('int x = 5'));
      expect(out, contains('bool b = true'));
    });

    test('optional positional defaults survive round-trip', () {
      final out = _roundTrip('''
String foo([int x = 5, String y = 'hi']) => '\$x/\$y';
void main() { print(foo()); }
''');
      expect(out, contains('int x = 5'));
      expect(out, contains("String y = 'hi'"));
    });

    test('constructor this-parameter defaults survive round-trip', () {
      final out = _roundTrip('''
class W {
  final int width;
  final String color;
  W({this.width = 100, this.color = 'red'});
}
void main() { W(); }
''');
      expect(out, contains('this.width = 100'));
      expect(out, contains("this.color = 'red'"));
    });
  });
}
