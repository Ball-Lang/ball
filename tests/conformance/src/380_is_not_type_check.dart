// Exercises `is!` (negated type check), which encodes to the std `is_not`
// base function — a distinct base function from `is` (issue #64 std-coverage
// gap: `is_not` was encoder-emittable but had zero conformance fixtures).
void main() {
  Object x = 5;
  Object y = 'hello';

  print(x is! String); // true: int is not a String
  print(y is! String); // false: y IS a String
  print(x is! int); // false: x IS an int

  if (x is! String) {
    print('x is not a String');
  }

  if (y is! int) {
    print('y is not an int');
  }
}
