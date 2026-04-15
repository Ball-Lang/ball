void main() {
  var i = 0;
  do {
    print(i.toString());
    i = i + 1;
  } while (i < 3);
  // Do-while always runs at least once, even with false condition
  var j = 10;
  do {
    print(j.toString());
    j = j + 1;
  } while (j < 5);
  print('done');
}
