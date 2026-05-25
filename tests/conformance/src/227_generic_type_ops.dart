T identity<T>(T value) => value;

List<T> singleton<T>(T value) => [value];

void main() {
  print(identity<int>(42));
  print(identity<String>('hi'));
  print(singleton<double>(3.5).first);
  print(singleton<bool>(true).first);
  print(singleton<List<int>>([1, 2]).first.length);
}
