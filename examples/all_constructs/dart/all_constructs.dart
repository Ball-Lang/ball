// Tests all constructs that should round-trip through ball encoding.

// --- Arithmetic & comparison ---
int add(int a, int b) => a + b;

int subtract(int a, int b) => a - b;

int multiply(int a, int b) => a * b;

double divide(double a, double b) => a / b;

int intDivide(int a, int b) => a ~/ b;

int modulo(int a, int b) => a % b;

int negate(int x) => -x;

// --- Comparison ---
bool lessThan(int a, int b) => a < b;

bool greaterThan(int a, int b) => a > b;

bool lessOrEqual(int a, int b) => a <= b;

bool greaterOrEqual(int a, int b) => a >= b;

bool isEqual(int a, int b) => a == b;

bool isNotEqual(int a, int b) => a != b;

// --- Logical ---
bool logicalAnd(bool a, bool b) => a && b;

bool logicalOr(bool a, bool b) => a || b;

bool logicalNot(bool a) => !a;

// --- Bitwise ---
int bitwiseAnd(int a, int b) => a & b;

int bitwiseOr(int a, int b) => a | b;

int bitwiseXor(int a, int b) => a ^ b;

int leftShift(int a, int b) => a << b;

int rightShift(int a, int b) => a >> b;

int bitwiseNot(int x) => ~x;

// --- String ---
String concat(String a, String b) => a + b;

// --- If/else ---
String classify(int n) {
  if (n < 0) {
    return 'negative';
  } else if (n == 0) {
    return 'zero';
  } else {
    return 'positive';
  }
}

// --- Ternary ---
String ternary(bool flag) => flag ? 'yes' : 'no';

// --- For loop ---
int sumRange(int n) {
  var total = 0;
  for (var i = 0; i < n; i++) {
    total = total + i;
  }
  return total;
}

// --- While loop ---
int whileLoop(int n) {
  var count = 0;
  while (count < n) {
    count = count + 1;
  }
  return count;
}

// --- Recursion ---
int factorial(int n) {
  if (n <= 1) {
    return 1;
  }
  return n * factorial(n - 1);
}

// --- Local variables ---
int localVars(int x) {
  final a = x + 1;
  final b = a * 2;
  final c = b - 3;
  return c;
}

// --- Nested function calls ---
int nested(int x) {
  return add(multiply(x, 2), subtract(x, 1));
}

// --- Block with multiple statements ---
String multiStep(int n) {
  final doubled = n * 2;
  final asStr = doubled.toString();
  return 'Result: $asStr';
}

void main() {
  // Arithmetic
  print(add(3, 4).toString());
  print(subtract(10, 3).toString());
  print(multiply(5, 6).toString());
  print(divide(10.0, 3.0).toString());
  print(intDivide(10, 3).toString());
  print(modulo(10, 3).toString());
  print(negate(5).toString());

  // Comparison
  print(lessThan(1, 2).toString());
  print(greaterThan(3, 2).toString());
  print(lessOrEqual(2, 2).toString());
  print(greaterOrEqual(3, 2).toString());
  print(isEqual(5, 5).toString());
  print(isNotEqual(5, 3).toString());

  // Logical
  print(logicalAnd(true, false).toString());
  print(logicalOr(true, false).toString());
  print(logicalNot(false).toString());

  // Bitwise
  print(bitwiseAnd(6, 3).toString());
  print(bitwiseOr(6, 3).toString());
  print(bitwiseXor(6, 3).toString());
  print(leftShift(1, 3).toString());
  print(rightShift(8, 2).toString());
  print(bitwiseNot(0).toString());

  // String
  print(concat('Hello, ', 'World!'));

  // Control flow
  print(classify(-5));
  print(classify(0));
  print(classify(7));

  // Ternary
  print(ternary(true));
  print(ternary(false));

  // Loops
  print(sumRange(5).toString());
  print(whileLoop(3).toString());

  // Recursion
  print(factorial(6).toString());

  // Local vars
  print(localVars(10).toString());

  // Nested calls
  print(nested(5).toString());

  // Multi-step
  print(multiStep(21));
}
