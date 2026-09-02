/// Regression tests for issue #494 (Bug B): Dart 3.8 null-aware collection
/// elements (`[1, ?x]`, `{1, ?x}`, `{?k: v}`, `{k: ?v}`) were unencodable —
/// `_encodeCollectionElement` had no `NullAwareElement` branch and threw
/// `UnsupportedError: Encoder: unsupported collection element
/// NullAwareElementImpl`, so any real file using them could not be encoded at
/// all.
///
/// The expected values below are the verified native-`dart run` outputs (the
/// oracle) — see also the conformance fixture
/// `tests/conformance/src/417_null_aware_collection_elements.dart`.
///
/// The evaluation-order group is the load-bearing part: Dart evaluates a
/// null-aware operand EXACTLY ONCE and short-circuits (`{?k: v}` does not
/// evaluate `v` when `k` is null), so the desugaring may not simply repeat the
/// operand in both the guard and the element.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

String jsonOf(String source) =>
    jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

Future<String> run(String src) async {
  final program = DartEncoder().encode(src);
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add, stderr: lines.add);
  await engine.run();
  return lines.join('\n');
}

void main() {
  group('null-aware collection elements encode', () {
    test('list null-aware element does not throw and emits collection_if', () {
      final j = jsonOf('''
List<int> f(int? x) => [1, 2, ?x];
void main() {}
''');
      expect(j.contains('collection_if'), isTrue);
    });

    test('set / map null-aware forms do not throw', () {
      expect(
        () => jsonOf('''
Set<int> s(int? x) => {1, ?x};
Map<int, int> m1(int? k) => {?k: 1};
Map<int, int> m2(int? v) => {1: ?v};
Map<int, int> m3(int? k, int? v) => {?k: ?v};
void main() {}
'''),
        returnsNormally,
      );
    });
  });

  group('null-aware collection elements execute like native Dart', () {
    test('list: non-null and null', () async {
      expect(
        await run('''
List<int> f(int? x) => [1, 2, ?x];
void main() {
  print(f(3));
  print(f(null));
}
'''),
        '[1, 2, 3]\n[1, 2]',
      );
    });

    test('set: non-null and null', () async {
      expect(
        await run('''
Set<int> f(int? x) => {1, 2, ?x};
void main() {
  print(f(3));
  print(f(null));
}
'''),
        '{1, 2, 3}\n{1, 2}',
      );
    });

    test('map: null-aware key', () async {
      expect(
        await run('''
Map<int, int> f(int? k) => {1: 10, ?k: 20};
void main() {
  print(f(2));
  print(f(null));
}
'''),
        '{1: 10, 2: 20}\n{1: 10}',
      );
    });

    test('map: null-aware value', () async {
      expect(
        await run('''
Map<int, int> f(int? v) => {1: 10, 2: ?v};
void main() {
  print(f(20));
  print(f(null));
}
'''),
        '{1: 10, 2: 20}\n{1: 10}',
      );
    });

    test('map: null-aware key and value', () async {
      expect(
        await run('''
Map<int, int> f(int? k, int? v) => {1: 10, ?k: ?v};
void main() {
  print(f(2, 20));
  print(f(null, 20));
  print(f(2, null));
  print(f(null, null));
}
'''),
        '{1: 10, 2: 20}\n{1: 10}\n{1: 10}\n{1: 10}',
      );
    });

    test('nested inside a collection-for / collection-if', () async {
      expect(
        await run('''
List<int> f(int? x) => [for (var i = 0; i < 2; i++) if (i == 1) ?x];
void main() {
  print(f(7));
  print(f(null));
}
'''),
        '[7]\n[]',
      );
    });
  });

  group('null-aware operands are evaluated once, in source order, and '
      'short-circuit', () {
    test('a side-effecting list operand is evaluated exactly once', () async {
      expect(
        await run('''
int? probe(String tag, int? v) {
  print('eval ' + tag);
  return v;
}
void main() {
  print([1, ?probe('a', 2)]);
  print([1, ?probe('b', null)]);
}
'''),
        'eval a\n[1, 2]\neval b\n[1]',
      );
    });

    test('a null key short-circuits its value expression', () async {
      expect(
        await run('''
int? probe(String tag, int? v) {
  print('eval ' + tag);
  return v;
}
void main() {
  print({?probe('key1', null): probe('val1', 9)});
  print({?probe('key2', 5): probe('val2', 9)});
}
'''),
        'eval key1\n{}\neval key2\neval val2\n{5: 9}',
      );
    });

    test(
      'a non-null-aware key is evaluated before a null-aware value',
      () async {
        expect(
          await run('''
int? probe(String tag, int? v) {
  print('eval ' + tag);
  return v;
}
void main() {
  print({probe('key3', 5)!: ?probe('val3', null)});
}
'''),
          'eval key3\neval val3\n{}',
        );
      },
    );
  });
}
