/// Demonstrates string manipulation and math operations.
///
/// When encoded → compiled through ball, exercises the new
/// std.string_* and std.math_* base functions.
import 'dart:math';

void main() {
  // String operations
  final greeting = 'Hello, World!';
  print(greeting.toUpperCase());
  print(greeting.toLowerCase());
  print(greeting.substring(0, 5));
  print(greeting.contains('World'));
  print(greeting.replaceAll('World', 'Ball'));
  print(greeting.split(', ').join(' - '));
  print(greeting.trim());
  print(greeting.padLeft(20, '*'));
  print(greeting.length);

  // Math operations
  final x = 2.0;
  final y = 3.0;
  print(sqrt(x));
  print(pow(x, y));
  print(x.abs());
  print(pi);
  print(min(x, y));
  print(max(x, y));
  print(x.clamp(1.0, 2.5));
  print(sin(pi / 2));
  print(cos(0.0));
  print(log(e));
}
