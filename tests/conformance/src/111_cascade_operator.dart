class Builder {
  List<String> parts = [];

  void addPart(String part) {
    parts.add(part);
  }

  void reset() {
    parts.clear();
  }

  String build() {
    return parts.join(', ');
  }
}

void main() {
  Builder b = Builder()
    ..addPart('engine')
    ..addPart('wheels')
    ..addPart('body');
  print(b.build());
  b
    ..reset()
    ..addPart('frame')
    ..addPart('glass');
  print(b.build());
}
