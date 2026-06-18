// Collection-for (for-each) and collection-if elements in a list literal.
// Regression for issue #55: these were never exercised by the corpus.
void main() {
  final xs = [1, 2, 3, 4];
  print([for (var x in xs) x * x]);
  print([for (var x in xs) if (x % 2 == 0) x]);
  print([for (var x in xs) if (x > 2) x else -x]);
}
