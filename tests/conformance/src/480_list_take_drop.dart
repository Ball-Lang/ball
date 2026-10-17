// Exercises `std_collections.list_take` / `list_drop` end to end (issue
// #833). Both were declared, compiler-lowered and engine-implemented on every
// target, but the Dart ENCODER had no route for `.take`/`.skip` at all, so no
// conformance fixture could ever reach them. `Iterable.take`/`.skip` return a
// lazy Iterable, not a List, so each call is chained with an explicit
// `.toList()` -- materializing on the native-Dart side so this fixture's
// printed output agrees with the Ball engines, which already materialize
// inside `list_take`/`list_drop` itself.
void main() {
  List<int> nums = [1, 2, 3, 4, 5, 6, 7];

  List<int> firstThree = nums.take(3).toList();
  List<int> dropTwo = nums.skip(2).toList();

  print(firstThree);
  print(dropTwo);

  // Taking/dropping more than the list holds clamps at the ends, same as
  // real `Iterable.take`/`.skip`.
  print(nums.take(100).toList());
  print(nums.skip(100).toList());

  // Taking/dropping zero is the identity / empty-list edge.
  print(nums.take(0).toList());
  print(nums.skip(0).toList());
}
