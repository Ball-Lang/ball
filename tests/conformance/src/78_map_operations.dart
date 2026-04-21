void main() {
  Map<String, int> scores = {};
  scores['alice'] = 95;
  scores['bob'] = 87;
  scores['charlie'] = 92;
  print(scores['alice']);
  print(scores['bob']);
  print(scores.containsKey('charlie'));
  print(scores.containsKey('dave'));
  scores['bob'] = 90;
  print(scores['bob']);
  print(scores.length);
}
