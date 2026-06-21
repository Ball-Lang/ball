/// Tests for `parts_resolver.dart` — resolving a multi-file Dart library
/// (one main file + `part` files) into a single source string, with
/// `extension on Class` blocks merged into their target class bodies.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_encoder/parts_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('resolveDartLibraryFromSource', () {
    test('returns the source unchanged when there are no part directives', () {
      const source = '''
library my_lib;
int value = 1;
''';
      final result = resolveDartLibraryFromSource(
        source,
        partLoader: (uri) => throw StateError('should not be called: $uri'),
      );
      expect(result, equals(source));
    });

    test('appends non-extension top-level declarations from part files', () {
      const main = '''
library my_lib;
part 'part_a.dart';
int mainValue = 1;
''';
      const partA = '''
part of 'main.dart';
int partValue = 2;
void partFn() {}
''';
      final result = resolveDartLibraryFromSource(
        main,
        partLoader: (uri) {
          expect(uri, equals('part_a.dart'));
          return partA;
        },
      );
      // The `part` directive is stripped.
      expect(result, isNot(contains("part 'part_a.dart';")));
      // Main declaration is kept.
      expect(result, contains('int mainValue = 1;'));
      // Part-file top-level declarations are appended.
      expect(result, contains('int partValue = 2;'));
      expect(result, contains('void partFn() {}'));
    });

    test('merges extension methods into the target class body', () {
      const main = '''
class Widget {
  int width = 0;
}
''';
      // main has no part directive of its own; we use a synthetic main that
      // declares the part.
      const mainWithPart = '''
part 'ext.dart';
class Widget {
  int width = 0;
}
''';
      const ext = '''
part of 'main.dart';
extension WidgetExt on Widget {
  int doubled() => width * 2;
}
''';
      final result = resolveDartLibraryFromSource(
        mainWithPart,
        partLoader: (uri) => ext,
      );
      // The extension member is spliced into the Widget class body.
      expect(result, contains('int doubled() => width * 2;'));
      // It is inside the class, before the closing brace — i.e. it should
      // appear before the end of the source and not as a standalone extension.
      expect(result, isNot(contains('extension WidgetExt on Widget')));
      // Sanity: it still parses as a single library with the class present.
      expect(result, contains('class Widget'));
      // unused single-class variant compiles too (no-op reference).
      expect(main, contains('class Widget'));
    });

    test('merges extension methods into a mixin declared in main', () {
      const mainWithPart = '''
part 'ext.dart';
mixin Flyer {
  int altitude = 0;
}
''';
      const ext = '''
part of 'main.dart';
extension FlyerExt on Flyer {
  int climb() => altitude + 1;
}
''';
      final result = resolveDartLibraryFromSource(
        mainWithPart,
        partLoader: (uri) => ext,
      );
      expect(result, contains('int climb() => altitude + 1;'));
      expect(result, contains('mixin Flyer'));
    });

    test('keeps extension on an external type as a standalone declaration', () {
      const mainWithPart = '''
part 'ext.dart';
class Local {}
''';
      const ext = '''
part of 'main.dart';
extension IntExt on int {
  int squared() => this * this;
}
''';
      final result = resolveDartLibraryFromSource(
        mainWithPart,
        partLoader: (uri) => ext,
      );
      // `int` is not a main-file class, so the extension is appended verbatim.
      expect(result, contains('extension IntExt on int'));
      expect(result, contains('int squared() => this * this;'));
    });

    test('dedupes identical extension members across multiple part files', () {
      const mainWithPart = '''
part 'a.dart';
part 'b.dart';
class Engine {
  int rpm = 0;
}
''';
      const partA = '''
part of 'main.dart';
extension EngineA on Engine {
  int helper() => rpm;
  int onlyA() => 1;
}
''';
      const partB = '''
part of 'main.dart';
extension EngineB on Engine {
  int helper() => rpm;
  int onlyB() => 2;
}
''';
      final result = resolveDartLibraryFromSource(
        mainWithPart,
        partLoader: (uri) => uri == 'a.dart' ? partA : partB,
      );
      // `helper` appears in both extensions but must be spliced only once.
      expect('helper'.allMatches(result).length, equals(1));
      // The unique members are both present.
      expect(result, contains('int onlyA() => 1;'));
      expect(result, contains('int onlyB() => 2;'));
    });

    test('merges extension field declarations into the target class', () {
      const mainWithPart = '''
part 'ext.dart';
class Box {
  int w = 0;
}
''';
      const ext = '''
part of 'main.dart';
extension BoxExt on Box {
  static const int max = 99;
}
''';
      final result = resolveDartLibraryFromSource(
        mainWithPart,
        partLoader: (uri) => ext,
      );
      expect(result, contains('static const int max = 99;'));
    });

    test('handles multiple part directives in declaration order', () {
      const mainWithPart = '''
part 'first.dart';
part 'second.dart';
int root = 0;
''';
      const first = '''
part of 'main.dart';
int fromFirst = 1;
''';
      const second = '''
part of 'main.dart';
int fromSecond = 2;
''';
      final result = resolveDartLibraryFromSource(
        mainWithPart,
        partLoader: (uri) => uri == 'first.dart' ? first : second,
      );
      expect(result, contains('int fromFirst = 1;'));
      expect(result, contains('int fromSecond = 2;'));
      // first should be appended before second.
      expect(
        result.indexOf('fromFirst'),
        lessThan(result.indexOf('fromSecond')),
      );
    });
  });

  group('resolveDartLibrary (file-based)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ball_parts_');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('reads main + part files from disk and merges them', () {
      final mainFile = File('${tmp.path}/main.dart');
      final partFile = File('${tmp.path}/helper.dart');
      mainFile.writeAsStringSync('''
part 'helper.dart';
class Service {
  int id = 0;
}
''');
      partFile.writeAsStringSync('''
part of 'main.dart';
extension ServiceExt on Service {
  int next() => id + 1;
}
int topLevel = 7;
''');
      final result = resolveDartLibrary(mainFile.path);
      expect(result, contains('int next() => id + 1;'));
      expect(result, contains('int topLevel = 7;'));
      expect(result, isNot(contains("part 'helper.dart';")));
    });

    test('returns source unchanged when main file has no parts', () {
      final mainFile = File('${tmp.path}/solo.dart');
      const src = 'int onlyValue = 42;\n';
      mainFile.writeAsStringSync(src);
      final result = resolveDartLibrary(mainFile.path);
      expect(result, equals(src));
    });
  });
}
