int collatzSteps(int n) {
  var steps = 0;
  while (n != 1) {
    if (n % 2 == 0) {
      n = n ~/ 2;
    } else {
      n = 3 * n + 1;
    }
    steps++;
  }
  return steps;
}

void main() {
  print(collatzSteps(1).toString());
  print(collatzSteps(6).toString());
  print(collatzSteps(27).toString());
}
