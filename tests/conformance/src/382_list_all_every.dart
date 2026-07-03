// Exercises `List.every`, which encodes to the std_collections `list_all`
// base function (issue #64 std-coverage gap: encoder-emittable but had zero
// conformance fixtures).
void main() {
  final positives = [1, 2, 3, 4, 5];
  print(positives.every((x) => x > 0)); // true

  final mixed = [1, -2, 3, 4];
  print(mixed.every((x) => x > 0)); // false

  final empty = <int>[];
  print(empty.every((x) => x > 100)); // true: vacuous truth

  final words = ['apple', 'avocado', 'ant'];
  print(words.every((w) => w.startsWith('a'))); // true
}
