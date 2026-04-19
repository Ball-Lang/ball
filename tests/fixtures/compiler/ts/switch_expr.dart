String classify(int n) => switch (n) {
      0 => 'zero',
      1 || 2 => 'small',
      _ when n < 0 => 'negative',
      _ => 'big',
    };

String dayName(int d) {
  return switch (d) {
    1 => 'Mon',
    2 => 'Tue',
    3 => 'Wed',
    4 => 'Thu',
    5 => 'Fri',
    6 => 'Sat',
    7 => 'Sun',
    _ => 'unknown',
  };
}

void main() {
  for (final n in [0, 1, 2, 5, -3]) {
    print(classify(n));
  }
  for (final d in [1, 3, 7, 10]) {
    print(dayName(d));
  }
}
