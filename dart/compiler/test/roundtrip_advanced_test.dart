/// Advanced round-trip compiler coverage: extension types, unnamed extensions,
/// optional/named/super/this parameters, late & uninitialized locals, generic
/// methods and type-argumented calls, const generics, and import/export
/// directives (deferred, conditional, show/hide).
@TestOn('vm')
library;

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

String _rt(String source) {
  final program = DartEncoder().encode(source);
  return DartCompiler(program, noFormat: true).compile();
}

String _flat(String source) => _rt(source).replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('extension types', () {
    test('extension type with representation field', () {
      final out = _flat('''
extension type Meters(double value) {
  double get feet => value * 3.28;
}
void main() { print(Meters(1.0).feet.toString()); }
''');
      expect(out, contains('extension type Meters'));
      expect(out, contains('value'));
    });
  });

  group('unnamed extension', () {
    test('anonymous extension on a type', () {
      final out = _flat('''
extension on String {
  String shout() => '\$this!';
}
void main() { print('hi'.shout()); }
''');
      expect(out, contains('extension on String'));
    });
  });

  group('parameter forms', () {
    test('named, optional, required-named, defaults', () {
      final out = _flat('''
String build(
  int a, [
  int b = 2,
]) => '\$a/\$b';
String greet({required String name, String greeting = 'hi'}) =>
    '\$greeting \$name';
void main() {
  print(build(1));
  print(greet(name: 'x'));
}
''');
      expect(out, contains('build'));
      expect(out, contains('greet'));
      expect(out, contains('required'));
    });

    test('super parameters in subclass constructor', () {
      final out = _flat('''
class Base {
  final int x;
  Base(this.x);
}
class Derived extends Base {
  final int y;
  Derived(super.x, this.y);
}
void main() { Derived(1, 2); }
''');
      expect(out, contains('class Derived extends Base'));
      expect(out, contains('super.x'));
    });
  });

  group('locals', () {
    test('late and uninitialized typed locals', () {
      final out = _flat('''
void main() {
  late int computed;
  int? maybe;
  computed = 5;
  print(computed.toString());
  print(maybe.toString());
}
''');
      expect(out, contains('late'));
      expect(out, contains('int? maybe'));
    });

    test('typed final and const locals', () {
      final out = _flat('''
void main() {
  final int a = 1;
  const int b = 2;
  print((a + b).toString());
}
''');
      expect(out, contains('final int a'));
      expect(out, contains('const int b'));
    });
  });

  group('generics', () {
    test('generic method and type-argumented call', () {
      final out = _flat('''
T identity<T>(T x) => x;
void main() {
  print(identity<int>(5).toString());
}
''');
      expect(out, contains('identity'));
    });

    test('nested generic types', () {
      final out = _flat('''
Map<String, List<int>> build() => {'a': [1, 2]};
void main() { print(build().toString()); }
''');
      expect(out, contains('Map<String, List<int>>'));
    });

    test('const constructor with generic type', () {
      final out = _flat('''
class Wrapper<T> {
  final T value;
  const Wrapper(this.value);
}
void main() {
  const w = Wrapper<int>(5);
  print(w.value.toString());
}
''');
      expect(out, contains('Wrapper'));
    });
  });

  group('directives', () {
    test('import with show / hide / prefix', () {
      final out = _flat('''
import 'dart:math' as math show pi hide e;
void main() { print(math.pi.toString()); }
''');
      expect(out, contains("import 'dart:math'"));
    });

    test('deferred import', () {
      final out = _rt('''
import 'dart:convert' deferred as conv;
void main() async {
  await conv.loadLibrary();
  print(conv.jsonEncode({'a': 1}));
}
''');
      expect(out, contains("import 'dart:convert'"));
    });

    test('export with show', () {
      final out = _flat('''
export 'dart:math' show pi;
void main() {}
''');
      expect(out, contains("export 'dart:math'"));
    });
  });

  group('type tests and casts in source', () {
    test('is / is! / as expressions', () {
      final out = _flat('''
String classify(Object o) {
  if (o is int) { return 'int'; }
  if (o is! String) { return 'not-string'; }
  return (o as String).toUpperCase();
}
void main() { print(classify(5)); }
''');
      expect(out, contains(' is '));
      expect(out, contains(' as '));
    });
  });

  group('functions returning generators assigned to typed local', () {
    test('sync* result assigned to List-typed var keeps Iterable type', () {
      final out = _flat('''
Iterable<int> nums() sync* { yield 1; yield 2; }
void main() {
  var xs = nums();
  print(xs.toList().toString());
}
''');
      expect(out, contains('sync*'));
    });
  });
}
