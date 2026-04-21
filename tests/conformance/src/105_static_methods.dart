class MathUtils {
  static int max(int a, int b) {
    return a > b ? a : b;
  }

  static int min(int a, int b) {
    return a < b ? a : b;
  }

  static int clamp(int value, int low, int high) {
    if (value < low) return low;
    if (value > high) return high;
    return value;
  }

  static int factorial(int n) {
    int result = 1;
    for (int i = 2; i <= n; i++) {
      result *= i;
    }
    return result;
  }
}

void main() {
  print(MathUtils.max(10, 20));
  print(MathUtils.min(10, 20));
  print(MathUtils.clamp(5, 0, 10));
  print(MathUtils.clamp(-5, 0, 10));
  print(MathUtils.clamp(15, 0, 10));
  print(MathUtils.factorial(5));
  print(MathUtils.factorial(0));
}
