String grade(int score) {
  return switch (score) {
    >= 90 => 'A',
    >= 80 => 'B',
    >= 70 => 'C',
    >= 60 => 'D',
    >= 0 => 'F',
    _ => 'invalid',
  };
}

void main() {
  List<int> scores = [95, 85, 72, 50, -1];
  for (int s in scores) {
    print('$s:${grade(s)}');
  }
}
