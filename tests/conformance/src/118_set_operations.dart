void main() {
  Set<int> a = {1, 2, 3, 4, 5};
  Set<int> b = {3, 4, 5, 6, 7};

  Set<int> union = a.union(b);
  List<int> unionSorted = union.toList()..sort();
  print('Union: $unionSorted');

  Set<int> intersection = a.intersection(b);
  List<int> interSorted = intersection.toList()..sort();
  print('Intersection: $interSorted');

  Set<int> diff = a.difference(b);
  List<int> diffSorted = diff.toList()..sort();
  print('Difference: $diffSorted');

  print('Contains 3: ${a.contains(3)}');
  print('Contains 9: ${a.contains(9)}');
  print('Length: ${a.length}');
}
