String? maybeValue(bool flag) {
  if (flag) return 'present';
  return null;
}

void main() {
  final list = [null, 'alpha', maybeValue(false)];
  final map = {
    'a': null,
    'b': maybeValue(true),
    'c': maybeValue(false),
  };

  print(list);
  print(map);
  print(maybeValue(true) == null);
  print(maybeValue(false) == null);
  print(maybeValue(false) != null);
}
