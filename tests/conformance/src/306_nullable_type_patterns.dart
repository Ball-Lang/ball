// Nullable type patterns (`int?`, `String?`) match null OR the base type, while
// a null-check pattern (`var v?`) matches only non-null and binds the value.

String maybeInt(Object? x) => switch (x) {
  int? v => 'int?:$v',
  _ => 'other',
};

String present(int? x) => switch (x) {
  var v? => 'present:$v',
  _ => 'absent',
};

String nstmt(Object? x) {
  switch (x) {
    case String? s:
      return 'str?:$s';
    default:
      return 'other';
  }
}

void main() {
  print(maybeInt(7));
  print(maybeInt(null));
  print(maybeInt('s'));
  print(present(42));
  print(present(null));
  print(nstmt('hi'));
  print(nstmt(null));
  print(nstmt(7));
}
