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

/// The names `DartEncoder.builtinAccessorGetters` is expected to hold,
/// restated here INDEPENDENTLY of the encoder.
///
/// The two halves of this suite read the route table differently on purpose.
/// The per-name matrix below reads the REAL table, so a route added without
/// its receiver seam fails with no test edit. This literal is the other half:
/// it pins WHICH names that table holds, so a route deleted — or swapped for
/// another, which leaves the count untouched — is a failure rather than a
/// quietly smaller population for the matrix to iterate.
const expectedBuiltinAccessorGetters = <String>{
  // `_directGetterRoutes`' seven, one `std` call each.
  'sign',
  'isNaN',
  'isFinite',
  'isInfinite',
  'isEmpty',
  'isNotEmpty',
  'runes',
  // The three composites, each handled at its own call site.
  'isEven',
  'isOdd',
  'reversed',
};

/// Everything the closed-set gate objects to in [candidate]; empty ⇒ accepted.
///
/// The gate is a FUNCTION so the negative controls below can feed it mutated
/// route tables — a deletion, a swap, a rename — and prove it rejects each
/// one. An assertion written inline against the real table can only ever show
/// that today's table passes, which is the very same green a gate with no
/// teeth prints (issue #786).
List<String> closedSetComplaints(Set<String> candidate) {
  final complaints = <String>[];
  if (candidate.length < expectedBuiltinAccessorGetters.length) {
    complaints.add(
      'the set holds ${candidate.length} names, below the measured '
      '${expectedBuiltinAccessorGetters.length}',
    );
  }
  for (final name in const ['isEmpty', 'isNotEmpty']) {
    if (!candidate.contains(name)) {
      complaints.add('`$name` is missing');
    }
  }
  return complaints;
}

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
    test('the closed set is exactly the table the encoder routes', () {
      expect(
        closedSetComplaints(DartEncoder.builtinAccessorGetters),
        isEmpty,
        reason:
            'the encoder routes ${DartEncoder.builtinAccessorGetters.toList()}',
      );
      // Every name in the set really IS routed — proven by the control leg of
      // each per-name case below, which asserts a core receiver still calls a
      // base function rather than emitting a `fieldAccess`.
      expect(DartEncoder.builtinAccessorGetters, contains('isEmpty'));
      expect(DartEncoder.builtinAccessorGetters, contains('isNotEmpty'));
    });

    // ── The gate's own negative controls (#786) ───────────────────────
    //
    // The per-name matrix DERIVES its cases from the route table, so a route
    // deleted from that table does not fail the matrix — it shrinks it, and a
    // smaller green run is indistinguishable from a complete one. The closed
    // set is what makes that visible, and these cases are what prove the
    // closed set can see it: each feeds `closedSetComplaints` a table mutated
    // the way a careless edit would mutate it.

    test('the gate REJECTS a deleted route', () {
      final deleted = {...DartEncoder.builtinAccessorGetters}..remove('isEven');
      expect(
        closedSetComplaints(deleted),
        isNotEmpty,
        reason:
            'dropping `isEven` from the table silently drops its seven matrix '
            'cases with it — the gate has to say so',
      );
    });

    test('the gate REJECTS a swapped route', () {
      // The mutation a count alone cannot see: one name out, one name in,
      // total unchanged. The matrix would then iterate a DIFFERENT population
      // than the one the docs, the rules file and fixture 476 all name.
      final swapped = {...DartEncoder.builtinAccessorGetters}
        ..remove('isEven')
        ..add('isBlank');
      expect(
        closedSetComplaints(swapped),
        isNotEmpty,
        reason:
            '`isEven` left the table and `isBlank` took its slot, so the count '
            'is untouched and the routed population is not',
      );
    });

    test('the gate REJECTS a renamed direct route', () {
      final renamed = {...DartEncoder.builtinAccessorGetters}
        ..remove('runes')
        ..add('codeUnits');
      expect(closedSetComplaints(renamed), isNotEmpty);
    });

    test('the gate REJECTS a route added without the expected list', () {
      // An ADDED route is welcome, but it is not silent: the one-line edit to
      // `expectedBuiltinAccessorGetters` is the acknowledgement that the new
      // name was considered, and the matrix is what then proves it brought its
      // receiver seam. Without that edit the prose in `.claude/rules/dart.md`,
      // `docs/TESTING_STRATEGY.md` and `dart/encoder/AGENTS.md` — all of which
      // name this set's size — would drift from the code in silence.
      final added = {...DartEncoder.builtinAccessorGetters, 'codeUnits'};
      expect(closedSetComplaints(added), isNotEmpty);
    });

    test('the gate ACCEPTS the table it is bounding', () {
      // The positive control: the cases above must fail for the mutation they
      // name, not because the gate rejects everything.
      expect(closedSetComplaints({...expectedBuiltinAccessorGetters}), isEmpty);
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

      test('`$name` read through `this.` resolves to the member', () {
        // `this` is the receiver whose type needs no search at all: it is the
        // enclosing declaration. A seam that cannot prove THIS one proves
        // nothing (issue #697, round-1 review of PR #731).
        final json = encodeToJson('''
class Holder {
  $fieldType $name;
  Holder(this.$name);

  Object? readViaThis() {
    return this.$name;
  }
}
''');
        expect(
          fieldAccessesTo(json, name),
          isNotEmpty,
          reason:
              '`this` names the very class that declares `$name`. '
              'Calls were: ${calledFunctions(json)}',
        );
      });

      test('`$name` read through `super.` resolves to the member', () {
        final json = encodeToJson('''
class Base {
  $fieldType $name;
  Base(this.$name);
}

class Derived extends Base {
  Derived($fieldType v) : super(v);

  Object? readViaSuper() {
    return super.$name;
  }
}
''');
        expect(
          fieldAccessesTo(json, name),
          isNotEmpty,
          reason:
              '`super` names the superclass this unit also declares. '
              'Calls were: ${calledFunctions(json)}',
        );
      });

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

    // ── The seam's other proof routes ─────────────────────────────────
    //
    // Each case below exercises one shape of receiver the per-name matrix
    // above does not reach. `isEmpty` stands in for the whole set here; the
    // matrix is what proves the set is closed.

    test('a MIXIN this unit declares supplies the member', () {
      final json = encodeToJson('''
mixin Sized {
  int isEmpty = 0;
}

Object? read(Sized s) {
  return s.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('a mixin reached through `on` supplies the member', () {
      final json = encodeToJson('''
mixin Base {
  int isEmpty = 0;
}

mixin Derived on Base {}

Object? read(Derived d) {
  return d.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('an ENUM this unit declares supplies the member', () {
      final json = encodeToJson('''
enum Size {
  small,
  large;

  bool get isEmpty => this == Size.small;
}

Object? read(Size s) {
  return s.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('an INTERFACE this unit declares supplies the member', () {
      final json = encodeToJson('''
class Sized {
  int isEmpty = 0;
}

class Holder implements Sized {
  @override
  int isEmpty = 1;
}

Object? read(Holder h) {
  return h.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('`this` inside a MIXIN resolves to the mixin\'s member', () {
      final json = encodeToJson('''
mixin Sized {
  int isEmpty = 0;

  Object? read() {
    return this.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('`this` inside an ENUM resolves to the enum\'s member', () {
      final json = encodeToJson('''
enum Size {
  small,
  large;

  bool get isEmpty => this == Size.small;

  Object? read() {
    return this.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('`this` inside an EXTENSION is the extended type', () {
      // The receiver is the `on` type, not the extension — so an extension on
      // a user class that declares the member proves it.
      final json = encodeToJson('''
class Holder {
  int isEmpty = 0;
}

extension Reader on Holder {
  Object? read() {
    return this.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('`this` inside an extension on a dart:core type KEEPS the route', () {
      // The mirror image, and the reason the extension case reads the `on`
      // clause rather than the extension name: inside `extension on String`,
      // `this.isEmpty` IS `String.isEmpty` and must stay routed.
      final json = encodeToJson('''
extension Reader on String {
  Object? read() {
    return this.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('`this` inside an EXTENSION TYPE resolves to its body member', () {
      // An extension type's BODY members are declarations like any other. Its
      // REPRESENTATION parameter deliberately is NOT — see the next case.
      final json = encodeToJson('''
extension type Counter(int raw) {
  int get isEmpty => raw;

  Object? read() {
    return this.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('an extension type is a provable receiver for a local too', () {
      final json = encodeToJson('''
extension type Counter(int raw) {
  int get isEmpty => raw;
}

Object? read(Counter c) {
  return c.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('an extension type REPRESENTATION parameter is not a declaration', () {
      // A documented, deliberate decline: this encoder models the
      // representation parameter nowhere — it reaches neither the descriptor
      // nor `metadata['fields']` — so treating it as a declaration HERE would
      // make the seam the only part of the encoder that believes in it.
      final json = encodeToJson('''
extension type Counter(int isEmpty) {
  Object? read() {
    return this.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('`super` inside an extension has no in-unit supertype', () {
      // `super` in an extension body is not valid Dart, but `parseString`
      // accepts it, and the seam must answer `no proof` rather than reach for
      // the extension's `on` type — which is what `this` denotes, not `super`.
      final json = encodeToJson('''
class Holder {
  int isEmpty = 0;
}

extension Reader on Holder {
  Object? read() {
    return super.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('`super` inside an ENUM has no in-unit supertype', () {
      final json = encodeToJson('''
enum Size {
  small;

  Object? read() {
    return super.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
    });

    test('`super` inside an extension TYPE has no in-unit supertype', () {
      final json = encodeToJson('''
extension type Counter(int raw) {
  Object? read() {
    return super.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
    });

    test('`super` with no enclosing declaration at all gives no proof', () {
      // Top-level `super` is not valid Dart either; the walk must terminate at
      // the compilation unit rather than run off the end.
      final json = encodeToJson('''
Object? read() {
  return super.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('`this` with no enclosing declaration at all gives no proof', () {
      final json = encodeToJson('''
Object? read() {
  return this.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('`this` bound to a local first is still a provable receiver', () {
      // The binding walk resolves `me`'s initializer, which is `this`.
      final json = encodeToJson('''
class Holder {
  int isEmpty = 0;

  Object? read() {
    var me = this;
    return me.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test(
      '`this` in a class that does NOT declare the member keeps the route',
      () {
        // The enclosing class is proof of the receiver's TYPE, never proof of
        // the member: a class with no `isEmpty` of its own is a `dynamic`-ish
        // receiver like any other, so the route must stand.
        final json = encodeToJson('''
class Holder {
  String text = '';

  Object? read() {
    return this.text.isEmpty;
  }
}
''');
        expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
        expect(calledFunctions(json), contains('std.string_is_empty'));
      },
    );

    test('`super` whose superclass does NOT declare it keeps the route', () {
      final json = encodeToJson('''
class Base {
  int size = 0;
}

class Derived extends Base {
  Object? read() {
    return super.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('`super` with no `extends` clause gives no proof', () {
      // `class Holder { … super.isEmpty }` has `Object` above it, which this
      // unit does not declare — so there is nothing to prove the member with,
      // and in particular the class's OWN declaration must not stand in for
      // its superclass's.
      final json = encodeToJson('''
class Holder {
  int isEmpty = 0;

  Object? read() {
    return super.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('`super` inside a mixin reaches its `on` constraint', () {
      final json = encodeToJson('''
class Base {
  int isEmpty = 0;
}

mixin Reader on Base {
  Object? read() {
    return super.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('a FIELD of the enclosing class is a provable receiver', () {
      final json = encodeToJson('''
class Holder {
  int isEmpty = 0;
}

class Owner {
  Holder held = Holder();

  Object? read() {
    return held.isEmpty;
  }
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('a TOP-LEVEL variable is a provable receiver', () {
      final json = encodeToJson('''
class Holder {
  int isEmpty = 0;
}

Holder held = Holder();

Object? read() {
  return held.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('a NAMED-constructor receiver resolves to its class', () {
      // `new Holder.empty()` is the one spelling an UNRESOLVED AST reports as
      // an `InstanceCreationExpression`, and it reports `Holder` as an import
      // PREFIX — the same misparse `_encodeInstanceCreation` compensates for.
      // Without `new`, `Holder.empty()` parses as a `MethodInvocation` that is
      // indistinguishable from a call to a static method returning anything at
      // all, so the seam declines it and the route stands (the next case).
      final json = encodeToJson('''
class Holder {
  int isEmpty = 0;
  Holder.empty();
}

// ignore: unnecessary_new
Object? read() {
  return new Holder.empty().isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isNotEmpty);
    });

    test('an unprefixed `Class.named()` call is NOT proof', () {
      // Deliberately conservative: on an unresolved AST this is the same node
      // shape as `Holder.emptyString()` returning a `String`, so the seam has
      // no proof and the route must stand.
      final json = encodeToJson('''
class Holder {
  int isEmpty = 0;
  Holder.empty();
}

Object? read() {
  return Holder.empty().isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('a class declared with a CYCLE terminates and declines', () {
      // Malformed Dart, but it parses — and the `seen` guard is what keeps the
      // supertype walk from recursing forever on it.
      final json = encodeToJson('''
class A extends B {}

class B extends A {}

Object? read(A a) {
  return a.isEmpty;
}
''');
      expect(
        fieldAccessesTo(json, 'isEmpty'),
        isEmpty,
        reason: 'neither class declares `isEmpty`, so the route must stand',
      );
    });

    test('a class that does NOT declare the member keeps the route', () {
      final json = encodeToJson('''
class Holder {
  int size = 0;
}

Object? read(Holder h) {
  return h.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });

    test('an IMPORT-PREFIXED type is another library, so the route stands', () {
      final json = encodeToJson('''
import 'other.dart' as other;

Object? viaAnnotation(other.Holder h) {
  return h.isEmpty;
}

// ignore: unnecessary_new
Object? viaConstruction() {
  return new other.Holder().isEmpty;
}
''');
      expect(
        fieldAccessesTo(json, 'isEmpty'),
        isEmpty,
        reason:
            "this unit cannot see `other.Holder`'s members, so it has no proof "
            'and must keep the encoding it has always had',
      );
    });

    test('a NON-named type annotation gives no proof', () {
      final json = encodeToJson('''
Object? read() {
  void Function() f = () {};
  return f.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
    });

    test('an UNINITIALIZED, unannotated local gives no proof', () {
      final json = encodeToJson('''
Object? read() {
  var x;
  return x.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
    });

    test('an UNBOUND receiver name gives no proof', () {
      final json = encodeToJson('''
Object? read() {
  return somethingNobodyDeclared.isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
    });

    test('a receiver that is neither an identifier nor a construction', () {
      final json = encodeToJson('''
Object? source() {
  return '';
}

Object? read() {
  return source().isEmpty;
}
''');
      expect(fieldAccessesTo(json, 'isEmpty'), isEmpty);
      expect(calledFunctions(json), contains('std.string_is_empty'));
    });
  });
}
