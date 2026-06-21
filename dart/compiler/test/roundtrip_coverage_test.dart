/// Round-trip compiler coverage tests.
///
/// Each test encodes a Dart snippet to Ball then recompiles it, asserting the
/// emitted Dart contains the expected construct. Unlike the IR-level base-call
/// tests, these drive the high-level emission paths — classes, enums, mixins,
/// extensions, generics, const constructors, all control-flow statements, and
/// generator/async functions — that are most concisely reached through real
/// Dart source.
@TestOn('vm')
library;

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

String _rt(String source) {
  final program = DartEncoder().encode(source);
  return DartCompiler(program, noFormat: true).compile();
}

/// Recompile and collapse whitespace, for layout-insensitive assertions.
String _flat(String source) => _rt(source).replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('classes', () {
    test('class with field, constructor, method, getter', () {
      final out = _flat('''
class Counter {
  int value;
  Counter(this.value);
  int get doubled => value * 2;
  void inc() { value = value + 1; }
}
void main() { final c = Counter(1); c.inc(); print(c.doubled.toString()); }
''');
      expect(out, contains('class Counter'));
      expect(out, contains('int value'));
      expect(out, contains('get doubled'));
      expect(out, contains('inc('));
    });

    test('named constructor + factory + final fields', () {
      final out = _flat('''
class Point {
  final int x;
  final int y;
  Point(this.x, this.y);
  Point.origin() : x = 0, y = 0;
  factory Point.diagonal(int n) => Point(n, n);
}
void main() { Point.origin(); Point.diagonal(3); }
''');
      expect(out, contains('class Point'));
      expect(out, contains('Point.origin'));
      expect(out, contains('factory Point.diagonal'));
    });

    test('inheritance: extends + super call + override', () {
      final out = _flat('''
class Animal {
  String speak() => 'generic';
}
class Dog extends Animal {
  @override
  String speak() => 'woof';
}
void main() { print(Dog().speak()); }
''');
      expect(out, contains('class Dog extends Animal'));
      expect(out, contains('speak'));
    });

    test('abstract class + implements', () {
      final out = _flat('''
abstract class Shape {
  double area();
}
class Square implements Shape {
  final double side;
  Square(this.side);
  @override
  double area() => side * side;
}
void main() { print(Square(2.0).area().toString()); }
''');
      expect(out, contains('abstract class Shape'));
      expect(out, contains('class Square implements Shape'));
    });

    test('static fields and methods', () {
      final out = _flat('''
class MathUtil {
  static const pi = 3.14;
  static int square(int n) => n * n;
}
void main() { print(MathUtil.square(3).toString()); }
''');
      expect(out, contains('class MathUtil'));
      expect(out, contains('static'));
      expect(out, contains('square'));
    });

    test('generic class', () {
      final out = _flat('''
class Box<T> {
  final T item;
  Box(this.item);
  T get value => item;
}
void main() { final b = Box<int>(5); print(b.value.toString()); }
''');
      expect(out, contains('class Box<T>'));
    });
  });

  group('enums', () {
    test('simple enum', () {
      final out = _flat('''
enum Color { red, green, blue }
void main() { print(Color.red.toString()); }
''');
      expect(out, contains('enum Color'));
      expect(out, contains('red'));
    });

    test('enhanced enum with fields and methods', () {
      final out = _flat('''
enum Planet {
  earth(9.8),
  mars(3.7);
  final double gravity;
  const Planet(this.gravity);
  double weight(double mass) => mass * gravity;
}
void main() { print(Planet.earth.weight(10).toString()); }
''');
      expect(out, contains('enum Planet'));
      expect(out, contains('gravity'));
    });
  });

  group('mixins and extensions', () {
    test('mixin + with', () {
      final out = _flat('''
mixin Walker {
  String walk() => 'walking';
}
class Person with Walker {}
void main() { print(Person().walk()); }
''');
      expect(out, contains('mixin Walker'));
      expect(out, contains('with Walker'));
    });

    test('extension method', () {
      final out = _flat('''
extension IntDouble on int {
  int get doubled => this * 2;
}
void main() { print(5.doubled.toString()); }
''');
      expect(out, contains('extension IntDouble on int'));
    });
  });

  group('control flow statements', () {
    test('while loop', () {
      final out = _flat('''
void main() {
  var i = 0;
  while (i < 3) { print(i.toString()); i = i + 1; }
}
''');
      expect(out, contains('while ('));
    });

    test('do-while loop', () {
      final out = _flat('''
void main() {
  var i = 0;
  do { print(i.toString()); i = i + 1; } while (i < 3);
}
''');
      expect(out, contains('do {'));
      expect(out, contains('} while ('));
    });

    test('for-in loop', () {
      final out = _flat('''
void main() {
  for (final x in [1, 2, 3]) { print(x.toString()); }
}
''');
      expect(out, contains('for (final x in'));
    });

    test('c-style for loop', () {
      final out = _flat('''
void main() {
  for (var i = 0; i < 3; i++) { print(i.toString()); }
}
''');
      expect(out, contains('for ('));
    });

    test('switch statement with cases and default', () {
      final out = _flat('''
void main() {
  var x = 2;
  switch (x) {
    case 1: print('one'); break;
    case 2: print('two'); break;
    default: print('other');
  }
}
''');
      expect(out, contains('switch ('));
      expect(out, contains('case'));
      expect(out, contains('default'));
    });

    test('try/catch/finally with typed and untyped catch', () {
      final out = _flat('''
void main() {
  try {
    throw Exception('boom');
  } on FormatException catch (e) {
    print(e.toString());
  } catch (e, st) {
    print(e.toString());
    print(st.toString());
  } finally {
    print('done');
  }
}
''');
      expect(out, contains('try {'));
      expect(out, contains('on FormatException'));
      expect(out, contains('finally'));
    });

    test('if/else if/else chain', () {
      final out = _flat('''
String grade(int n) {
  if (n >= 90) { return 'A'; }
  else if (n >= 80) { return 'B'; }
  else { return 'C'; }
}
void main() { print(grade(85)); }
''');
      expect(out, contains('if ('));
      expect(out, contains('else'));
    });

    test('break and continue with labels', () {
      final out = _flat('''
void main() {
  outer:
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      if (j == 1) continue outer;
      if (i == 2) break outer;
      print('\$i,\$j');
    }
  }
}
''');
      expect(out, contains('continue outer'));
      expect(out, contains('break outer'));
    });

    test('assert statement', () {
      final out = _flat('''
void main() {
  var x = 5;
  assert(x > 0, 'must be positive');
  print(x.toString());
}
''');
      expect(out, contains('assert('));
    });
  });

  group('generators and async', () {
    test('sync* generator with yield', () {
      final out = _flat('''
Iterable<int> gen() sync* {
  yield 1;
  yield 2;
}
void main() { print(gen().toList().toString()); }
''');
      expect(out, contains('sync*'));
      expect(out, contains('yield'));
    });

    test('async* generator with yield*', () {
      final out = _flat('''
Stream<int> gen() async* {
  yield 1;
  yield* Stream.fromIterable([2, 3]);
}
void main() { gen(); }
''');
      expect(out, contains('async*'));
      expect(out, contains('yield*'));
    });

    test('async function with await', () {
      final out = _flat('''
Future<int> fetch() async {
  await Future.delayed(Duration.zero);
  return 42;
}
void main() async { print((await fetch()).toString()); }
''');
      expect(out, contains('async'));
      expect(out, contains('await'));
    });
  });

  group('expressions and literals', () {
    test('string interpolation (lowered to concatenation)', () {
      final out = _flat(r'''
void main() {
  var name = 'world';
  print('hello $name and ${name.length}');
}
''');
      // The encoder lowers interpolation to `+` concatenation with toString().
      expect(out, contains("'hello ' + name.toString()"));
    });

    test('control characters in string literal are escaped', () {
      final out = _rt(r'''
void main() {
  print('tab\there\nnewline\r\\backslash');
}
''');
      expect(out, contains(r'\t'));
      expect(out, contains(r'\n'));
      expect(out, contains(r'\\'));
    });

    test('ternary and null-aware operators', () {
      final out = _flat('''
String describe(int? x) => x == null ? 'none' : x.toString();
void main() {
  int? a;
  print(describe(a));
  print((a ?? 0).toString());
}
''');
      expect(out, contains('?'));
      expect(out, contains('??'));
    });

    test('collection literals: list, set, map', () {
      final out = _flat('''
void main() {
  var l = [1, 2, 3];
  var s = <int>{1, 2};
  var m = {'a': 1, 'b': 2};
  print(l.length.toString());
  print(s.length.toString());
  print(m.length.toString());
}
''');
      expect(out, contains('[1, 2, 3'));
      expect(out, contains('<int>{1, 2}'));
      expect(out, contains("{'a': 1, 'b': 2}"));
    });

    test('record literal and destructuring', () {
      final out = _flat('''
(int, int) pair() => (1, 2);
void main() {
  var (a, b) = pair();
  print((a + b).toString());
}
''');
      expect(out, contains('('));
    });

    test('cascade notation (lowered to block IIFE)', () {
      final out = _flat('''
void main() {
  var sb = StringBuffer()
    ..write('a')
    ..write('b');
  print(sb.toString());
}
''');
      // The Dart encoder lowers cascades to a `let __cascade_self__ = …` block
      // that re-applies each section and returns the receiver.
      expect(out, contains('__cascade_self__'));
      expect(out, contains(".write('a')"));
    });

    test('const constructor invocation', () {
      final out = _flat('''
class Vec {
  final int x;
  const Vec(this.x);
}
void main() {
  const v = Vec(5);
  print(v.x.toString());
}
''');
      expect(out, contains('Vec'));
    });

    test('typedef / function-type parameters', () {
      final out = _flat('''
int apply(int Function(int) f, int x) => f(x);
void main() {
  print(apply((n) => n * 2, 5).toString());
}
''');
      expect(out, contains('apply'));
    });
  });

  group('top-level declarations', () {
    test('top-level variables and getters', () {
      final out = _flat('''
const greeting = 'hello';
final answer = 42;
int get computed => answer * 2;
void main() {
  print(greeting);
  print(computed.toString());
}
''');
      expect(out, contains('greeting'));
      expect(out, contains('answer'));
    });
  });
}
