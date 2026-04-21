void main() {
  var sum = 0;
  for (var i = 1; i <= 10; i++) {
    sum += i * i;
  }
  print(sum.toString());
  var sumCubes = 0;
  for (var i = 1; i <= 5; i++) {
    sumCubes += i * i * i;
  }
  print(sumCubes.toString());
}
