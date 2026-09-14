/// Issue #697 A — a member a USER class declares wins over the built-in
/// accessor the encoder routes by the same name.
///
/// The encoder routes a small, fixed set of getter names straight onto `std` /
/// `std_collections` base calls, because without type resolution the name is
/// all it has. Before #697 that route consulted nothing at all, so a class
/// declaring `int isEmpty` encoded `b.isEmpty` as `std.string_is_empty(b)` —
/// the encoded program carried no `fieldAccess` for the user's member anywhere,
/// and every engine then faithfully ran the wrong program and agreed on the
/// wrong answer (a member of #488's receiver-type family, not of #681's
/// precedence family).
///
/// This suite is the CLOSED SET over that routing: the cases are derived from
/// `DartEncoder.builtinAccessorGetters`, the encoder's own single source of
/// truth for which names it diverts. Adding a route without teaching it the
/// user-member seam fails here, with no test edit needed.
///
/// Both directions are pinned, because the fix must be a refinement and not a
/// removal: the same accessor on a receiver the unit does NOT declare (a
/// `String`, `List`, `int` or `double` local) must keep the route it has always
/// had.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

/// Every `fieldAccess` node in a decoded Ball program's JSON whose field is
/// [field].
List<Map<String, Object?>> fieldAccessesTo(Object? node, String field) {
  final found = <Map<String, Object?>>[];
  void walk(Object? n) {
    if (n is List) {
      for (final element in n) {
        walk(element);
      }
      return;
    }
    if (n is! Map) return;
    final fa = n['fieldAccess'];
    if (fa is Map && fa['field'] == field) {
      found.add(fa.cast<String, Object?>());
    }
    for (final value in n.values) {
      walk(value);
    }
  }

  walk(node);
  return found;
}

/// Every `<module>.<function>` pair the program calls.
Set<String> calledFunctions(Object? node) {
  final found = <String>{};
  void walk(Object? n) {
    if (n is List) {
      for (final element in n) {
        walk(element);
      }
      return;
    }
    if (n is! Map) return;
    final call = n['call'];
    if (call is Map) found.add('${call['module']}.${call['function']}');
    for (final value in n.values) {
      walk(value);
    }
  }

  walk(node);
  return found;
}

/// The decoded proto3-JSON form of [source] encoded as a Ball program.
Map<String, Object?> encodeToJson(String source) {
  final program = DartEncoder().encode(source, name: 'probe');
  return jsonDecode(jsonEncode(encodeBallFileJson(program)))
      as Map<String, Object?>;
}

/// The Dart type a probe field of accessor [name] is declared with. `dynamic`
/// everywhere would do, but a plausible type keeps the probe source valid Dart
/// so the same shapes can be pasted into a conformance fixture.
String _fieldTypeFor(String name) => switch (name) {
  'runes' => 'String',
  'sign' => 'double',
  'reversed' => 'List<int>',
  'isEmpty' => 'int',
  'isNotEmpty' => 'String',
  _ => 'bool',
};

/// A receiver whose type is a `dart:core` type that really declares [name],
/// so the route must still fire.
({String declaration, String receiver}) _coreReceiverFor(String name) =>
    switch (name) {
      'sign' ||
      'isEven' ||
      'isOdd' => (declaration: 'int n = 4;', receiver: 'n'),
      'isNaN' ||
      'isFinite' ||
      'isInfinite' => (declaration: 'double d = 2.5;', receiver: 'd'),
      'reversed' => (declaration: 'List<int> xs = <int>[1];', receiver: 'xs'),
      _ => (declaration: "String s = 'hi';", receiver: 's'),
    };

void main() {
  group('a built-in accessor name a user class declares (#697)', () {
    test('the closed set is non-empty and is what the encoder routes', () {
      // A positive floor: an empty set would make every case below vacuous.
      expect(
        DartEncoder.builtinAccessorGetters.length,
        greaterThanOrEqualTo(6),
      );
      // Every name in the set really IS routed — proven by the control leg of
      // each per-name case below, which asserts a core receiver still calls a
      // base function rather than emitting a `fieldAccess`.
      expect(DartEncoder.builtinAccessorGetters, contains('isEmpty'));
      expect(DartEncoder.builtinAccessorGetters, contains('isNotEmpty'));
    });

    for (final name in DartEncoder.builtinAccessorGetters) {
      final fieldType = _fieldTypeFor(name);

      test('`$name` declared as a FIELD resolves to the field', () {
        final json = encodeToJson('''
class Holder {
  $fieldType $name;
  Holder(this.$name);
}

Object? readViaLocal() {
  Holder h = Holder(Holder(null as dynamic).$name);
  return h.$name;
}
''');
        expect(
          fieldAccessesTo(json, name),
          isNotEmpty,
          reason:
              'the user declared `$name`, so the encoded program must contain '
              'a fieldAccess for it. Calls were: ${calledFunctions(json)}',
        );
      });

      test('`$name` declared as a GETTER resolves to the getter', () {
        final json = encodeToJson('''
class Holder {
  final int stored;
  Holder(this.stored);
  $fieldType get $name => throw UnimplementedError();
}

Object? read(Holder h) {
  return h.$name;
}
''');
        expect(
          fieldAccessesTo(json, name),
          isNotEmpty,
          reason:
              'a user GETTER named `$name` is the same shape as a field. '
              'Calls were: ${calledFunctions(json)}',
        );
      });

      test(
        '`$name` on an INSTANCE-CREATION receiver resolves to the member',
        () {
          final json = encodeToJson('''
class Holder {
  $fieldType $name;
  Holder(this.$name);
}

Object? read() {
  return Holder(null as dynamic).$name;
}
''');
          expect(
            fieldAccessesTo(json, name),
            isNotEmpty,
            reason:
                'the receiver names its own class, so no other proof is needed. '
                'Calls were: ${calledFunctions(json)}',
          );
        },
      );

      test('`$name` INHERITED from a base class in the unit resolves too', () {
        final json = encodeToJson('''
class Base {
  $fieldType $name;
  Base(this.$name);
}

class Derived extends Base {
  Derived($fieldType v) : super(v);
}

Object? read(Derived d) {
  return d.$name;
}
''');
        expect(
          fieldAccessesTo(json, name),
          isNotEmpty,
          reason:
              'the member is declared by a superclass this unit also declares. '
              'Calls were: ${calledFunctions(json)}',
        );
      });

      test('`$name` on a dart:core receiver KEEPS its route', () {
        final core = _coreReceiverFor(name);
        final json = encodeToJson('''
Object? read() {
  ${core.declaration}
  return ${core.receiver}.$name;
}
''');
        expect(
          fieldAccessesTo(json, name),
          isEmpty,
          reason:
              'a `dart:core` receiver must still be routed onto a base call — '
              'the fix is a refinement, not a removal. '
              'Calls were: ${calledFunctions(json)}',
        );
        expect(
          calledFunctions(json),
          isNotEmpty,
          reason: 'the route must emit a base call for `$name`',
        );
      });
    }
  });
}
