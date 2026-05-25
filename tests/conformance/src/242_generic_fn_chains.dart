T pickFirst<T>(List<T> items) => items.first;

T transform<T>(T value, T Function(T) fn) => fn(value);

void main() {
  print(pickFirst<int>([10, 20]));
  print(pickFirst<String>(['a', 'b']));
  print(transform<int>(5, (x) => x * 2));
  print(transform<String>('hi', (s) => '$s!'));
  print(pickFirst<List<int>>([[1], [2]]).length);
}
