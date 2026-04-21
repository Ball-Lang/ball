void main() {
  List<String> queue = [];

  queue.add('Alice');
  queue.add('Bob');
  queue.add('Charlie');
  print('Queue: $queue');

  String first = queue.removeAt(0);
  print('Served: $first');
  print('Queue: $queue');

  queue.add('Diana');
  queue.add('Eve');
  print('Queue: $queue');

  while (queue.isNotEmpty) {
    String served = queue.removeAt(0);
    print('Served: $served');
  }
  print('Empty: ${queue.isEmpty}');
}
