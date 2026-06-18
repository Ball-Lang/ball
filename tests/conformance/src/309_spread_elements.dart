// Spread (`...`) and null-aware spread (`...?`) elements in list literals.
// Regression for issue #55: spread silently NESTED instead of splicing.
// The `...?n` over an uninitialized nullable also covers the __no_init__ fix.
void main() {
  final a = [1, 2];
  final b = [3, 4];
  print([0, ...a, ...b, 5]);
  List<int>? n;
  print([0, ...?n, 99]);
  print([for (var x in a) ...[x, x * 10]]);
}
