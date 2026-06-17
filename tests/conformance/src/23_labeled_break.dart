void main() {
  int i = 1;
  outer:
  while (i <= 5) {
    if (i == 3) {
      break outer;
    }
    print('$i');
    i = i + 1;
  }
  print('done');
}
