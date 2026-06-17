int sumPair(Object? value) {
  switch (value) {
    case [var x as int, var y as int]:
      return x + y;
    default:
      return -1;
  }
}

String safeCast(Object? value) {
  try {
    switch (value) {
      case var x as int:
        return 'int:$x';
    }
  } catch (_) {
    return 'cast-failed';
  }
  return 'unreached';
}

void main() {
  print(sumPair([3, 4]));
  print(sumPair([1, 2, 3]));
  print(sumPair('hi'));
  print(safeCast(42));
  print(safeCast('hi'));
}
