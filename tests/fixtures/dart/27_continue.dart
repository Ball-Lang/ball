void main() {
  var count = 0;
  for (var i = 1; i <= 10; i = i + 1) {
    if (i % 2 == 0) continue;
    if (i == 7) break;
    count = count + 1;
    print(i.toString());
  }
  print('count=$count');
}
