import 'dart:convert';

void main() {
  var data = <String, Object>{};
  data['name'] = 'Alice';
  data['age'] = 30;
  print(jsonEncode(data));
  print(jsonDecode('{"x":1,"y":2}'));
}
