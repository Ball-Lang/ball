/// Additional targeted coverage tests for narrower encoder.dart routes:
/// single-section collection cascades (`xs..add(x)`), null-aware access on a
/// non-reference target, enum `with` mixins, for-loops with multiple updaters,
/// type literals / tear-offs, and async/generator local function declarations.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

void main() {
  String jsonOf(String source) =>
      jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

  Module mainModule(Program p) => p.modules.firstWhere((m) => m.name == 'main');

  group('single-section collection cascades', () {
    test('list ..add routes to list_push wrapped in assign', () {
      final j = jsonOf('''
void f() {
  final xs = <int>[];
  xs..add(1);
}
''');
      expect(j, contains('list_push'));
      expect(j, contains('assign'));
    });

    test('list ..insert routes to list_insert', () {
      final j = jsonOf('''
void f() {
  final xs = <int>[];
  xs..insert(0, 9);
}
''');
      expect(j, contains('list_insert'));
    });

    test('list ..clear and ..sort route to collection ops', () {
      final clearJson = jsonOf('''
void f() {
  final xs = <int>[1];
  xs..clear();
}
''');
      expect(clearJson, contains('list_clear'));

      final sortJson = jsonOf('''
void f() {
  final xs = <int>[2, 1];
  xs..sort();
}
''');
      expect(sortJson, contains('list_sort'));
    });

    test('non-identifier collection cascade target still routes', () {
      // A cascade whose target is not a SimpleIdentifier skips the assign-wrap
      // branch but still routes to the collection op.
      final j = jsonOf('''
List<int> make() => <int>[];
void f() {
  make()..add(1);
}
''');
      expect(j, contains('list_push'));
    });

    test('cascade with an unrouted method falls back to the cascade path', () {
      final j = jsonOf('''
void f(StringBuffer b) {
  b..write('x');
}
''');
      // `write` is not a routed collection method → general cascade encoding.
      expect(j.isNotEmpty, isTrue);
    });
  });

  group('null-aware access on non-reference targets', () {
    test('null-aware property access on a method-call target', () {
      final j = jsonOf('''
String? upper() => 'x';
int? f() {
  return upper()?.length;
}
''');
      expect(j, contains('null_aware_access'));
    });

    test('null-aware method call on a method-call target', () {
      final j = jsonOf('''
String? get() => 'x';
String? f() {
  return get()?.toUpperCase();
}
''');
      expect(j, contains('null_aware_call'));
    });
  });

  group('enum with mixins and type params', () {
    test('enum with with-clause mixins', () {
      final p = DartEncoder().encode('''
mixin Loggable {}
enum Status with Loggable {
  active,
  inactive;
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':Status'));
      expect(td.metadata.fields.containsKey('mixins'), isTrue);
    });

    test('generic enum with documented value', () {
      final p = DartEncoder().encode('''
enum Box<T> {
  /// The empty box.
  empty,
  full;
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':Box'));
      expect(td.metadata.fields.containsKey('type_params'), isTrue);
    });
  });

  group('for-loops with multiple updaters', () {
    test('C-style for with two updaters', () {
      final j = jsonOf('''
void f() {
  for (var i = 0, j = 10; i < j; i = i + 1, j = j - 1) {
    print(i);
  }
}
''');
      expect(j, contains('for'));
    });

    test('expression-style for with initialization', () {
      final j = jsonOf('''
void f() {
  var i;
  for (i = 0; i < 3; i = i + 1) {
    print(i);
  }
}
''');
      expect(j, contains('for'));
    });
  });

  group('type literals & tear-offs', () {
    test('type literal as a value', () {
      final p = DartEncoder().encode('''
Type f() {
  return int;
}
void main() {}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });

    test('prefixed identifier (library member access)', () {
      final p = DartEncoder().encode('''
import 'dart:math' as math;
double f() => math.pi;
void main() {}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });
  });

  group('local function declarations with modifiers', () {
    test('async / sync* / async* local functions', () {
      final p = DartEncoder().encode('''
void outer() {
  Future<int> a() async => 1;
  Iterable<int> b() sync* { yield 1; }
  Stream<int> c() async* { yield 1; }
}
''');
      expect(mainModule(p).functions, isNotEmpty);
    });
  });

  group('switch statement pattern cases', () {
    test('pattern case with when guard and braced body', () {
      final j = jsonOf('''
void f(Object o) {
  switch (o) {
    case int n when n > 0:
      {
        print('pos');
      }
    case String s:
      print(s);
    default:
      print('other');
  }
}
''');
      expect(j, contains('switch'));
    });
  });

  group('for-each variants with non-block bodies', () {
    test('for-each with identifier and single-statement body', () {
      final j = jsonOf('''
void f(List<int> xs) {
  int v = 0;
  for (v in xs) print(v);
}
''');
      expect(j, contains('for_in'));
    });

    test('destructuring for-each (pattern) with single-statement body', () {
      final j = jsonOf('''
void f(Map<String, int> m) {
  for (final MapEntry(key: k, value: val) in m.entries) print(k);
}
''');
      expect(j, contains('for_in'));
    });

    test('await-for with a destructuring pattern', () {
      final j = jsonOf('''
Future<void> f(Stream<(int, int)> s) async {
  await for (final (a, b) in s) {
    print(a + b);
  }
}
''');
      expect(j, contains('for_in'));
    });
  });

  group('operator method declarations', () {
    test(
      'comparison and arithmetic operator methods encode by canonical name',
      () {
        final p = DartEncoder().encode('''
class N {
  bool operator <(N o) => true;
  bool operator <=(N o) => true;
  bool operator >(N o) => true;
  bool operator >=(N o) => true;
  N operator +(N o) => this;
  N operator -(N o) => this;
  N operator *(N o) => this;
  N operator ~/(N o) => this;
  N operator %(N o) => this;
  N operator &(N o) => this;
  N operator |(N o) => this;
  N operator ^(N o) => this;
  N operator <<(N o) => this;
  N operator >>(N o) => this;
  N operator >>>(N o) => this;
  N operator ~() => this;
  N operator -() => this;
}
void main() {}
''');
        expect(mainModule(p).functions, isNotEmpty);
      },
    );
  });

  group('mixin metadata edge cases', () {
    test('mixin with base keyword and documentation', () {
      final p = DartEncoder().encode('''
/// A base mixin.
base mixin M {
  void hook() {}
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':M'));
      final meta = td.metadata.fields;
      expect(meta['kind']!.stringValue, equals('mixin'));
      expect(meta.containsKey('doc'), isTrue);
    });
  });
}
