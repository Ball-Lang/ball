class Logger {
  static final Map<String, Logger> _cache = {};
  final String name;

  Logger._internal(this.name);

  factory Logger(String name) {
    if (_cache.containsKey(name)) {
      return _cache[name]!;
    }
    Logger logger = Logger._internal(name);
    _cache[name] = logger;
    return logger;
  }

  void log(String message) {
    print('[$name] $message');
  }
}

void main() {
  Logger l1 = Logger('App');
  Logger l2 = Logger('App');
  Logger l3 = Logger('DB');
  l1.log('started');
  l2.log('running');
  l3.log('connected');
  print(identical(l1, l2));
  print(identical(l1, l3));
}
