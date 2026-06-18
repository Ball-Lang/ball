// C-style collection-for inside a list literal — the exact shape from issue
// #55 that silently round-tripped to []. Includes a nested collection-for.
void main() {
  print([for (var i = 0; i < 5; i++) i * i]);
  print([for (var i = 3; i >= 0; i--) i]);
  print([for (var i = 0; i < 3; i++) for (var j = 0; j < 2; j++) i * 10 + j]);
}
