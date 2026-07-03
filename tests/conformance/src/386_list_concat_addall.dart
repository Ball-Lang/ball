// Exercises `List.addAll`, which encodes to the std_collections `list_concat`
// base function (issue #64 std-coverage gap: encoder-emittable but had zero
// conformance fixtures).
void main() {
  final a = [1, 2, 3];
  a.addAll([4, 5]);
  print(a); // [1, 2, 3, 4, 5]

  final letters = <String>['x'];
  letters.addAll(['y', 'z']);
  print(letters); // [x, y, z]

  final empty = <int>[];
  empty.addAll([1, 2, 3]);
  print(empty); // [1, 2, 3]
}
