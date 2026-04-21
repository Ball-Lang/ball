String toRoman(int num) {
  List<int> values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  List<String> symbols = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
  String result = '';
  for (int i = 0; i < values.length; i++) {
    while (num >= values[i]) {
      result += symbols[i];
      num -= values[i];
    }
  }
  return result;
}

void main() {
  print(toRoman(1));
  print(toRoman(4));
  print(toRoman(9));
  print(toRoman(58));
  print(toRoman(1994));
}
