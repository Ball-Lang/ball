wrapNested(int depth, value) {
  if (depth == 0) {
    return [value];
  }

  return [wrapNested(depth - 1, value)];
}

String describeCycle(value, int depth) {
  if (depth == 0) {
    return 'cycle';
  }

  if (value is List && value.isNotEmpty) {
    return describeCycle(value.first, depth - 1);
  }

  return 'leaf';
}

void main() {
  final circular = [];
  circular.add(circular);

  final nested = wrapNested(80, circular);

  try {
    final probe = [nested];
    print(describeCycle(circular, 1));
    print(probe[1]);
  } on RangeError {
    print('caught range error');
  }

  print(describeCycle(nested, 2));
}
