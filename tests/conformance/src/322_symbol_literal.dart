// A symbol literal must print exactly like native Dart: `print(#foo)` is
// `Symbol("foo")` (#65). The engine previously leaked the bare name ("foo").
// Also exercises a dotted symbol and a symbol inside string interpolation.
void main() {
  print(#foo);
  print(#alpha_beta);
  print(#a.b);
  print('sym: ${#bar}');
  var s = #qux;
  print(s);
}
