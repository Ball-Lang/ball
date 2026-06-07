bool sideEffect(String tag, bool v) {
  print('eval:$tag');
  return v;
}

void main() {
  // && short-circuits on false
  print((sideEffect('a', false) && sideEffect('b', true)).toString());
  // || short-circuits on true
  print((sideEffect('c', true) || sideEffect('d', false)).toString());
  // No short-circuit when first doesn't match
  print((sideEffect('e', true) && sideEffect('f', false)).toString());
}
