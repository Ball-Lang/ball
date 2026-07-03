// Exercises `>>>` (unsigned/logical right shift), which encodes to the std
// `unsigned_right_shift` base function — distinct from `>>` (arithmetic right
// shift, sign-extending). Issue #64 std-coverage gap: encoder-emittable but
// had zero conformance fixtures.
void main() {
  final negative = -8;
  // Arithmetic shift sign-extends; unsigned shift fills with zeros, so on a
  // negative operand the two diverge sharply.
  print(negative >> 1); // -4 (sign-extending)
  print(negative >>> 1); // 9223372036854775804 (zero-filling, 64-bit)

  final positive = 32;
  print(positive >>> 2); // 8 (matches >> for non-negative operands)
  print(positive >> 2); // 8

  print((-1) >>> 60); // 15: top 4 bits of all-ones
}
