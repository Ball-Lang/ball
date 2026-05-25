String label(Object? value) {
  switch (value) {
    case null:
      return 'null';
    case true:
      return 'true';
    case false:
      return 'false';
    default:
      return 'other:$value';
  }
}

void main() {
  print(label(null));
  print(label(true));
  print(label(false));
  print(label(0));
}
