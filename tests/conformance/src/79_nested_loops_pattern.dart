void main() {
  for (int i = 1; i <= 5; i++) {
    String line = '';
    for (int j = 1; j <= i; j++) {
      line += '*';
    }
    print(line);
  }
  for (int i = 5; i >= 1; i--) {
    String line = '';
    for (int j = 1; j <= i; j++) {
      line += '#';
    }
    print(line);
  }
}
