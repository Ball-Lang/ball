String encrypt(String text, int shift) {
  StringBuffer result = StringBuffer();
  for (int i = 0; i < text.length; i++) {
    int code = text.codeUnitAt(i);
    if (code >= 65 && code <= 90) {
      result.writeCharCode((code - 65 + shift) % 26 + 65);
    } else if (code >= 97 && code <= 122) {
      result.writeCharCode((code - 97 + shift) % 26 + 97);
    } else {
      result.writeCharCode(code);
    }
  }
  return result.toString();
}

String decrypt(String text, int shift) {
  return encrypt(text, 26 - shift);
}

void main() {
  String msg = 'Hello World';
  String enc = encrypt(msg, 3);
  print(enc);
  String dec = decrypt(enc, 3);
  print(dec);
  print(encrypt('ABC xyz', 1));
  print(encrypt('ZZZ', 1));
}
