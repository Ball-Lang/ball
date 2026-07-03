// Exercises `List.insert`, which encodes to the std_collections `list_insert`
// base function (issue #64 std-coverage gap: encoder-emittable but had zero
// conformance fixtures).
void main() {
  final letters = ['a', 'b', 'd', 'e'];
  letters.insert(2, 'c');
  print(letters); // [a, b, c, d, e]

  final nums = [1, 2, 3];
  nums.insert(0, 0);
  print(nums); // [0, 1, 2, 3]

  final tail = [1, 2, 3];
  tail.insert(tail.length, 4);
  print(tail); // [1, 2, 3, 4]
}
