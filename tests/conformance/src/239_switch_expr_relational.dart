String classify(Object? value) {
  return switch (value) {
    null => 'null',
    0 => 'zero',
    1 || 2 || 3 || 4 || 5 || 6 || 7 || 8 || 9 => 'small-pos',
    10 || 11 || 12 => 'large-pos',
    -1 || -2 || -3 || -4 || -5 => 'negative',
    double d => 'double:$d',
    _ => 'other',
  };
}

void main() {
  for (final v in [null, 0, 3, 12, -5, 1.5, 99]) {
    print('$v:${classify(v)}');
  }
}
