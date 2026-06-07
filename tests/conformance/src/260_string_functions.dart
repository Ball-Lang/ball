void main() {
  var s = 'Hello, World!';
  print(s.contains('World'));
  print(s.contains('xyz'));
  print(s.startsWith('Hello'));
  print(s.endsWith('!'));
  print('aabaa'.replaceAll('a', 'x'));
  print('  hi  '.trimLeft());
  print('  hi  '.trimRight());
  print('foo' + 'bar');
  print('hello'.length);
}
