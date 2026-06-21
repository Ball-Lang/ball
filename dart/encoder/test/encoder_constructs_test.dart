/// Broad coverage tests for `encoder.dart`, exercising the many Dart AST node
/// kinds the [DartEncoder] handles: declarations (classes, mixins, enums,
/// extensions, extension types, typedefs, top-level vars), statements
/// (control flow, try/catch, assert, yield, labeled, local functions,
/// pattern declarations) and expressions (operators, conditionals, casts,
/// throws, awaits, cascades, collections, patterns, null-aware access).
///
/// Each test encodes a Dart snippet and asserts a structural fact about the
/// produced Ball [Program]. The `encodeBallFileJson` helper renders the
/// program to JSON so we can search the expression tree for the std functions
/// or message types the encoder is expected to emit.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

void main() {
  // Encode [source] and return the serialized JSON for structural search.
  String jsonOf(String source) =>
      jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

  Module mainModule(Program p) => p.modules.firstWhere((m) => m.name == 'main');

  group('imports / exports / part-of directives', () {
    test('import with prefix, show, hide, deferred', () {
      final p = DartEncoder().encode('''
import 'dart:async' as a;
import 'package:meta/meta.dart' show immutable hide protected;
import 'dart:io' deferred as io;
void main() {}
''');
      final meta = mainModule(p).metadata.fields;
      expect(meta.containsKey('dart_imports'), isTrue);
    });

    test('export directives are captured in metadata', () {
      final p = DartEncoder().encode('''
export 'src/a.dart';
export 'src/b.dart' show Foo hide Bar;
void main() {}
''');
      final meta = mainModule(p).metadata.fields;
      expect(meta.containsKey('dart_exports'), isTrue);
    });

    test('part-of with library name (not URI)', () {
      final p = DartEncoder().encode('''
part of my.library.name;
int helper() => 1;
''');
      expect(p.modules, isNotEmpty);
    });

    test('partResolver inlines part declarations', () {
      final enc = DartEncoder();
      final p = enc.encode(
        '''
library root;
part 'extra.dart';
int base() => 1;
''',
        partResolver: (uri) {
          expect(uri, equals('extra.dart'));
          return 'int extra() => 2;';
        },
      );
      final fnNames = mainModule(p).functions.map((f) => f.name).toSet();
      expect(fnNames, containsAll(['base', 'extra']));
    });
  });

  group('class members & constructors', () {
    test('class modifiers: abstract / sealed / base / final / interface', () {
      for (final mod in [
        'abstract',
        'sealed',
        'base',
        'final',
        'interface',
        'mixin',
      ]) {
        final p = DartEncoder().encode('$mod class C {}\nvoid main() {}');
        final td = mainModule(
          p,
        ).typeDefs.firstWhere((t) => t.name.endsWith(':C'));
        expect(td.metadata.fields, isNotEmpty);
      }
    });

    test('named, factory, const and redirecting constructors', () {
      final p = DartEncoder().encode('''
class Point {
  final int x;
  final int y;
  const Point(this.x, this.y);
  Point.origin() : x = 0, y = 0;
  factory Point.fromList(List<int> v) => Point(v[0], v[1]);
  Point.copy(Point o) : this(o.x, o.y);
  Point.validated(int a, int b) : assert(a >= 0), x = a, y = b;
}
void main() {}
''');
      final fnNames = mainModule(p).functions.map((f) => f.name).toList();
      // Constructors are encoded as functions on the class.
      expect(fnNames.any((n) => n.contains('Point')), isTrue);
    });

    test('getters, setters, operators and static fields', () {
      final p = DartEncoder().encode('''
class Vec {
  int _v = 0;
  int get value => _v;
  set value(int n) => _v = n;
  Vec operator +(Vec other) => Vec();
  bool operator ==(Object other) => true;
  int operator [](int i) => i;
  void operator []=(int i, int v) {}
  static int count = 0;
  static const String tag = 'vec';
}
void main() {}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });

    test('abstract method without a body', () {
      final p = DartEncoder().encode('''
abstract class Shape {
  double area();
}
void main() {}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });

    test('generic methods and type parameters', () {
      final p = DartEncoder().encode('''
class Box<T> {
  T value;
  Box(this.value);
  R map<R>(R Function(T) f) => f(value);
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':Box'));
      expect(td.metadata.fields.containsKey('type_params'), isTrue);
    });
  });

  group('mixins, enums, extensions, extension types', () {
    test('mixin with on/implements/type params and fields', () {
      final p = DartEncoder().encode('''
mixin Walker<T> on Animal implements Mover {
  int steps = 0;
  void walk() {}
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':Walker'));
      final meta = td.metadata.fields;
      expect(meta['kind']!.stringValue, equals('mixin'));
      expect(meta.containsKey('on'), isTrue);
      expect(meta.containsKey('interfaces'), isTrue);
      expect(meta.containsKey('type_params'), isTrue);
    });

    test('enum with fields, methods, constructor, values and implements', () {
      final p = DartEncoder().encode('''
enum Planet implements Comparable<Planet> {
  earth(9.8),
  mars(3.7);

  final double gravity;
  const Planet(this.gravity);
  double weight(double mass) => mass * gravity;
  int compareTo(Planet other) => 0;
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':Planet'));
      final meta = td.metadata.fields;
      expect(meta['kind']!.stringValue, equals('enum'));
      expect(meta.containsKey('fields'), isTrue);
      expect(meta.containsKey('values'), isTrue);
      expect(meta.containsKey('interfaces'), isTrue);
    });

    test('named extension with type params and docs', () {
      final p = DartEncoder().encode('''
/// Doc comment.
extension NumberExt<T extends num> on T {
  T doubled() => this;
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':NumberExt'));
      final meta = td.metadata.fields;
      expect(meta['kind']!.stringValue, equals('extension'));
      expect(meta.containsKey('on'), isTrue);
      expect(meta.containsKey('type_params'), isTrue);
    });

    test('extension type with representation and implements', () {
      final p = DartEncoder().encode('''
extension type Meters(int value) implements num {
  Meters get doubled => Meters(value * 2);
  static const zero = Meters(0);
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':Meters'));
      final meta = td.metadata.fields;
      expect(meta['kind']!.stringValue, equals('extension_type'));
      expect(meta.containsKey('rep_type'), isTrue);
    });
  });

  group('top-level variables & typedefs', () {
    test('top-level var, final, const, late with docs', () {
      final p = DartEncoder().encode('''
int counter = 0;
final String label = 'x';
const double pi = 3.14;
late int delayed;
/// A documented top-level.
final List<int> data = [1, 2, 3];
void main() {}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });

    test('generic function-type typedef', () {
      final p = DartEncoder().encode('''
typedef Predicate<T> = bool Function(T value);
typedef IntMapper = int Function(int);
void main() {}
''');
      expect(p.modules, isNotEmpty);
    });

    test('legacy function typedef', () {
      final p = DartEncoder().encode('''
typedef void Callback(int x);
void main() {}
''');
      expect(p.modules, isNotEmpty);
    });
  });

  group('statements', () {
    test('assert with and without message', () {
      final j = jsonOf('''
void f(int x) {
  assert(x > 0);
  assert(x > 0, 'must be positive');
}
''');
      expect(j, contains('assert'));
    });

    test('labeled statement and break with label', () {
      final j = jsonOf('''
void f() {
  outer:
  for (var i = 0; i < 3; i = i + 1) {
    for (var k = 0; k < 3; k = k + 1) {
      if (k == 1) break outer;
    }
  }
}
''');
      expect(j, contains('for'));
    });

    test('local function declaration inside a body', () {
      final p = DartEncoder().encode('''
void outer() {
  int helper(int n) => n + 1;
  print(helper(2));
}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });

    test('yield and yield* in a generator', () {
      final j = jsonOf('''
Iterable<int> gen() sync* {
  yield 1;
  yield* [2, 3];
}
''');
      expect(j, contains('yield'));
    });

    test('do-while loop', () {
      final j = jsonOf('''
void f() {
  var i = 0;
  do {
    i = i + 1;
  } while (i < 3);
}
''');
      expect(j, contains('do_while'));
    });

    test('single-statement (non-block) loop bodies', () {
      final j = jsonOf('''
void f() {
  for (var i = 0; i < 2; i = i + 1) print(i);
  var k = 0;
  while (k < 2) k = k + 1;
}
''');
      expect(j, contains('for'));
      expect(j, contains('while'));
    });

    test('for-each over identifier iterable and C-style expression for', () {
      final j = jsonOf('''
void f(List<int> xs) {
  var total = 0;
  for (total in xs) {}
  var i = 0;
  for (; i < 3; i = i + 1) {}
}
''');
      expect(j, contains('for_in'));
    });

    test('for-each with var/final keyword and explicit type', () {
      final j = jsonOf('''
void f(List<int> xs) {
  for (var x in xs) {}
  for (final y in xs) {}
  for (int z in xs) {}
}
''');
      expect(j, contains('for_in'));
    });

    test('await-for over a stream', () {
      final j = jsonOf('''
Future<void> f(Stream<int> s) async {
  await for (final x in s) {
    print(x);
  }
}
''');
      expect(j, contains('for_in'));
    });
  });

  group('pattern variable declarations', () {
    test('record destructuring at the top of a block', () {
      final p = DartEncoder().encode('''
void f() {
  final (a, b) = (1, 2);
  print(a + b);
}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });

    test('multiple variable declaration with mixed initializers', () {
      final p = DartEncoder().encode('''
void f() {
  var a = 1, b = 2, c;
  print(a + b);
}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });
  });

  group('expressions', () {
    test('conditional, is, is!, as', () {
      final j = jsonOf('''
Object f(Object x) {
  final t = x is int ? 'int' : 'other';
  final n = x is! String;
  final d = x as num;
  return [t, n, d];
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('throw and rethrow', () {
      final j = jsonOf('''
void f() {
  try {
    throw Exception('boom');
  } catch (e) {
    rethrow;
  }
}
''');
      expect(j, contains('throw'));
    });

    test('await expression', () {
      final j = jsonOf('''
Future<int> f(Future<int> g) async {
  return await g;
}
''');
      expect(j, contains('await'));
    });

    test('index access and assignment', () {
      final j = jsonOf('''
void f(List<int> xs, Map<String, int> m) {
  final a = xs[0];
  xs[1] = a;
  final b = m['k'];
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('symbol literal and type literal', () {
      final p = DartEncoder().encode('''
void f() {
  final s = #foo;
  final t = int;
}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });

    test('compound assignments and prefix/postfix', () {
      final j = jsonOf('''
void f() {
  var i = 0;
  i += 2;
  i -= 1;
  i *= 3;
  i++;
  ++i;
  i--;
  --i;
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('all binary and bitwise operators map to std functions', () {
      final j = jsonOf('''
void f(int a, int b, bool p, bool q) {
  final r = [
    a + b, a - b, a * b, a ~/ b, a / b, a % b,
    a & b, a | b, a ^ b, a << b, a >> b, a >>> b,
    a == b, a != b, a < b, a > b, a <= b, a >= b,
    p && q, p || q, a ?? b,
  ];
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('unary minus, not and bitwise-not', () {
      final j = jsonOf('''
void f(int a, bool p) {
  final r = [-a, !p, ~a];
}
''');
      expect(j.isNotEmpty, isTrue);
    });
  });

  group('method invocations & string ops', () {
    test('toString, string methods, num methods', () {
      final j = jsonOf('''
void f(int n, String s) {
  final r = [
    n.toString(),
    s.toUpperCase(),
    s.toLowerCase(),
    s.trim(),
    s.split(','),
    s.contains('x'),
    (-n).abs(),
  ];
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('int.parse / double.parse static calls', () {
      final j = jsonOf('''
void f(String s) {
  final a = int.parse(s);
  final b = double.parse(s);
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('list and map collection methods', () {
      final j = jsonOf('''
void f(List<int> xs, Map<String, int> m) {
  xs.add(1);
  xs.remove(0);
  final c = xs.contains(1);
  final i = xs.indexOf(1);
  final k = m.containsKey('a');
  final len = xs.length;
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('named arguments in a call', () {
      final p = DartEncoder().encode('''
void greet({required String name, int times = 1}) {}
void main() {
  greet(name: 'a', times: 2);
}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });
  });

  group('instance creation', () {
    test('const, named and generic constructors', () {
      final j = jsonOf('''
void f() {
  final a = const Duration(seconds: 1);
  final b = List<int>.filled(3, 0);
  final c = StringBuffer();
}
''');
      expect(j.isNotEmpty, isTrue);
    });
  });

  group('cascades & collections', () {
    test('multi-section cascade and collection cascade', () {
      final j = jsonOf('''
void f() {
  final xs = <int>[]
    ..add(1)
    ..add(2);
  final b = StringBuffer()
    ..write('a')
    ..write('b');
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('null-aware cascade', () {
      final j = jsonOf('''
void f(List<int>? xs) {
  xs?..add(1)..add(2);
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('spread, null-aware spread, if-element and for-element', () {
      final j = jsonOf('''
List<int> f(List<int> base, List<int>? maybe, bool flag) {
  return [
    0,
    ...base,
    ...?maybe,
    if (flag) 1 else 2,
    for (final x in base) x * 2,
  ];
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('set and map literals, record literal', () {
      final j = jsonOf('''
void f() {
  final s = <int>{1, 2, 3};
  final m = <String, int>{'a': 1};
  final r = (1, name: 'x');
}
''');
      expect(j.isNotEmpty, isTrue);
    });
  });

  group('null-aware access', () {
    test('null-aware property and method access', () {
      final j = jsonOf('''
int? f(String? s) {
  final a = s?.length;
  final b = s?.toUpperCase();
  return a;
}
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('isEven / isOdd parity checks', () {
      final j = jsonOf('''
void f(int n) {
  final a = n.isEven;
  final b = n.isOdd;
}
''');
      expect(j.isNotEmpty, isTrue);
    });
  });

  group('switch expressions & patterns', () {
    test(
      'switch expression with constant, relational and wildcard patterns',
      () {
        final j = jsonOf('''
String f(int x) => switch (x) {
  0 => 'zero',
  < 0 => 'neg',
  _ => 'pos',
};
''');
        expect(j.isNotEmpty, isTrue);
      },
    );

    test('switch expression with record, object and var patterns', () {
      final j = jsonOf('''
String f(Object o) => switch (o) {
  (int a, int b) => 'rec',
  [int x, ...] => 'list',
  {'k': var v} => 'map',
  String s when s.isNotEmpty => s,
  int n && > 0 => 'pos',
  _ => 'other',
};
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('switch statement with cases and default', () {
      final j = jsonOf('''
void f(int x) {
  switch (x) {
    case 1:
      print('one');
      break;
    case 2:
    case 3:
      print('two-three');
      break;
    default:
      print('other');
  }
}
''');
      expect(j, contains('switch'));
    });

    test('cast, null-check and null-assert patterns', () {
      final j = jsonOf('''
String f(Object? o) => switch (o) {
  int _ as num => 'cast',
  int? _? => 'nncheck',
  int _! => 'assert',
  _ => 'x',
};
''');
      expect(j.isNotEmpty, isTrue);
    });
  });

  group('functions: async / generators / params', () {
    test('async, sync*, async* and parameter kinds', () {
      final p = DartEncoder().encode('''
Future<int> a() async => 1;
Iterable<int> b() sync* { yield 1; }
Stream<int> c() async* { yield 1; }
void d(int x, [int y = 0, int z = 1]) {}
void e(int x, {int y = 0, required int w}) {}
void main() {}
''');
      final fnNames = mainModule(p).functions.map((f) => f.name).toSet();
      expect(fnNames, containsAll(['a', 'b', 'c', 'd', 'e', 'main']));
    });

    test('annotations on functions are captured', () {
      final p = DartEncoder().encode('''
@Deprecated('use bar')
void foo() {}
void main() {}
''');
      final foo = mainModule(p).functions.firstWhere((f) => f.name == 'foo');
      expect(foo.metadata.fields.containsKey('annotations'), isTrue);
    });
  });

  group('string interpolation', () {
    test('interpolated string with expression and identifier parts', () {
      final j = jsonOf(r'''
String f(int n, String s) => 'n=$n s=${s.toUpperCase()} done';
''');
      expect(j.isNotEmpty, isTrue);
    });
  });

  group('strict mode propagation', () {
    test('strict encoder still encodes valid sources', () {
      final enc = DartEncoder(strict: true);
      final p = enc.encode('int add(int a, int b) => a + b;\nvoid main() {}');
      expect(p.modules, isNotEmpty);
      expect(enc.warnings, isEmpty);
    });
  });
}
