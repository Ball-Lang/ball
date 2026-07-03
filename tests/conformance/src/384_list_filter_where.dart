// Exercises `List.where`, which encodes to the std_collections `list_filter`
// base function (issue #64 std-coverage gap: encoder-emittable but had zero
// conformance fixtures).
void main() {
  final nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
  final evens = nums.where((x) => x % 2 == 0).toList();
  print(evens); // [2, 4, 6, 8, 10]

  final words = ['apple', 'kiwi', 'banana', 'fig'];
  final longWords = words.where((w) => w.length > 4).toList();
  print(longWords); // [apple, banana]

  final none = nums.where((x) => x > 100).toList();
  print(none); // []
}
