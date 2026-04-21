String classify(int n) {
  if (n < 0) return 'negative';
  if (n == 0) return 'zero';
  if (n < 10) return 'small';
  return 'large';
}

void main() {
  print(classify(-5));
  print(classify(0));
  print(classify(7));
  print(classify(100));
}
