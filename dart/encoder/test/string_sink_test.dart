/// Issue #630 — the Dart encoder routes `StringBuffer` onto the universal
/// `std.sink_create` / `std.sink_write` / `std.sink_to_string` base functions.
///
/// Before #630 `StringBuffer()` encoded as a generic constructor
/// (`messageCreation{typeName: "main:StringBuffer"}`) and `sb.write(x)` as a
/// generic method call, which the Dart and TS ENGINES then special-cased by
/// name — with incompatible buffer shapes between them (issue #633) and with no
/// implementation at all in the Rust/C#/Go/Python/C++ compilers or runtimes.
/// That is exactly the #505 shape one level up: implemented by hardcoded name,
/// declared nowhere, divergent between implementations, silently absent on five
/// targets.
///
/// Routing is SYNTACTIC — `generate_conformance.dart` parses without
/// resolution, so `staticType` is null and the receiver-type gate of #488 is
/// unavailable. A receiver counts as a sink when the nearest enclosing scope
/// declares it with a `StringBuffer`/`StringSink` type annotation or a
/// `StringBuffer(...)` initializer, which is why the carve-out tests below
/// (an untracked name, a same-named variable in another function) matter.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

/// Every `<module>.<fn>` call node in a decoded Ball program's JSON.
List<Map<String, Object?>> _callsTo(Object? node, String module, String fn) {
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
Map<String, Object?> _inputFields(Map<String, Object?> call) {
  final input = call['input'] as Map<String, Object?>;
  final creation = input['messageCreation'] as Map<String, Object?>;
  final fields = (creation['fields'] as List?) ?? const [];
  return {
    for (final f in fields.cast<Map<String, Object?>>())
      f['name'] as String: f['value'],
  };
}

void main() {
  Map<String, Object?> encode(String source) =>
      jsonDecode(jsonEncode(encodeBallFileJson(DartEncoder().encode(source))))
          as Map<String, Object?>;

  group('std sink routing (#630)', () {
    test('StringBuffer() encodes to std.sink_create', () {
      final js = encode('''
void main() {
  StringBuffer sb = StringBuffer();
  print(sb.toString());
}
''');
      final creates = _callsTo(js, 'std', 'sink_create');
      expect(creates, hasLength(1));
      // No seed argument ⇒ no `initial` field.
      expect(_inputFields(creates.single), isEmpty);
      // The generic constructor encoding must be GONE — it is what left five
      // targets with no implementation at all.
      expect(jsonEncode(js), isNot(contains('StringBuffer')));
    });

    test('StringBuffer(seed) carries the seed as `initial`', () {
      final js = encode('''
void main() {
  StringBuffer sb = StringBuffer('x');
  print(sb.toString());
}
''');
      final creates = _callsTo(js, 'std', 'sink_create');
      expect(creates, hasLength(1));
      expect(_inputFields(creates.single), {
        'initial': {
          'literal': {'stringValue': 'x'},
        },
      });
    });

    test('write / writeln / writeCharCode all route to std.sink_write', () {
      final js = encode('''
void main() {
  StringBuffer sb = StringBuffer();
  sb.write('a');
  sb.writeln('b');
  sb.writeCharCode(67);
  print(sb.toString());
}
''');
      final writes = _callsTo(js, 'std', 'sink_write');
      expect(writes, hasLength(3));
      for (final w in writes) {
        expect(_inputFields(w).keys, containsAll(<String>['sink', 'text']));
      }
      // `writeln` desugars to write + "\n" (core's own rule), so no separate
      // base function is declared for it.
      expect(
        (js['modules'] as List).cast<Map<String, Object?>>().firstWhere(
          (m) => m['name'] == 'std',
        )['functions'],
        isNot(contains(predicate((f) => (f as Map)['name'] == 'sink_writeln'))),
      );
      // writeCharCode desugars through the existing string_from_char_code.
      expect(_callsTo(js, 'std', 'string_from_char_code'), hasLength(1));
    });

    test('toString / length / isEmpty read back through sink_to_string', () {
      final js = encode('''
void main() {
  StringBuffer sb = StringBuffer();
  sb.write('a');
  print(sb.toString());
  print(sb.length);
  print(sb.isEmpty);
  print(sb.isNotEmpty);
}
''');
      expect(_callsTo(js, 'std', 'sink_to_string'), hasLength(4));
      expect(_callsTo(js, 'std', 'string_length'), hasLength(1));
      expect(_callsTo(js, 'std', 'string_is_empty'), hasLength(2));
    });

    test('a StringBuffer PARAMETER is a sink inside the callee', () {
      final js = encode('''
void appendWord(StringBuffer sink, String word) {
  sink.write(word);
}

void main() {
  StringBuffer out = StringBuffer();
  appendWord(out, 'c');
  print(out.toString());
}
''');
      // The callee's `sink.write(word)` is the reference-semantics leg: it must
      // be a sink_write on the caller's sink, not a generic method call.
      expect(_callsTo(js, 'std', 'sink_write'), hasLength(1));
      expect(_callsTo(js, 'std', 'sink_create'), hasLength(1));
      expect(_callsTo(js, 'std', 'sink_to_string'), hasLength(1));
    });

    test('the encoded program declares the three base functions', () {
      final js = encode('''
void main() {
  StringBuffer sb = StringBuffer();
  sb.write('a');
  print(sb.toString());
}
''');
      final std = (js['modules'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((m) => m['name'] == 'std');
      final names = (std['functions'] as List)
          .cast<Map<String, Object?>>()
          .map((f) => f['name'])
          .toList();
      expect(
        names,
        containsAll(['sink_create', 'sink_write', 'sink_to_string']),
      );
    });

    test('carve-out: `.write` on an untracked receiver stays generic', () {
      final js = encode('''
void main() {
  final sink = openSomething();
  sink.write('a');
}
''');
      expect(_callsTo(js, 'std', 'sink_write'), isEmpty);
    });

    test('carve-out: a same-named local in another function is not a sink', () {
      final js = encode('''
void other() {
  final out = makeThing();
  out.write('a');
}

void main() {
  StringBuffer out = StringBuffer();
  out.write('b');
  print(out.toString());
}
''');
      // Exactly ONE sink_write: `other()`'s `out` is a different scope.
      expect(_callsTo(js, 'std', 'sink_write'), hasLength(1));
    });
  });
}
