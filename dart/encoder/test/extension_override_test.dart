/// Explicit extension-override call syntax (issue #488 →  #670,
/// `collection/lib/src/iterable_extensions.dart`).
///
/// `ExtensionName(receiver).member` names WHICH extension supplies the member.
/// It is written precisely when the plain `receiver.member` would resolve to
/// something ELSE — `collection`'s own source is the canonical case:
///
/// ```dart
/// extension IterableComparableExtension<T extends Comparable<T>> on Iterable<T> {
///   bool isSorted([Comparator<T>? compare]) {
///     if (compare != null) {
///       return IterableExtension(this).isSorted(compare);   // the OTHER one
///     }
///     …
///   }
/// }
/// ```
///
/// The encoder has no `ast.ExtensionOverride` case, so the node falls to
/// `_encodeExpr`'s last-resort `/* unsupported: … */` STRING LITERAL and the
/// compiled Dart calls the member ON a String. The obvious repair — erase the
/// override to its single argument — is **unsound**, and this suite is the
/// proof: erasing the snippet above makes `isSorted` call ITSELF. Measured
/// with the real Tier B harness against `collection@96afcc2`:
/// `1706 → 1702 passing, 4 failing` (`.isSorted empty` / `single` / `same`).
/// That trades a loud build error for a silently wrong answer, which is worse.
///
/// So the contract this suite pins is the honest one:
///   * the encoder must REPORT the construct (a warning naming it), never
///     drop it silently as it did before;
///   * it must NOT emit a plain member access, because that can resolve to a
///     different member than the source named.
///
/// Encoding it faithfully needs the IR to carry which extension a member call
/// targets, plus a compiler rule to re-emit the override — a new capability,
/// tracked by #670.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

/// The shape `collection/lib/src/iterable_extensions.dart` actually uses: two
/// extensions on the same type declaring the SAME member name, where the
/// override is the only thing keeping the call from recursing into itself.
const _sourceUnderTest = r'''
extension ByCompare on List<int> {
  bool isSorted(int Function(int, int) compare) {
    for (var i = 1; i < length; i++) {
      if (compare(this[i - 1], this[i]) > 0) return false;
    }
    return true;
  }
}

extension Natural on List<int> {
  bool isSorted([int Function(int, int)? compare]) {
    if (compare != null) {
      return ByCompare(this).isSorted(compare);
    }
    for (var i = 1; i < length; i++) {
      if (this[i - 1] > this[i]) return false;
    }
    return true;
  }
}
''';

/// Creates a self-contained scratch package: `pubspec.yaml` + one library.
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

void main() {
  group(
    'extension-override call syntax (#488 / #670)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late PackageEncoder encoder;
      late Program program;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('extension_override_probe', _sourceUnderTest);
        encoder = PackageEncoder(pkg);
        await encoder.prepareStaticTypes();
        expect(
          encoder.hasStaticTypes,
          isTrue,
          reason:
              'the analyzer resolved no file in the scratch package, so this '
              'suite would be vacuous. Warnings: ${encoder.warnings}',
        );
        program = encoder.encode();
        compiled = DartCompiler(program).compileModule('lib.subject');
      });

      tearDownAll(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
      });

      test('the encoder REPORTS the construct instead of dropping it', () {
        expect(
          encoder.warnings.where((w) => w.contains('Extension-override')),
          isNotEmpty,
          reason:
              'silence is what made this shape invisible to every gate. All '
              'warnings were: ${encoder.warnings}',
        );
      });

      test('the warning names the offending source and the issue', () {
        final warning = encoder.warnings.firstWhere(
          (w) => w.contains('Extension-override'),
        );
        expect(warning, contains('ByCompare(this)'));
        expect(warning, contains('#670'));
      });

      test('the override is NOT erased into a self-recursive call', () {
        // `ByCompare(this).isSorted(compare)` erased to `this.isSorted(compare)`
        // resolves, inside `Natural.isSorted`, to `Natural.isSorted` itself.
        // Tier B measures that as 4 real test failures on `collection`; here it
        // is forbidden outright.
        expect(
          compiled,
          isNot(contains('this.isSorted(compare)')),
          reason:
              'an erased override calls the WRONG member. Compiled output '
              'was:\n$compiled',
        );
        expect(compiled, isNot(contains('return isSorted(compare)')));
      });

      test('the unencodable node still leaves a visible placeholder', () {
        // Not an endorsement of the placeholder — a guard that the construct
        // stays LOUD (it breaks the front end) rather than compiling to
        // something plausible. #670 replaces this with a real encoding.
        expect(compiled, contains('unsupported:'));
      });
    },
  );
}
