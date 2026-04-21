void main() {
  String result = '';
  for (int i = 1; i <= 5; i++) {
    result += i.toString();
    if (i < 5) result += ', ';
  }
  print(result);
  print(result.length);
  print(result.contains('3'));
  print(result.contains('7'));
}
