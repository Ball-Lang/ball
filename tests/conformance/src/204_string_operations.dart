void main() {
  print('hello world'.toUpperCase());
  print('HELLO World'.toLowerCase());
  print('abcdefgh'.substring(2, 5));
  print('ab' + 'ab' + 'ab');
  print('find the needle here'.indexOf('needle').toString());
  print('42'.padLeft(5, '0'));
  print('a-b-c-d'.replaceAll('-', '_'));
  print('[' + '   padded   '.trim() + ']');
}
