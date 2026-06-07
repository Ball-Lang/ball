void main() {
  var found = 0;
  outer:
  for (var i = 1; i <= 5; i = i + 1) {
    for (var j = 1; j <= 5; j = j + 1) {
      if (i * j == 12) {
        found = i * 100 + j;
        break outer;
      }
    }
  }
  print(found.toString());
}
