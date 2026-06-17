import 'dart:convert';

void main() {
  const ascii = 'Ball';
  const unicode = 'こんにちは世界';
  const emoji = 'Ball 🚀';
  print(utf8.decode(base64.decode(base64.encode(utf8.encode(ascii)))));
  print(utf8.decode(base64.decode(base64.encode(utf8.encode(unicode)))));
  print(utf8.decode(base64.decode(base64.encode(utf8.encode(emoji)))));
}
