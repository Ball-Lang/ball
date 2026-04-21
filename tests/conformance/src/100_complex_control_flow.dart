void main() {
  int result = 0;
  for (int i = 0; i < 10; i++) {
    if (i == 3) continue;
    if (i == 8) break;
    for (int j = 0; j < 3; j++) {
      if (j == 1 && i > 5) continue;
      result += i * j;
    }
  }
  print(result);
  
  int x = 100;
  while (x > 0) {
    x -= 17;
    if (x < 30) break;
  }
  print(x);
}
