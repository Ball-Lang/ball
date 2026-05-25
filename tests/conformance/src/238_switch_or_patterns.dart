String tag(int n) {
  switch (n) {
    case 0:
      return 'zero';
    case 1 || 2 || 3:
      return 'small';
    case -1 || -2:
      return 'neg';
    default:
      return 'other';
  }
}

void main() {
  for (final n in [0, 1, 2, 3, 5, -1, -2, -3]) {
    print('$n:${tag(n)}');
  }
}
