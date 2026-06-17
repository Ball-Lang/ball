void main() {
  var intList = [1, 2, 3];
  var strList = ['a', 'b', 'c'];

  var isIntList = intList is List<int>;
  print(isIntList);

  var isStrList = strList is List<String>;
  print(isStrList);

  var intListNotString = intList is List<String>;
  print(intListNotString);
}
