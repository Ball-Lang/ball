int square(int x) => x * x;

int sumOfSquares(int a, int b) => square(a) + square(b);

void main() {
  print('${sumOfSquares(3, 4)}');
  print('${sumOfSquares(5, 12)}');
}
