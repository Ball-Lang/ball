import 'dart:math' show max, min;

// ============================================================
// Top-level variables
// ============================================================

const pi = 3.14159;
final greeting = 'Hello';
var globalCounter = 0;
late String lateInit;

// ============================================================
// Typedef
// ============================================================

typedef IntTransform = int Function(int);
typedef StringMapper<T> = String Function(T);

// ============================================================
// Enum (simple)
// ============================================================

enum Color { red, green, blue }

// ============================================================
// Enum with members
// ============================================================

enum Planet {
  mercury(3.7),
  venus(8.87),
  earth(9.81);

  final double gravity;
  const Planet(this.gravity);

  String describe() => '$name: gravity=$gravity';
}

// ============================================================
// Abstract class
// ============================================================

abstract class Shape {
  double area();
  String describe() => 'Shape(area=${area()})';
}

// ============================================================
// Class with inheritance
// ============================================================

class Circle extends Shape {
  final double radius;
  Circle(this.radius);

  @override
  double area() => pi * radius * radius;

  @override
  String describe() => 'Circle(r=$radius, a=${area()})';
}

class Rectangle extends Shape {
  final double width;
  final double height;
  Rectangle(this.width, this.height);

  @override
  double area() => width * height;
}

// ============================================================
// Class with named constructor & initializer list
// ============================================================

class Point {
  final double x;
  final double y;
  Point(this.x, this.y);
  Point.origin() : x = 0, y = 0;
  Point.fromList(List<double> coords)
      : x = coords[0],
        y = coords[1];

  double distanceTo(Point other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return (dx * dx + dy * dy);
  }

  @override
  String toString() => 'Point($x, $y)';
}

// ============================================================
// Factory constructor
// ============================================================

class Logger {
  final String name;
  static final Map<String, Logger> _cache = {};

  Logger._internal(this.name);

  factory Logger(String name) {
    return _cache.putIfAbsent(name, () => Logger._internal(name));
  }

  void log(String message) {
    print('[$name] $message');
  }
}

// ============================================================
// Mixin
// ============================================================

mixin Describable {
  String describe();
  void printDescription() {
    print(describe());
  }
}

// ============================================================
// Class using mixin
// ============================================================

class Animal with Describable {
  final String species;
  Animal(this.species);

  @override
  String describe() => 'Animal: $species';
}

// ============================================================
// Extension
// ============================================================

extension StringUtils on String {
  String reversed() {
    final chars = split('');
    final buffer = StringBuffer();
    for (var i = chars.length - 1; i >= 0; i--) {
      buffer.write(chars[i]);
    }
    return buffer.toString();
  }

  bool get isPalindrome => this == reversed();
}

// ============================================================
// Generics
// ============================================================

T identity<T>(T value) => value;

class Pair<A, B> {
  final A first;
  final B second;
  Pair(this.first, this.second);

  @override
  String toString() => 'Pair($first, $second)';
}

// ============================================================
// Async/await
// ============================================================

Future<int> asyncAdd(int a, int b) async {
  return a + b;
}

Future<String> asyncGreet(String name) async {
  final result = await asyncAdd(1, 2);
  return 'Hello $name, result=$result';
}

// ============================================================
// Null safety
// ============================================================

String? maybeNull(bool flag) => flag ? 'value' : null;

String withDefault(String? input) => input ?? 'default';

int safeLength(String? s) => s?.length ?? 0;

// ============================================================
// Switch expression
// ============================================================

String describeNumber(int n) => switch (n) {
  0 => 'zero',
  1 => 'one',
  2 => 'two',
  _ => 'other: $n',
};

// ============================================================
// Try/catch/finally
// ============================================================

String safeDivide(int a, int b) {
  try {
    if (b == 0) {
      throw ArgumentError('Division by zero');
    }
    return (a ~/ b).toString();
  } on ArgumentError catch (e) {
    return 'error: $e';
  } catch (e) {
    return 'unknown: $e';
  } finally {
    globalCounter = globalCounter + 1;
  }
}

// ============================================================
// For-in loop
// ============================================================

int sumList(List<int> items) {
  var sum = 0;
  for (final item in items) {
    sum = sum + item;
  }
  return sum;
}

// ============================================================
// Do-while loop
// ============================================================

int doWhileCount(int target) {
  var i = 0;
  do {
    i = i + 1;
  } while (i < target);
  return i;
}

// ============================================================
// Assert
// ============================================================

int assertPositive(int n) {
  assert(n > 0, 'must be positive');
  return n;
}

// ============================================================
// Type tests
// ============================================================

String typeTest(Object obj) {
  if (obj is int) {
    return 'int: ${obj.toString()}';
  } else if (obj is String) {
    return 'string: $obj';
  } else {
    return 'other';
  }
}

// ============================================================
// Cascade
// ============================================================

String cascadeTest() {
  final sb = StringBuffer()..write('a')..write('b')..write('c');
  return sb.toString();
}

// ============================================================
// Collection literals
// ============================================================

List<int> doubleList(List<int> items) => [for (final item in items) item * 2];

Map<String, int> makeMap() => {'x': 10, 'y': 20, 'z': 30};

Set<int> makeSet() => {1, 2, 3, 4, 5};

// ============================================================
// Spread operator
// ============================================================

List<int> mergeSort(List<int> a, List<int> b) => [...a, ...b];

// ============================================================
// Collection if/for
// ============================================================

List<String> conditionalList(bool includeExtra) => [
  'always',
  if (includeExtra) 'extra',
];

// ============================================================
// Compound assignment
// ============================================================

int compoundOps(int x) {
  x += 10;
  x -= 3;
  x *= 2;
  return x;
}

// ============================================================
// Index access
// ============================================================

int getAt(List<int> items, int idx) => items[idx];

// ============================================================
// Closures / Lambdas
// ============================================================

IntTransform makeAdder(int n) {
  return (int x) => x + n;
}

List<int> applyToAll(List<int> items, IntTransform fn) {
  final result = <int>[];
  for (final item in items) {
    result.add(fn(item));
  }
  return result;
}

// ============================================================
// Local functions
// ============================================================

int withHelper(int n) {
  int helper(int x) {
    return x * x;
  }
  return helper(n) + helper(n + 1);
}

// ============================================================
// Labeled break
// ============================================================

int labeledBreak() {
  var result = 0;
  outer:
  for (var i = 0; i < 5; i++) {
    for (var j = 0; j < 5; j++) {
      if (i + j > 4) {
        break outer;
      }
      result = result + 1;
    }
  }
  return result;
}

// ============================================================
// main
// ============================================================

void main() async {
  // Top-level variables
  print('pi=$pi');
  print(greeting);
  print('counter=$globalCounter');
  lateInit = 'initialized';
  print(lateInit);

  // Enums
  print(Color.red);
  print(Color.values.length.toString());
  print(Planet.earth.describe());

  // Classes and inheritance
  final circle = Circle(5.0);
  print(circle.describe());
  final rect = Rectangle(3.0, 4.0);
  print(rect.area().toString());

  // Constructors
  final p1 = Point(3.0, 4.0);
  final p2 = Point.origin();
  print(p1.toString());
  print(p2.toString());
  print(p1.distanceTo(p2).toString());

  // Factory
  final log1 = Logger('test');
  log1.log('factory works');

  // Mixin
  final animal = Animal('Cat');
  print(animal.describe());

  // Extension
  print('hello'.reversed());
  print('racecar'.isPalindrome.toString());

  // Generics
  print(identity(42).toString());
  print(Pair('a', 1).toString());

  // Async
  final asyncResult = await asyncGreet('World');
  print(asyncResult);

  // Null safety
  print(maybeNull(true).toString());
  print(withDefault(null));
  print(safeLength('hello').toString());

  // Switch expression
  print(describeNumber(0));
  print(describeNumber(42));

  // Try/catch
  print(safeDivide(10, 3));
  print(safeDivide(10, 0));

  // For-in
  print(sumList([1, 2, 3, 4, 5]).toString());

  // Do-while
  print(doWhileCount(3).toString());

  // Assert
  print(assertPositive(5).toString());

  // Type tests
  print(typeTest(42));
  print(typeTest('hello'));

  // Cascade
  print(cascadeTest());

  // Collections
  print(doubleList([1, 2, 3]).toString());
  print(makeMap().toString());
  print(makeSet().toString());
  print(mergeSort([1, 2], [3, 4]).toString());
  print(conditionalList(true).toString());
  print(conditionalList(false).toString());

  // Compound assignment
  print(compoundOps(5).toString());

  // Index
  print(getAt([10, 20, 30], 1).toString());

  // Closures
  final add5 = makeAdder(5);
  print(add5(10).toString());
  print(applyToAll([1, 2, 3], add5).toString());

  // Local functions
  print(withHelper(3).toString());

  // Labeled break
  print(labeledBreak().toString());

  // Math import
  print(max(10, 20).toString());
  print(min(3, 7).toString());
}
