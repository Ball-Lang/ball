// Exercises List.reduce — the no-seed combine that starts at the first element
// and folds from the second (regression guard for #108). Distinct from
// `fold`, which takes an explicit initial value.
void main() {
  final nums = [1, 2, 3, 4, 5];
  print(nums.reduce((a, b) => a + b)); // 15
  print([3, 1, 4, 1, 5, 9, 2, 6].reduce((a, b) => a > b ? a : b)); // 9 (max)
  print([2, 4, 6, 8].reduce((a, b) => a * b)); // 384 (product)
  print([42].reduce((a, b) => a + b)); // 42 (single element: combine never runs)
  print(['a', 'b', 'c', 'd'].reduce((a, b) => '$a$b')); // abcd
}
