String classifyNum(num value) {
  switch (value) {
    case 0:
      return 'zero';
    case 1:
    case 2:
    case 3:
      return 'small';
    default:
      return 'other';
  }
}

String classifyString(String value) {
  switch (value) {
    case '':
      return 'empty';
    case 'a':
    case 'b':
      return 'short';
    default:
      return 'long';
  }
}

void main() {
  for (final n in [0, 1, 2, 5, -1]) {
    print('$n:${classifyNum(n)}');
  }
  for (final s in ['', 'a', 'hello']) {
    print('$s:${classifyString(s)}');
  }
}
