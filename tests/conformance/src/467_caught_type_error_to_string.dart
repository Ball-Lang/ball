// The observable STRING FORM of a caught Dart `TypeError` — the value a failed
// cast binds into a `catch` clause (issue #641).
//
// `463`/`465` pinned what a caught `StateError` reads; nothing pinned the other
// built-in error a Ball program can catch. A cast pattern (`case var x as int`)
// ASSERTS its type: a mismatch THROWS rather than falling through (fixture
// `302_cast_patterns` proves the throw happens, but it prints a hardcoded
// literal from its catch body, so it cannot see the value at all).
//
// Dart's failed cast raises a `TypeError` whose `toString()` is
//   type '<runtime type>' is not a subtype of type '<target>' in type cast
// and — unlike `StateError` ("Bad state: …"), `FormatException` and
// `RangeError` — it carries NO type-name prefix: `_TypeError.toString()` IS its
// message. This golden is produced by running THIS FILE on the Dart SDK
// (`generate_conformance.dart` captures `dart run`'s stdout), so the reference
// is real Dart, not any engine's current string.
//
// The last two lines also pin that an `on TypeError catch` clause MATCHES the
// value a failed cast raises — a target whose cast throws an untyped/native
// fault sails straight past that clause.

void report(String label, Object? value) {
  try {
    switch (value) {
      case var x as int:
        print('$label: matched $x');
    }
  } catch (e) {
    print(e);
    print(e.toString());
    print('$label: caught $e');
  }
}

String typedClause(Object? value) {
  try {
    switch (value) {
      case var x as String:
        return 'matched $x';
    }
  } on TypeError catch (e) {
    return 'on TypeError: $e';
  }
  return 'unreached';
}

void main() {
  report('int', 42);
  report('String', 'hi');
  report('double', 1.5);
  report('bool', true);
  report('Null', null);
  print(typedClause('ok'));
  print(typedClause(7));
}
