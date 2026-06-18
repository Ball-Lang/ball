// A closure created inside a C-style collection-for must capture THAT
// iteration's loop variable (the comprehension analogue of conformance 229).
void main() {
  final fns = [for (var i = 0; i < 3; i++) () => i];
  print([for (var f in fns) f()]);
}
