String describe(Map<String, int> m) {
  if (m.isEmpty) return 'empty';
  switch (m) {
    case {'x': var v}:
      return 'single:$v';
    case {'a': var a, 'b': var b}:
      return 'pair:$a,$b';
    default:
      return 'other:${m.length}';
  }
}

void main() {
  print(describe({}));
  print(describe({'x': 9}));
  print(describe({'a': 1, 'b': 2}));
  print(describe({'a': 1, 'b': 2, 'c': 3}));
}
