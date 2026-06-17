void main() {
  var nums = [3, 1, 4, 1, 5];
  print('${nums.length}');
  print('${nums[2]}');
  var sum = 0;
  for (var i = 0; i < nums.length; i = i + 1) {
    sum = sum + nums[i];
  }
  print('$sum');
}
