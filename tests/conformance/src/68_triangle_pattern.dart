void main() {
  for (var i = 1; i <= 5; i++) {
    var line = '';
    for (var j = 0; j < i; j++) {
      line = '$line*';
    }
    print(line);
  }
}
