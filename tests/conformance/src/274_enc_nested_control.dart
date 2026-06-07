void main() {
  var sum = 0;
  for (var i = 1; i <= 3; i = i + 1) {
    for (var j = 1; j <= 3; j = j + 1) {
      if (i == j) continue;
      sum = sum + (i * j);
    }
  }
  print(sum.toString());
}
