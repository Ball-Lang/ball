List<int> range(int start, int end, int step) {
  List<int> result = [];
  for (int i = start; i < end; i += step) {
    result.add(i);
  }
  return result;
}

List<int> fibSequence(int count) {
  List<int> result = [];
  int a = 0;
  int b = 1;
  for (int i = 0; i < count; i++) {
    result.add(a);
    int temp = a + b;
    a = b;
    b = temp;
  }
  return result;
}

List<int> primes(int limit) {
  List<int> result = [];
  for (int n = 2; n <= limit; n++) {
    bool isPrime = true;
    for (int i = 2; i * i <= n; i++) {
      if (n % i == 0) {
        isPrime = false;
        break;
      }
    }
    if (isPrime) result.add(n);
  }
  return result;
}

void main() {
  print(range(0, 10, 2));
  print(range(1, 20, 3));
  print(fibSequence(10));
  print(primes(30));
}
