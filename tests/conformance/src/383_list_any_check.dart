// Exercises `List.any`, which encodes to the std_collections `list_any` base
// function (issue #64 std-coverage gap: encoder-emittable but had zero
// conformance fixtures).
void main() {
  final nums = [1, 2, 3, 4, 5];
  print(nums.any((x) => x > 4)); // true

  final small = [1, 2, 3];
  print(small.any((x) => x > 100)); // false

  final empty = <int>[];
  print(empty.any((x) => true)); // false: vacuously false

  final words = ['pear', 'kiwi', 'apple'];
  print(words.any((w) => w.length > 4)); // true ('apple')
}
