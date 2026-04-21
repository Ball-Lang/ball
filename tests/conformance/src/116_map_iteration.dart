void main() {
  Map<String, int> scores = {
    'Alice': 95,
    'Bob': 87,
    'Charlie': 92,
    'Diana': 88,
  };

  scores.forEach((name, score) {
    print('$name: $score');
  });

  int total = 0;
  scores.forEach((name, score) {
    total += score;
  });
  print('Total: $total');
  print('Count: ${scores.length}');
}
