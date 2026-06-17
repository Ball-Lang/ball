String describe() {
  final point = (10, 20);
  final (a, b) = point;
  return '$a,$b';
}

void main() {
  print(describe());
}
