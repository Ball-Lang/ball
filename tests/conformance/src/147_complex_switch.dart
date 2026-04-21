String classify(int n) {
  switch (n % 4) {
    case 0:
      return 'divisible by 4';
    case 1:
      return 'remainder 1';
    case 2:
      return 'remainder 2';
    case 3:
      return 'remainder 3';
    default:
      return 'unknown';
  }
}

String dayType(String day) {
  switch (day) {
    case 'Monday':
    case 'Tuesday':
    case 'Wednesday':
    case 'Thursday':
    case 'Friday':
      return 'weekday';
    case 'Saturday':
    case 'Sunday':
      return 'weekend';
    default:
      return 'invalid';
  }
}

void main() {
  for (int i = 0; i < 8; i++) {
    print('$i: ${classify(i)}');
  }
  List<String> days = ['Monday', 'Saturday', 'Wednesday', 'Sunday', 'Holiday'];
  for (String d in days) {
    print('$d: ${dayType(d)}');
  }
}
