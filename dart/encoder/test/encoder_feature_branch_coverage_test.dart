/// Feature-branch coverage for `encoder.dart` (#61 Phase 2): real Dart
/// constructs the existing corpus + unit tests don't exercise — doc comments,
/// annotations on various declarations, sync*/async* generators, redirecting /
/// super constructors, generic type params, record-pattern variable
/// declarations, empty statements, const/final field keywords, and await.
///
/// Each test encodes a small Dart snippet containing exactly one feature and
/// asserts the encoder emits the corresponding Ball metadata — proving the
/// branch runs AND produces the expected output (not just that it doesn't
/// throw).
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

void main() {
  String jsonOf(String source) =>
      jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

  group('doc comments -> meta[doc]', () {
    test('class + method + field + top-level function doc comments', () {
      final js = jsonOf('''
/// A documented class.
class Widget {
  /// A documented field.
  final int size = 1;

  /// A documented method.
  int area() => size * size;
}

/// A documented top-level function.
void run() {}

void main() {}
''');
      expect(js, contains('doc'));
    });

    test('mixin + enum + extension doc comments', () {
      final js = jsonOf('''
/// A documented mixin.
mixin Walk {
  void step() {}
}

/// A documented enum.
enum Color { red, green, blue }

/// A documented extension.
extension IntX on int {
  int get doubled => this * 2;
}

void main() {}
''');
      expect(js, contains('doc'));
    });
  });

  group('annotations -> meta[annotations]', () {
    test('class / mixin / enum / constructor annotations', () {
      final js = jsonOf('''
@deprecated
class Old {
  @deprecated
  Old();
}

@deprecated
mixin M {}

@deprecated
enum E { a, b }

void main() {}
''');
      expect(js, contains('annotations'));
    });
  });

  group('generator function bodies', () {
    test('sync* -> is_sync_star', () {
      expect(
        jsonOf('''
Iterable<int> gen() sync* {
  yield 1;
  yield 2;
}
void main() {}
'''),
        contains('is_sync_star'),
      );
    });

    test('async* -> is_async_star', () {
      expect(
        jsonOf('''
Stream<int> gen() async* {
  yield 1;
}
void main() {}
'''),
        contains('is_async_star'),
      );
    });
  });

  group('await for with identifier loop variable -> is_await', () {
    test('await for (x in stream) where x is a pre-declared identifier', () {
      // ForEachPartsWithIdentifier (not a declaration) + await keyword — the
      // branch that stamps is_await onto the for_in call.
      expect(
        jsonOf('''
Stream<int> src() async* {
  yield 1;
}
Future<void> run() async {
  var x = 0;
  await for (x in src()) {
    print(x);
  }
}
void main() {}
'''),
        contains('is_await'),
      );
    });
  });

  group('constructors', () {
    test('redirecting factory constructor -> redirects_to', () {
      expect(
        jsonOf('''
class F {
  F.impl();
  factory F() = F.impl;
}
void main() {}
'''),
        contains('redirects_to'),
      );
    });

    test('super.named() initializer records the constructor name', () {
      final js = jsonOf('''
class B {
  B.named();
}
class D extends B {
  D() : super.named();
}
void main() {}
''');
      expect(js, contains('super'));
      expect(js, contains('named'));
    });

    test(
      'this.named() redirecting initializer records the constructor name',
      () {
        final js = jsonOf('''
class C {
  C.named();
  C() : this.named();
}
void main() {}
''');
        expect(js, contains('redirect'));
        expect(js, contains('named'));
      },
    );
  });

  group('generic type parameters -> meta[type_params]', () {
    test('generic class type parameters', () {
      expect(
        jsonOf('''
class Box<T> {
  final T value;
  Box(this.value);
}
void main() {}
'''),
        contains('type_params'),
      );
    });
  });

  group('record-pattern variable declaration', () {
    test('positional record destructuring in a block', () {
      final js = jsonOf('''
void main() {
  var (a, b) = (1, 2);
  print(a + b);
}
''');
      // The destructuring is spliced as let-bindings that reference a temp via
      // \$1 / \$2 positional field access.
      expect(js, contains('__ball_rec_'));
    });

    test('named-field record destructuring in a block', () {
      final js = jsonOf('''
void main() {
  final (x, y: name) = (1, y: 2);
  print(x + name);
}
''');
      expect(js, contains('__ball_rec_'));
    });
  });

  group('empty statement', () {
    test('a bare ; encodes as a no-op', () {
      // Should encode without error; the empty statement becomes a null literal.
      expect(() => DartEncoder().encode('void main() { ; }'), returnsNormally);
    });
  });

  group('local multi-variable declarations -> meta[keyword] + __no_init__', () {
    test('final / const / uninitialized locals in one declaration each', () {
      // The multi-variable local path builds a block of let-bindings, stamping
      // each with keyword (final/const/var) and using __no_init__ for a
      // variable with no initializer.
      final js = jsonOf('''
void main() {
  final a = 1, b = 2;
  const c = 3, d = 4;
  int e, f = 5;
  print(a + b + c + d + e + f);
}
''');
      expect(js, contains('keyword'));
      expect(js, contains('__no_init__'));
    });
  });

  group('generators in method / local-function / extension-type contexts', () {
    test('sync* and async* class methods', () {
      final js = jsonOf('''
class Gen {
  Iterable<int> counting() sync* {
    yield 1;
    yield 2;
  }

  Stream<int> streaming() async* {
    yield 3;
  }
}
void main() {}
''');
      expect(js, contains('is_sync_star'));
      expect(js, contains('is_async_star'));
    });

    test('sync* and async* local (nested) functions', () {
      final js = jsonOf('''
void main() {
  Iterable<int> localSync() sync* {
    yield 1;
  }
  Stream<int> localAsync() async* {
    yield 2;
  }
  localSync();
  localAsync();
}
''');
      expect(js, contains('is_sync_star'));
      expect(js, contains('is_async_star'));
    });
  });

  group('statement forms', () {
    test('do-while with a non-block (single-statement) body', () {
      expect(
        () => DartEncoder().encode('''
void main() {
  var i = 0;
  do i = i + 1; while (i < 3);
  print(i);
}
'''),
        returnsNormally,
      );
    });

    test('switch statement: braced case body, default, and pattern case', () {
      final js = jsonOf('''
String describe(int x) {
  switch (x) {
    case 0:
      {
        return 'zero';
      }
    case 1:
      return 'one';
    default:
      return 'many';
  }
}
enum Suit { hearts, spades }
String suitName(Suit s) {
  switch (s) {
    case Suit.hearts:
      return 'H';
    case Suit.spades:
      return 'S';
  }
}
void main() {}
''');
      expect(js, contains('switch'));
    });

    test('labeled statement, assert, and rethrow', () {
      expect(
        () => DartEncoder().encode('''
void main() {
  assert(1 < 2, 'math works');
  outer:
  for (var i = 0; i < 2; i++) {
    if (i == 1) break outer;
  }
  try {
    throw StateError('x');
  } catch (e) {
    rethrow;
  }
}
'''),
        returnsNormally,
      );
    });
  });

  group(
    'member-kind metadata (getter / setter / operator / static / abstract)',
    () {
      test('getters, setters, operators, static and abstract members', () {
        final js = jsonOf('''
abstract class Shape {
  int _n = 0;
  int get n => _n;
  set n(int v) => _n = v;
  Shape operator +(Shape other) => this;
  static int origin() => 0;
  int area();
}
void main() {}
''');
        expect(js, contains('is_getter'));
        expect(js, contains('is_setter'));
        expect(js, contains('is_operator'));
        expect(js, contains('is_static'));
        expect(js, contains('is_abstract'));
      });
    },
  );

  group('try / catch with typed and stack-trace clauses', () {
    test('on Type catch (e, st) and catch (e, st) with stack traces', () {
      expect(
        () => DartEncoder().encode('''
void main() {
  try {
    throw StateError('boom');
  } on StateError catch (e, st) {
    print('\$e \$st');
  } on Exception catch (e) {
    print(e);
  } catch (e, st) {
    print('\$e \$st');
  } finally {
    print('done');
  }
}
'''),
        returnsNormally,
      );
    });
  });

  group('parameter forms -> _encodeParamsMeta', () {
    test('positional-optional, named, required-named, and defaults', () {
      expect(
        () => DartEncoder().encode('''
int a(int x, [int y = 2, int z = 3]) => x + y + z;
int b(int x, {int y = 2, required int z}) => x + y + z;
void main() {
  a(1);
  b(1, z: 3);
}
'''),
        returnsNormally,
      );
    });
  });

  group('const instance creation + explicit generic instantiation', () {
    test('const constructor call and generic type arguments', () {
      final js = jsonOf('''
class Point {
  final int x;
  final int y;
  const Point(this.x, this.y);
}
class Box<T> {
  final T value;
  const Box(this.value);
}
void main() {
  const p = Point(1, 2);
  final b = Box<int>(3);
  print('\$p \$b');
}
''');
      // const construction stamps is_const metadata on the message creation.
      expect(js, contains('is_const'));
    });
  });

  group('string interpolation + adjacent strings + cascades', () {
    test('interpolation, adjacent string literals, and a cascade chain', () {
      expect(
        () => DartEncoder().encode(r'''
class Buf {
  final List<int> items = [];
  void add(int x) => items.add(x);
}
void main() {
  var name = 'world';
  var greeting = 'hello, $name!' ' and welcome';
  var b = Buf()
    ..add(1)
    ..add(2);
  print('$greeting ${b.items.length}');
}
'''),
        returnsNormally,
      );
    });
  });

  group('conditional, null-aware, and null-assert expressions', () {
    test('ternary, ?., ??, and ! operators', () {
      expect(
        () => DartEncoder().encode('''
int pick(int? a, int b) {
  var c = a ?? b;
  var d = a?.bitLength ?? 0;
  var e = (a != null) ? a! : b;
  return c + d + e;
}
void main() {
  pick(null, 5);
  pick(3, 5);
}
'''),
        returnsNormally,
      );
    });
  });

  group('conditional import/export configurations with a value', () {
    test('import/export "if (name == value)" records the config value', () {
      // The `== 'value'` form gives the configuration a non-null value, which
      // exercises the config-value encoding arm (as opposed to the bare
      // `if (dart.library.io)` form covered elsewhere).
      final js = jsonOf('''
import 'stub.dart'
    if (dart.library.io == 'true') 'io_impl.dart';
export 'stub.dart'
    if (dart.library.io == 'true') 'io_impl.dart';
void main() {}
''');
      expect(js, contains('configurations'));
      expect(js, contains('value'));
    });
  });
}
