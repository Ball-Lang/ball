/// Targeted coverage tests for the less-common encoder routes in
/// `encoder.dart`: dart:convert routing (jsonEncode/utf8/base64), protobuf
/// API routing (`whichExpr`/`hasBody`), getter routes (`isNaN`/`isEmpty`),
/// collection-element variants (if-case / C-style for-element), the synthetic
/// `__ball_e` try/catch re-encoding patterns the compiler emits, and assorted
/// metadata branches.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

void main() {
  String jsonOf(String source) =>
      jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

  Module mainModule(Program p) => p.modules.firstWhere((m) => m.name == 'main');

  group('dart:convert routing', () {
    test('jsonEncode / jsonDecode route to std_convert and build a module', () {
      final p = DartEncoder().encode('''
import 'dart:convert';
void f(Object o, String s) {
  final a = jsonEncode(o);
  final b = jsonDecode(s);
}
void main() {}
''');
      final j = jsonEncode(encodeBallFileJson(p));
      expect(j, contains('std_convert'));
      expect(j, contains('json_encode'));
      expect(j, contains('json_decode'));
      // A std_convert module should be emitted with these base functions.
      final convertMod = p.modules.firstWhere(
        (m) => m.name == 'std_convert',
        orElse: () => throw StateError('no std_convert module'),
      );
      final fns = convertMod.functions.map((f) => f.name).toSet();
      expect(fns, containsAll(['json_encode', 'json_decode']));
      // Base functions carry no body.
      expect(convertMod.functions.every((f) => f.isBase), isTrue);
    });

    test(
      'utf8.encode/decode and base64.encode/decode route to std_convert',
      () {
        final p = DartEncoder().encode('''
import 'dart:convert';
void f(String s, List<int> bytes) {
  final a = utf8.encode(s);
  final b = utf8.decode(bytes);
  final c = base64.encode(bytes);
  final d = base64.decode(s);
}
void main() {}
''');
        final convertMod = p.modules.firstWhere((m) => m.name == 'std_convert');
        final fns = convertMod.functions.map((f) => f.name).toSet();
        expect(
          fns,
          containsAll([
            'utf8_encode',
            'utf8_decode',
            'base64_encode',
            'base64_decode',
          ]),
        );
      },
    );
  });

  group('protobuf API routing', () {
    test('which*/has* calls route to the ball_proto module', () {
      final p = DartEncoder().encode('''
void f(Object e) {
  final a = e.whichExpr();
  final b = e.hasBody();
  final c = e.whichKind();
  final d = e.hasMetadata();
}
void main() {}
''');
      final j = jsonEncode(encodeBallFileJson(p));
      expect(j, contains('ball_proto'));
      final protoMod = p.modules.firstWhere(
        (m) => m.name == 'ball_proto',
        orElse: () => throw StateError('no ball_proto module'),
      );
      final fns = protoMod.functions.map((f) => f.name).toSet();
      expect(fns, containsAll(['whichExpr', 'hasBody', 'whichKind']));
      expect(protoMod.functions.every((f) => f.isBase), isTrue);
    });
  });

  group('getter property routes', () {
    test('sign / isNaN / isFinite / isInfinite map to math std fns', () {
      final j = jsonOf('''
void f(double x) {
  final r = [x.sign, x.isNaN, x.isFinite, x.isInfinite];
}
''');
      expect(j, contains('math_sign'));
      expect(j, contains('math_is_nan'));
      expect(j, contains('math_is_finite'));
      expect(j, contains('math_is_infinite'));
    });

    test('isEmpty / isNotEmpty map to string_is_empty (+ not)', () {
      final j = jsonOf('''
void f(String s) {
  final a = s.isEmpty;
  final b = s.isNotEmpty;
}
''');
      expect(j, contains('string_is_empty'));
    });
  });

  group('parenthesized expressions', () {
    test('parens around assignment and conditional are preserved', () {
      final j = jsonOf('''
void f(List<int>? xs, bool c) {
  (xs ??= []).add(1);
  final v = (c ? 1 : 2);
}
''');
      expect(j, contains('paren'));
    });
  });

  group('collection-element variants', () {
    test('if-case element', () {
      final j = jsonOf('''
List<String> f(Object o) {
  return [
    if (o case int n) 'int',
  ];
}
''');
      expect(j, contains('collection_if'));
    });

    test('if-element with else branch', () {
      final j = jsonOf('''
List<int> f(bool flag) {
  return [if (flag) 1 else 2];
}
''');
      expect(j, contains('collection_if'));
    });

    test('C-style for-element with declarations', () {
      final j = jsonOf('''
List<int> f(int n) {
  return [for (var i = 0; i < n; i = i + 1) i * 2];
}
''');
      expect(j, contains('collection_for'));
    });

    test('C-style for-element with expression initializer', () {
      final j = jsonOf('''
List<int> f(int n) {
  var i = 0;
  return [for (i = 0; i < n; i = i + 1) i];
}
''');
      expect(j, contains('collection_for'));
    });

    test('for-element over a pre-declared identifier', () {
      final j = jsonOf('''
List<int> f(List<int> xs) {
  int v = 0;
  return [for (v in xs) v];
}
''');
      expect(j, contains('collection_for'));
    });

    test('null-aware spread in a map literal', () {
      final j = jsonOf('''
Map<String, int> f(Map<String, int>? extra) {
  return {'a': 1, ...?extra};
}
''');
      expect(j, contains('null_spread'));
    });
  });

  group('synthetic compiler catch patterns (re-encoding)', () {
    test('simple untyped synthetic catch (__ball_e alias)', () {
      // Mirrors what the compiler emits when compiling Ball `try` out to Dart,
      // which the encoder must re-fold back into a Ball catch.
      final j = jsonOf('''
void f() {
  try {
    risky();
  } catch (__ball_e) {
    final dynamic e = __ball_e;
    print(e);
  }
}
void risky() {}
''');
      expect(j, contains('try'));
    });

    test('synthetic catch with stack-trace alias', () {
      final j = jsonOf('''
void f() {
  try {
    risky();
  } catch (__ball_e, __ball_st) {
    final dynamic e = __ball_e;
    final st = __ball_st;
    print(e);
    print(st);
  }
}
void risky() {}
''');
      expect(j, contains('try'));
    });

    test('tag-typed synthetic catch chain with rethrow fallback', () {
      final j = jsonOf('''
void f() {
  try {
    risky();
  } catch (__ball_e) {
    if (__ball_e is Map && __ball_e['__type'] == 'FormatException') {
      final e = __ball_e;
      print(e);
    } else if (__ball_e is Map && __ball_e['__type'] == 'StateError') {
      final e = __ball_e;
      print(e);
    } else {
      rethrow;
    }
  }
}
void risky() {}
''');
      expect(j, contains('try'));
    });

    test('tag-typed synthetic catch with untyped else fallback', () {
      final j = jsonOf('''
void f() {
  try {
    risky();
  } catch (__ball_e) {
    if (__ball_e is Map && __ball_e['__type'] == 'FormatException') {
      final e = __ball_e;
      print('fmt');
    } else {
      final dynamic e = __ball_e;
      print('other');
    }
  }
}
void risky() {}
''');
      expect(j, contains('try'));
    });

    test('tag-typed synthetic catch with stack alias before the chain', () {
      final j = jsonOf('''
void f() {
  try {
    risky();
  } catch (__ball_e, __ball_st) {
    final st = __ball_st;
    if (__ball_e is Map && __ball_e['__type'] == 'FormatException') {
      final e = __ball_e;
      print(e);
    } else {
      rethrow;
    }
  }
}
void risky() {}
''');
      expect(j, contains('try'));
    });

    test('regular typed on-catch with finally', () {
      final j = jsonOf('''
void f() {
  try {
    risky();
  } on FormatException catch (e, st) {
    print(e);
  } finally {
    print('done');
  }
}
void risky() {}
''');
      expect(j, contains('try'));
    });
  });

  group('patterns with names', () {
    test('record pattern with named field and object pattern', () {
      final j = jsonOf('''
String f(Object o) => switch (o) {
  (:int a, :int b) => 'named',
  Rect(width: var w, height: var h) => 'obj',
  _ => 'x',
};
''');
      expect(j.isNotEmpty, isTrue);
    });

    test('logical-or pattern in a switch', () {
      final j = jsonOf('''
String f(int x) => switch (x) {
  1 || 2 || 3 => 'low',
  _ => 'high',
};
''');
      expect(j.isNotEmpty, isTrue);
    });
  });

  group('encodeModule accumulation', () {
    test('encodeModule then buildStdModules consolidates convert + proto', () {
      final enc = DartEncoder();
      enc.encodeModule('''
import 'dart:convert';
String a(Object o) => jsonEncode(o);
''', moduleName: 'lib.a');
      enc.encodeModule('''
bool b(Object e) => e.hasBody();
''', moduleName: 'lib.b');
      final stds = enc.buildStdModules();
      // std_collections / proto modules are returned via the record fields.
      expect(stds.protoModule, isNotNull);
      expect(
        stds.protoModule!.functions.map((f) => f.name),
        contains('hasBody'),
      );
    });
  });

  group('top-level metadata round-trip keys', () {
    test('module carries dart_parts metadata for part directives', () {
      final p = DartEncoder().encode('''
library m;
part 'a.dart';
part 'b.dart';
void main() {}
''');
      final meta = mainModule(p).metadata.fields;
      expect(meta.containsKey('dart_parts'), isTrue);
    });
  });
}
