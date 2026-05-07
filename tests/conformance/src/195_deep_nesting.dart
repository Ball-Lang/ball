List<dynamic> buildNestedList(int depth) {
  dynamic value = 'leaf';
  for (var i = 0; i < depth; i++) {
    value = [value];
  }
  return value as List<dynamic>;
}

Map<String, dynamic> buildNestedMap(int depth) {
  dynamic value = 'leaf';
  for (var i = 0; i < depth; i++) {
    value = {'inner': value};
  }
  return value as Map<String, dynamic>;
}

int listDepth(dynamic value) {
  var depth = 0;
  while (value is List && value.isNotEmpty) {
    depth++;
    value = value.first;
  }
  return depth;
}

int mapDepth(dynamic value) {
  var depth = 0;
  while (value is Map && value.containsKey('inner')) {
    depth++;
    value = value['inner'];
  }
  return depth;
}

void main() {
  final list = buildNestedList(120);
  final map = buildNestedMap(120);

  print(listDepth(list));
  print(mapDepth(map));
  print(listDepth(list) == 120 && mapDepth(map) == 120);
}
