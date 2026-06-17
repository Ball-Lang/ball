void show(Object value) {
  print(value.toString());
}

void main() {
  show(''.length);
  show(''.isEmpty);
  show('x'.isEmpty);
  show('   '.trim());
  show('abc'.indexOf('z'));
  show('hello'.substring(5));
  show(''.toUpperCase());
  show('' + 'tail');
}
