String sign(int n) {
  return switch (n) {
    < 0 => 'negative',
    0 => 'zero',
    _ => 'positive',
  };
}

void main() {
  print(sign(-5));
  print(sign(0));
  print(sign(7));
}
