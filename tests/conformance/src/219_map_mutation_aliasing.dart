void main() {
  final scores = <String, int>{'alice': 10};
  final mirror = scores;
  mirror['alice'] = 99;
  mirror['bob'] = 42;
  print(scores['alice']);
  print(mirror['alice']);
  print(scores.length);
  print(mirror.containsKey('bob'));
}
