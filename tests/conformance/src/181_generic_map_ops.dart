void main() {
  Map<String, int> scores = {};
  scores['alice'] = 95;
  scores['bob'] = 87;

  var isStrIntMap = scores is Map<String, int>;
  print(isStrIntMap);

  var notStrStrMap = scores is Map<String, String>;
  print(notStrStrMap);

  var isMap = scores is Map;
  print(isMap);
}
