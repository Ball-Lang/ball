/// Flow-sensitive promotion must survive a cascade (issue #573, case 1).
///
/// `path/lib/src/context.dart`'s `relative()` reassigns its nullable named
/// parameter and relies on Dart's flow analysis promoting it for the rest of
/// the body:
///
/// ```dart
/// from = from == null ? current : absolute(from);   // `from` is now String
/// final fromParsed = _parse(from)..normalize();     // _parse(String p)
/// ```
///
/// Round-tripping that through `DartEncoder` + `DartCompiler` used to wrap the
/// cascade in an immediately-invoked closure, and Dart deliberately does not
/// carry a local's promotion across a function-literal boundary — so `from`
/// was demoted to `String?` inside the closure and the front end rejected the
/// call with
/// `The argument type 'String?' can't be assigned to the parameter type
/// 'String'`, the exact diagnostic issue #573 quotes.
///
/// The existing `dart/compiler` cascade tests all build the NATIVE
/// `std.cascade(...)` `FunctionCall` IR, which this encoder never emits, so
/// none of them constructed the shape that trips this. And every round-trip
/// leg in CI passes `--skip-analyze`, so nothing ran a real front end over
/// code round-tripped from real sources.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

/// A reduction of `path/lib/src/context.dart`'s `relative()` to the two
/// constructs that interact: a promotion-through-reassignment, and a cascade
/// that reads the promoted local.
const _sourceUnderTest = '''
class Parsed {
  Parsed(this.value);
  String value;
  void normalize() {}
}

class Ctx {
  String current = '/';

  String absolute(String p) => p;

  Parsed _parse(String path) => Parsed(path);

  String relative(String path, {String? from}) {
    from = from == null ? current : absolute(from);
    final fromParsed = _parse(from)..normalize();
    return fromParsed.value;
  }
}
''';

Directory _scratchPackage(String name, String librarySource) {
  final dir = Directory.systemTemp.createTempSync('ball_$name');
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: $name\n'
    'environment:\n'
    "  sdk: '^3.9.0'\n",
  );
  Directory('${dir.path}/lib').createSync();
  File('${dir.path}/lib/subject.dart').writeAsStringSync(librarySource);
  return dir;
}

Future<List<String>> _analyzeErrors(String compiled) async {
  final out = _scratchPackage('flow_promotion_analyze', 'const _ = 0;\n');
  addTearDown(() {
    if (out.existsSync()) out.deleteSync(recursive: true);
  });
  File('${out.path}/lib/subject.dart').writeAsStringSync(compiled);
  final analyze = await Process.run(
    'dart',
    ['analyze', '--format=machine', out.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return const LineSplitter()
      .convert('${analyze.stdout}\n${analyze.stderr}')
      .where((l) => l.startsWith('ERROR|'))
      .toList();
}

void main() {
  group(
    'promotion survives a round-tripped cascade (#573 case 1)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('flow_promotion_probe', _sourceUnderTest);
        final encoder = PackageEncoder(pkg);
        await encoder.prepareStaticTypes();
        expect(
          encoder.hasStaticTypes,
          isTrue,
          reason:
              'the analyzer resolved no file in the scratch package, so this '
              'suite would be vacuous. Warnings: ${encoder.warnings}',
        );
        compiled = DartCompiler(encoder.encode()).compileModule('lib.subject');
      });

      tearDownAll(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
      });

      test('the cascade compiles to Dart cascade syntax, not a closure', () {
        expect(
          compiled,
          contains('_parse(from)..normalize()'),
          reason: 'compiled output was:\n$compiled',
        );
        expect(
          compiled,
          isNot(contains('__cascade_self__')),
          reason:
              'the Block lowering leaks its temporary into the emitted Dart '
              'and, worse, wraps it in a closure. Output:\n$compiled',
        );
      });

      test('the compiled Dart passes the real `dart analyze`', () async {
        final errors = await _analyzeErrors(compiled);
        expect(
          errors,
          isEmpty,
          reason:
              'dart analyze rejected the compiled-back Dart:\n'
              '${errors.join('\n')}\n\n'
              'Compiled source was:\n$compiled',
        );
      });
    },
  );
}
