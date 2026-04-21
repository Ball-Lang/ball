bool isEven(int n) => n % 2 == 0;
bool isPositive(int n) => n > 0;
int absolute(int n) => n < 0 ? -n : n;

void main() {
  print(isEven(4));
  print(isEven(7));
  print(isPositive(5));
  print(isPositive(-3));
  print(absolute(-42));
  print(absolute(17));
  
  int sum = 0;
  for (int i = 1; i <= 20; i++) {
    if (isEven(i)) sum += i;
  }
  print(sum);
}
