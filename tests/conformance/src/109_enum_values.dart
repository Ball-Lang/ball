enum Color { red, green, blue, yellow }

String colorName(Color c) {
  switch (c) {
    case Color.red:
      return 'Red';
    case Color.green:
      return 'Green';
    case Color.blue:
      return 'Blue';
    case Color.yellow:
      return 'Yellow';
  }
}

void main() {
  for (Color c in Color.values) {
    print('${c.index}: ${colorName(c)}');
  }
  print(Color.values.length);
}
