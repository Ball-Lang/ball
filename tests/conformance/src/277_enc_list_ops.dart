void main() {
  var xs = [1, 2, 3, 4, 5];
  print(xs.length.toString());
  var sum = 0;
  for (var i = 0; i < xs.length; i = i + 1) {
    sum = sum + xs[i];
  }
  print(sum.toString());
}
