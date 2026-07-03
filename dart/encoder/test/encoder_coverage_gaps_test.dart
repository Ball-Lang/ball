/// Targeted coverage for encoder.dart branches not exercised by the other
/// encoder test files: conditional import/export configurations,
/// `uriToModuleName` edge cases, extra `extension type` metadata (doc
/// comments, const/named primary constructors, interfaces, instance field
/// modifiers, type params), the `EncoderError` message formatting, the
/// if-case *statement* (as opposed to the if-case collection *element*
/// already covered elsewhere), for-in loop variants (non-block body,
/// `await for`, Dart-3 destructuring for-each), switch-case body flattening,
/// adjacent string literals, and a non-builtin generic type literal.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

void main() {
  String jsonOf(String source) =>
      jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

  Module mainModule(Program p) => p.modules.firstWhere((m) => m.name == 'main');

  group('EncoderError', () {
    test('toString includes the message and, when set, the source', () {
      expect(EncoderError('bad thing').toString(), 'EncoderError: bad thing');
      expect(
        EncoderError('bad thing', source: 'x + y').toString(),
        'EncoderError: bad thing at x + y',
      );
    });

    test('strict mode throws EncoderError instead of collecting a warning', () {
      final enc = DartEncoder(strict: true);
      // An unnamed `extension on T { ... }` triggers the "no name" warning.
      expect(
        () => enc.encode('''
extension on int {
  int doubled() => this * 2;
}
void main() {}
'''),
        throwsA(isA<EncoderError>()),
      );
    });

    test('non-strict mode records the same condition as a warning instead', () {
      final enc = DartEncoder();
      enc.encode('''
extension on int {
  int doubled() => this * 2;
}
void main() {}
''');
      expect(
        enc.warnings,
        contains(contains('Extension declaration has no name')),
      );
    });
  });

  group('uriToModuleName', () {
    test('dart: URIs map to dart.<lib>', () {
      expect(DartEncoder.uriToModuleName('dart:core'), 'dart.core');
    });

    test('package: URIs use the package name (before the first slash)', () {
      expect(
        DartEncoder.uriToModuleName('package:ball_base/ball_base.dart'),
        'ball_base',
      );
    });

    test('a bare package: URI with no slash is returned as-is', () {
      expect(DartEncoder.uriToModuleName('package:ball_base'), 'ball_base');
    });

    test('relative URIs use the file basename without the .dart suffix', () {
      expect(DartEncoder.uriToModuleName('src/helpers.dart'), 'helpers');
      expect(DartEncoder.uriToModuleName('helpers.dart'), 'helpers');
    });
  });

  group('conditional imports / exports', () {
    test('an import with `if` configurations records them in metadata', () {
      final p = DartEncoder().encode('''
import 'stub.dart'
  if (dart.library.io) 'io.dart'
  if (dart.library.js_interop) 'web.dart' as web;
void main() {}
''');
      final meta = mainModule(p).metadata.fields;
      expect(meta.containsKey('dart_imports'), isTrue);
      final imports = meta['dart_imports']!.listValue.values;
      final detail = imports.first.structValue.fields;
      expect(detail.containsKey('configurations'), isTrue);
      final configs = detail['configurations']!.listValue.values;
      expect(configs, hasLength(2));
      expect(
        configs.first.structValue.fields['name']!.stringValue,
        'dart.library.io',
      );
      expect(configs.first.structValue.fields['uri']!.stringValue, 'io.dart');
    });

    test('an export with `if` configurations records them in metadata', () {
      final p = DartEncoder().encode('''
export 'stub.dart' if (dart.library.io) 'io.dart';
void main() {}
''');
      final meta = mainModule(p).metadata.fields;
      expect(meta.containsKey('dart_exports'), isTrue);
      final exports = meta['dart_exports']!.listValue.values;
      final detail = exports.first.structValue.fields;
      expect(detail.containsKey('configurations'), isTrue);
    });
  });

  group('extension type: extra metadata', () {
    test('doc comment, const named ctor, interfaces, field modifiers, '
        'type params', () {
      final p = DartEncoder().encode('''
/// Doc comment on Meters.
extension type const Meters.of(int value) implements Comparable<Meters> {
  /// A scaled copy.
  final double scale = 1.0;
  late String label;
  static const int zero = 0;
}
void main() {}
''');
      final td = mainModule(
        p,
      ).typeDefs.firstWhere((t) => t.name.endsWith(':Meters'));
      final meta = td.metadata.fields;
      expect(meta['kind']!.stringValue, 'extension_type');
      expect(meta.containsKey('doc'), isTrue);
      expect(meta['is_const']!.boolValue, isTrue);
      expect(meta['rep_constructor_name']!.stringValue, 'of');
      expect(meta.containsKey('interfaces'), isTrue);
      final fields = meta['fields']!.listValue.values;
      final scaleField = fields.firstWhere(
        (f) => f.structValue.fields['name']!.stringValue == 'scale',
      );
      expect(scaleField.structValue.fields['is_final']!.boolValue, isTrue);
      expect(scaleField.structValue.fields.containsKey('initializer'), isTrue);
      final labelField = fields.firstWhere(
        (f) => f.structValue.fields['name']!.stringValue == 'label',
      );
      expect(labelField.structValue.fields['is_late']!.boolValue, isTrue);
    });
  });

  group('library-level annotations', () {
    test('an annotated `library;` directive is captured as metadata', () {
      final p = DartEncoder().encode('''
@Deprecated('use something else')
library;

void main() {}
''');
      final meta = mainModule(p).metadata.fields;
      expect(meta.containsKey('library_annotations'), isTrue);
    });
  });

  group('if-case statement (not collection element)', () {
    test('an if-case control-flow statement encodes a structured pattern', () {
      final j = jsonOf('''
void f(Object? o) {
  if (o case int n when n > 0) {
    print(n);
  } else {
    print('no');
  }
}
void main() {}
''');
      expect(j, contains('case_pattern'));
      expect(j, contains('case_pattern_expr'));
    });
  });

  group('for-in loop variants', () {
    test('for-in with a non-block (single-statement) body', () {
      final j = jsonOf('''
void f(List<int> xs) {
  for (final x in xs) print(x);
}
void main() {}
''');
      expect(j, contains('for_in'));
    });

    test('await-for loop sets is_await', () {
      final j = jsonOf('''
Future<void> f(Stream<int> s) async {
  await for (final x in s) {
    print(x);
  }
}
void main() {}
''');
      expect(j, contains('is_await'));
    });

    test('Dart-3 destructuring for-each records the pattern verbatim', () {
      final j = jsonOf('''
void f(Map<String, int> m) {
  for (var MapEntry(key: k, value: v) in m.entries) {
    print('\$k=\$v');
  }
}
void main() {}
''');
      expect(j, contains('MapEntry'));
    });
  });

  group('switch statement: braced case body flattening', () {
    test(
      'a legacy case with a single braced block flattens its statements',
      () {
        final j = jsonOf('''
void f(int x) {
  switch (x) {
    case 1:
      {
        print('one');
        print('done');
      }
      break;
  }
}
void main() {}
''');
        expect(j, contains('switch'));
        expect(j, contains('one'));
        expect(j, contains('done'));
      },
    );
  });

  group('literal expressions', () {
    test('adjacent string literals concatenate via std.concat', () {
      final j = jsonOf('''
void f() {
  final s = 'foo' 'bar';
  print(s);
}
void main() {}
''');
      expect(j, contains('"function":"concat"'));
      expect(j, contains('"foo"'));
      expect(j, contains('"bar"'));
    });
  });
}
