// Exercises `List.reversed` (a getter, not a method call), which encodes to
// the std_collections `list_reverse` base function (issue #64 std-coverage
// gap: the encoder had a dead routing table entry for it keyed to the wrong
// AST node — MethodInvocation instead of PropertyAccess — so it was never
// actually reachable; fixed alongside this fixture).
void main() {
  final nums = [1, 2, 3, 4, 5];
  print(nums.reversed.toList()); // [5, 4, 3, 2, 1]

  final letters = <String>['x', 'y', 'z'];
  for (final ch in letters.reversed) {
    print(ch); // z, y, x
  }

  final single = [42];
  print(single.reversed.toList()); // [42]
}
