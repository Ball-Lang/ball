/// Regression tests for issue #494 (Bug A) / the arity subset of issue #488:
/// the Dart encoder's `collectionRoutes` table dispatched on the METHOD NAME
/// alone, so a *user-defined* method whose name collides with a std/String/
/// collection method was rerouted to the std base function even when the call
/// could not possibly satisfy that function's operands.
///
/// The worst case is a zero-argument call: `splitter.split()` (dart-lang/async
/// `lib/src/stream_splitter.dart`) was encoded as
/// `std.string_split(value: <target>)` with no `separator` field at all, and
/// `DartCompiler._methodCall2` then emitted the literal placeholder
/// `/* invalid split() */` into an expression position — Dart that does not
/// parse.
///
/// Routes now carry a `(minArgs, maxArgs)` arity window taken from the real
/// Dart signature; a call whose argument count falls outside it falls through
/// to the generic user-method-call encoding (`function: <name>`, `self` field).
///
/// NOTE (scope, deliberately narrow): an arity window cannot see the RECEIVER
/// type, so `Set.add` vs `List.add` and `Map.toList` vs `List.toList` — the
/// majority of #488's real-world failures — are still misrouted. Those need
/// the resolver-backed encoder #488 proposes.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Encode [source] and return the serialized Ball JSON for structural search.
String jsonOf(String source) =>
    jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

/// Encode [src] and run it on the Dart engine, returning captured stdout.
Future<String> run(String src) async {
  final program = DartEncoder().encode(src);
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add, stderr: lines.add);
  await engine.run();
  return lines.join('\n');
}

void main() {
  group('arity-gated collection/std method dispatch', () {
    test('zero-arg user method named split() is NOT routed to string_split', () {
      final j = jsonOf('''
class C {
  int split() => 1;
}
void f(C c) {
  c.split();
}
void main() {}
''');
      expect(
        j.contains('string_split'),
        isFalse,
        reason:
            'a 0-arg split() cannot satisfy std.string_split(value, '
            'separator) and must fall through to the generic user-method call',
      );
      expect(j.contains('"function":"split"'), isTrue);
      expect(j.contains('"name":"self"'), isTrue);
    });

    test('a real String.split(separator) still routes to std.string_split', () {
      final j = jsonOf('''
List<String> f(String s) => s.split(',');
void main() {}
''');
      expect(j.contains('string_split'), isTrue);
      expect(j.contains('"name":"separator"'), isTrue);
    });

    test('zero-arg user methods colliding with 1-arg routes fall through', () {
      final j = jsonOf('''
class Bag {
  bool contains() => true;
  int indexOf() => 7;
  int compareTo() => 0;
  bool startsWith() => false;
  bool endsWith() => false;
  String substring() => 'x';
}
void f(Bag b) {
  b.contains();
  b.indexOf();
  b.compareTo();
  b.startsWith();
  b.endsWith();
  b.substring();
}
void main() {}
''');
      for (final routed in [
        'list_contains',
        'list_index_of',
        'compare_to',
        'string_starts_with',
        'string_ends_with',
        'string_substring',
      ]) {
        expect(
          j.contains(routed),
          isFalse,
          reason: '0-arg call must not be routed to $routed',
        );
      }
    });

    test('one-arg user methods colliding with 2-arg routes fall through', () {
      final j = jsonOf('''
class Bag {
  void insert(int a) {}
  int clamp(int a) => a;
  int putIfAbsent(int a) => a;
  String replaceAll(String a) => a;
}
void f(Bag b) {
  b.insert(1);
  b.clamp(1);
  b.putIfAbsent(1);
  b.replaceAll('a');
}
void main() {}
''');
      for (final routed in [
        'list_insert',
        'math_clamp',
        'map_put_if_absent',
        'string_replace_all',
      ]) {
        expect(
          j.contains(routed),
          isFalse,
          reason: '1-arg call must not be routed to $routed',
        );
      }
    });

    test('user methods taking MORE args than the std route accepts fall '
        'through', () {
      final j = jsonOf('''
class Bag {
  int toInt(int a) => a;
  List<int> toList(int a, int b) => [a, b];
  void clear(int a) {}
  void removeLast(int a) {}
  int codeUnitAt(int a, int b) => a;
}
void f(Bag b) {
  b.toInt(1);
  b.toList(1, 2);
  b.clear(1);
  b.removeLast(1);
  b.codeUnitAt(1, 2);
}
void main() {}
''');
      for (final routed in [
        '"to_int"',
        'list_to_list',
        'list_clear',
        'list_pop',
        'string_code_unit_at',
      ]) {
        expect(
          j.contains(routed),
          isFalse,
          reason: 'over-arity call must not be routed to $routed',
        );
      }
    });

    test('genuine collection calls keep their std routes (no regression)', () {
      final j = jsonOf('''
void f(List<int> xs, Map<String, int> m, String s) {
  xs.add(1);
  xs.insert(0, 2);
  xs.contains(3);
  xs.indexOf(4);
  xs.clear();
  xs.removeLast();
  xs.toList();
  xs.join(',');
  xs.sublist(0, 1);
  m.containsKey('a');
  m.putIfAbsent('a', () => 1);
  s.substring(0, 1);
  s.startsWith('a');
  s.padLeft(3, '0');
  s.codeUnitAt(0);
  (1.5).toInt();
  (1).clamp(0, 2);
}
void main() {}
''');
      for (final routed in [
        'list_push',
        'list_insert',
        'list_contains',
        'list_index_of',
        'list_clear',
        'list_pop',
        'list_to_list',
        'list_join',
        'list_slice',
        'map_contains_key',
        'map_put_if_absent',
        'string_substring',
        'string_starts_with',
        'string_pad_left',
        'string_code_unit_at',
        '"to_int"',
        'math_clamp',
      ]) {
        expect(j.contains(routed), isTrue, reason: 'lost the route $routed');
      }
    });

    test(
      'user class with colliding zero-arg methods executes correctly',
      () async {
        expect(
          await run('''
class Bag {
  List<int> split() => [1, 2, 3];
  int indexOf() => 7;
}
void main() {
  final b = Bag();
  print(b.split());
  print(b.indexOf());
}
'''),
          '[1, 2, 3]\n7',
        );
      },
    );
  });
}
