// `assert` exercises the std `assert` base function (was emittable but never
// covered — surfaced by the encoder-completeness gate).
void main() {
  assert(1 == 1);
  var x = 5;
  assert(x > 0, 'x must be positive');
  print('asserts passed: $x');
}
