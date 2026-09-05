// #531 - a BUILT-IN exception class torn off as `FormatException.new(...)` and
// thrown must keep its type tag, so a typed `on FormatException catch` matches.
//
// Two independent defects met on this one line:
//   * The Dart reference engine's `_evalReference` only synthesized a class-ref
//     sentinel for a name with a registered TypeDefinition plus a constructor
//     or static method - which no built-in exception name has - so evaluating
//     the tear-off's `self` threw `Undefined variable: "FormatException"`
//     before the throw/catch machinery ever ran. Every self-hosted engine is
//     generated from that same source, so all six failed identically.
//   * The C++ compiler's `throw` arm derived the exception's type name from
//     `call.function` assuming a `mod:Foo.new` shape. For the tear-off shape
//     `call.function` is the bare string "new": nothing to strip, lower-case
//     leading char, so the tag stayed the generic "Exception" and the typed
//     catch could never match.
//
// This fixture deliberately THROWS rather than merely constructing: a bare
// `final e = FormatException.new("x"); print(e.message);` fails for a THIRD,
// unrelated reason (the arg0 -> message rename lives only inside the std.throw
// handler, not in field access), which would make the fixture red for a defect
// this change does not address.

String classify(int n) {
  try {
    if (n < 0) {
      throw FormatException.new('negative: $n');
    }
    if (n == 0) {
      throw StateError.new('zero');
    }
    return 'ok: $n';
  } on FormatException catch (e) {
    return 'format: ${e.message}';
  } on StateError catch (e) {
    return 'state: ${e.message}';
  }
}

void main() {
  // The exact shape of #531: a torn-off built-in exception, caught by type.
  try {
    throw FormatException.new('bad input');
  } on FormatException catch (e) {
    print(e.message);
  }

  // The typed catch must pick the RIGHT arm out of several.
  print(classify(-2));
  print(classify(0));
  print(classify(5));

  // Control: the ordinary construction form still throws and catches the same.
  try {
    throw FormatException('direct');
  } on FormatException catch (e) {
    print(e.message);
  }
}
