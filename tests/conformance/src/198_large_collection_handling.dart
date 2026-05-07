void main() {
  final bigList = List.filled(10000, 0);
  final bigMap = <String, int>{};

  for (var i = 0; i < 1000; i++) {
    bigMap['k$i'] = i;
  }

  print(bigList.length);
  print(bigMap.length);
  print('ok');
}
