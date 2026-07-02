// Regression/documentation fixture for the type-literal promotion heuristic
// (dart/encoder/lib/encoder.dart, _hasEnclosingDeclaration): a bare
// reference to one of the 11 builtin type names (int, double, num, String,
// bool, List, Map, Set, Object, Symbol, dynamic) is only a field/variable
// read when something in the LEXICAL/OWN-CLASS scope actually declares that
// name.
//
// Investigated for issue #160, which assumed a field declared only on a
// SUPERCLASS (never on the referencing class itself) should shadow the type
// the same way an own-class field does. Verified against `dart run` (the
// project's conformance oracle) that this is NOT the case: Dart's
// unqualified-identifier resolution does not let an inherited-only member
// shadow a same-named visible type — see dart-lang/sdk#7051 ("Inherited
// member with same name as enclosing class not shadowed by specification").
// So the encoder's existing behavior (walking only the enclosing class's OWN
// field declarations, never the `extends` chain) is correct as-is; #160 was
// closed as not-a-bug.
class Base {
  var List = [10, 20, 30];
}

class Sub extends Base {
  // `List` is only inherited here (declared on Base, not on Sub), so the
  // unqualified reference below resolves to the built-in `List` type —
  // matching `dart run` exactly, including its `==` behavior on the type.
  void method() {
    print(List);
    print(List == List);
  }
}

void main() {
  Sub().method();
}
