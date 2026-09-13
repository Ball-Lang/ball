/// `PackageEncoder.prepareStaticTypes()` is **fail-soft by contract**: a file
/// the analyzer will not resolve degrades to a `warnings` entry and a
/// syntax-only encode for that file, never an exception and never a lost
/// package.
///
/// That promise had no test for its per-file arm (issue #605). The shape below
/// is a real one: the analyzer EXCLUDES every path with a dot-segment
/// (`.hidden/`, `.dart_tool/`) from its context roots, while `PackageEncoder`'s
/// own file map is a plain recursive `lib/`+`bin/` walk that includes them — so
/// `collection.contextFor(path)` throws `StateError: Unable to find the
/// context to …` for exactly those files. The rest of the package must still
/// resolve.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

/// A self-contained scratch package: `pubspec.yaml` + one library.
Directory _scratchPackage(String name) {
  final dir = Directory.systemTemp.createTempSync('ball_$name');
  File(
    '${dir.path}/pubspec.yaml',
  ).writeAsStringSync('name: $name\nenvironment:\n  sdk: ^3.9.0\n');
  Directory('${dir.path}/lib').createSync();
  File(
    '${dir.path}/lib/subject.dart',
  ).writeAsStringSync('int visible() => 1;\n');
  return dir;
}

void main() {
  group(
    'prepareStaticTypes is fail-soft per file',
    // The analyzer has a multi-second cold start.
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;

      setUp(() {
        pkg = _scratchPackage('failsoft_probe');
      });

      tearDown(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
      });

      test('a file the analyzer refuses warns instead of throwing', () async {
        Directory('${pkg.path}/lib/.hidden').createSync();
        File(
          '${pkg.path}/lib/.hidden/excluded.dart',
        ).writeAsStringSync('int hidden() => 2;\n');

        final encoder = PackageEncoder(pkg);
        await encoder.prepareStaticTypes();

        // The unresolvable file is named in a warning…
        expect(
          encoder.warnings,
          contains(
            allOf(
              contains('excluded.dart'),
              contains('encoding it without receiver types'),
            ),
          ),
        );
        // …the rest of the package still resolved…
        expect(
          encoder.hasStaticTypes,
          isTrue,
          reason:
              'one unresolvable file must not disable receiver types for the '
              'whole package',
        );
        // …and the package still encodes, both modules included.
        final program = encoder.encode();
        final moduleNames = program.modules.map((m) => m.name).toSet();
        expect(moduleNames, contains('lib.subject'));
        expect(
          moduleNames.any((n) => n.contains('excluded')),
          isTrue,
          reason: 'the unresolved file is encoded syntax-only, never dropped',
        );
      });

      test('a clean package produces no warnings', () async {
        final encoder = PackageEncoder(pkg);
        await encoder.prepareStaticTypes();
        expect(encoder.warnings, isEmpty);
        expect(encoder.hasStaticTypes, isTrue);
      });
    },
  );
}
