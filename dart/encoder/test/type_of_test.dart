/// Issue #489 — the Dart encoder maps `<expr>.runtimeType.toString()` onto the
/// universal `std.type_of` base function.
///
/// `type_of` is the one name `ts/encoder` could already emit (for JS `typeof`)
/// that no compiler or engine implemented. Dart has no `typeof`; the single
/// idiom that yields the same thing — a plain type-name STRING — is
/// `<expr>.runtimeType.toString()`. Wiring that chain is what lets a
/// conformance fixture for `type_of` be generated through the standard
/// `generate_conformance.dart` pipeline (fixture provenance, per CLAUDE.md).
///
/// The mapping is deliberately narrow. Its documented carve-outs (see
/// `dart/encoder/AGENTS.md`) are asserted here too, so the scope
/// cannot silently widen: a bare `x.runtimeType` is a `Type` object rather
/// than a string, an interpolated `'${x.runtimeType}'` never goes through
/// `toString()` syntactically, and a null-aware `x?.runtimeType.toString()`
/// must keep its `?.` semantics.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

/// Every `<module>.<fn>` call node in a decoded Ball program's JSON.
List<Map<String, Object?>> callsTo(Object? node, String module, String fn) {
  final found = <Map<String, Object?>>[];
  void walk(Object? n) {
    if (n is List) {
      for (final element in n) {
        walk(element);
      }
      return;
    }
    if (n is! Map) return;
    final call = n['call'];
    if (call is Map && call['module'] == module && call['function'] == fn) {
      found.add(call.cast<String, Object?>());
    }
    for (final value in n.values) {
      walk(value);
    }
  }

  walk(node);
  return found;
}

/// The `{name: value}` field map of a call's `MessageCreation` input.
Map<String, Object?> inputFields(Map<String, Object?> call) {
  final input = call['input'] as Map<String, Object?>;
  final creation = input['messageCreation'] as Map<String, Object?>;
  final fields = (creation['fields'] as List).cast<Map<String, Object?>>();
  return {for (final f in fields) f['name'] as String: f['value']};
}

void main() {
  Map<String, Object?> encode(String source) =>
      jsonDecode(jsonEncode(encodeBallFileJson(DartEncoder().encode(source))))
          as Map<String, Object?>;

  group('std.type_of (#489)', () {
    test(
      '`<expr>.runtimeType.toString()` encodes to std.type_of(value: expr)',
      () {
        final js = encode('''
void main() {
  final x = 5;
  print(x.runtimeType.toString());
}
''');
        final calls = callsTo(js, 'std', 'type_of');
        expect(calls, hasLength(1));
        expect(inputFields(calls.single), {
          'value': {
            'reference': {'name': 'x'},
          },
        });
        // The chain must NOT also produce the generic `.toString()` routing —
        // `type_of` replaces it, it does not wrap it.
        expect(callsTo(js, 'std', 'to_string'), isEmpty);
      },
    );

    test('the encoded program declares type_of as a std base function', () {
      final js = encode('''
void main() {
  print(3.5.runtimeType.toString());
}
''');
      final modules = (js['modules'] as List).cast<Map<String, Object?>>();
      final std = modules.firstWhere((m) => m['name'] == 'std');
      final names = (std['functions'] as List)
          .cast<Map<String, Object?>>()
          .map((f) => f['name'])
          .toList();
      expect(names, contains('type_of'));
    });

    test('a `this.runtimeType.toString()` receiver is mapped too', () {
      final js = encode('''
class Widget {
  String describe() => this.runtimeType.toString();
}

void main() {
  print(Widget().describe());
}
''');
      final calls = callsTo(js, 'std', 'type_of');
      expect(calls, hasLength(1));
      expect(inputFields(calls.single).keys, ['value']);
    });

    test(
      'carve-out: a bare `x.runtimeType` keeps its fieldAccess encoding',
      () {
        final js = encode('''
void main() {
  final x = 5;
  final t = x.runtimeType;
  print(t);
}
''');
        expect(callsTo(js, 'std', 'type_of'), isEmpty);
        expect(jsonEncode(js), contains('runtimeType'));
      },
    );

    test("carve-out: an interpolated '\${x.runtimeType}' is not mapped", () {
      final js = encode('''
void main() {
  final x = 5;
  print('type is \${x.runtimeType}');
}
''');
      expect(callsTo(js, 'std', 'type_of'), isEmpty);
      expect(jsonEncode(js), contains('runtimeType'));
    });

    test(
      'carve-out: a null-aware `x?.runtimeType.toString()` is not mapped',
      () {
        final js = encode('''
void main() {
  final Object? x = 5;
  print(x?.runtimeType.toString());
}
''');
        expect(callsTo(js, 'std', 'type_of'), isEmpty);
      },
    );
  });
}
