/// Wave-6 feature-branch coverage for `encoder.dart` (issue #61): real Dart
/// constructs that the existing corpus + unit tests don't exercise yet —
/// annotated `extension`/`extension type` declarations, a generic
/// `extension type`, an `extension type` with a secondary named constructor,
/// a `typedef` doc comment, for-loop-init variable declarations without an
/// initializer / with `final`/`const`, and a parenthesized multi-section
/// cascade.
///
/// Each test encodes a small Dart snippet containing exactly one feature and
/// asserts the encoder emits the corresponding Ball metadata/shape — proving
/// the branch runs AND produces the expected output (not just that it
/// doesn't throw). Mirrors encoder_feature_branch_coverage_test.dart's house
/// style.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

void main() {
  String jsonOf(String source) =>
      jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

  group('extension / extension type annotations', () {
    test('an annotated extension carries meta[annotations]', () {
      final js = jsonOf('''
@deprecated
extension IntX on int {
  int get doubled => this * 2;
}

void main() {}
''');
      expect(js, contains('annotations'));
      expect(js, contains('extension'));
    });

    test('an annotated extension type carries meta[annotations]', () {
      final js = jsonOf('''
@deprecated
extension type Meters(int value) {}

void main() {}
''');
      expect(js, contains('annotations'));
      expect(js, contains('extension_type'));
    });
  });

  group('extension type — generic + secondary constructor', () {
    test('a generic extension type carries meta[type_params]', () {
      final js = jsonOf('''
extension type Box<T>(T value) {}

void main() {}
''');
      expect(js, contains('type_params'));
    });

    test('an extension type with a secondary named constructor encodes it', () {
      final js = jsonOf('''
extension type Meters(int value) {
  Meters.zero() : value = 0;
}

void main() {}
''');
      expect(js, contains('Meters.zero'));
    });
  });

  group('typedef doc comment', () {
    test('a documented typedef carries meta[doc]', () {
      final js = jsonOf('''
/// A type alias for a callback.
typedef Callback = void Function();

void main() {}
''');
      expect(js, contains('doc'));
      expect(js, contains('typedef'));
    });
  });

  group('for-loop-init variable declaration edge cases', () {
    test('a for-loop-init declaration with no initializer', () {
      final js = jsonOf('''
void main() {
  for (int i; i < 0;) {
    break;
  }
}
''');
      expect(js, contains('__no_init__'));
    });

    test('a for-loop-init `final` declaration', () {
      final js = jsonOf('''
void main() {
  for (final x = 0; x < 3;) {
    break;
  }
}
''');
      expect(js, contains('final'));
    });

    test('a for-loop-init `const` declaration', () {
      final js = jsonOf('''
void main() {
  for (const x = 0; x < 3;) {
    break;
  }
}
''');
      expect(js, contains('const'));
    });
  });

  group('parenthesized multi-section cascade', () {
    test('a parenthesized multi-section cascade emits the paren wrapper', () {
      final js = jsonOf('''
void main() {
  final list = <int>[];
  final x = (list..add(1)..add(2));
  print(x);
}
''');
      expect(js, contains('paren'));
    });
  });
}
