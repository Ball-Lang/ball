/// Single-source the `ball` CLI version from `pubspec.yaml` (issue #363).
///
/// Reads `version:` from `dart/cli/pubspec.yaml` and writes
/// `lib/src/version.g.dart` (`const ballCliVersion = '<version>';`). Run from the
/// package root:
///
///   cd dart/cli && dart run tool/gen_version.dart
///
/// Pass `--check` for the CI drift guard: exits non-zero (without writing) if
/// `lib/src/version.g.dart` is missing or out of date, so a melos version bump can
/// never leave `ball version` reporting a stale number.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

void main(List<String> args) {
  final check = args.contains('--check');
  final root = _findPackageRoot();
  final pubspec = File('$root/pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('gen_version: pubspec.yaml not found at ${pubspec.path}');
    exit(2);
  }

  final doc = loadYaml(pubspec.readAsStringSync());
  if (doc is! YamlMap || doc['version'] == null) {
    stderr.writeln('gen_version: no `version:` in pubspec.yaml');
    exit(2);
  }
  final version = doc['version'].toString();

  final outFile = File('$root/lib/src/version.g.dart');
  final expected = _render(version);

  if (check) {
    final actual = outFile.existsSync() ? outFile.readAsStringSync() : '';
    if (actual != expected) {
      stderr.writeln(
        'gen_version: lib/src/version.g.dart is stale (pubspec version '
        '"$version"). Run: cd dart/cli && dart run tool/gen_version.dart',
      );
      exit(1);
    }
    stdout.writeln(
      'gen_version: lib/src/version.g.dart matches pubspec ($version)',
    );
    return;
  }

  outFile.writeAsStringSync(expected);
  stdout.writeln(
    'gen_version: wrote lib/src/version.g.dart (version $version)',
  );
}

String _render(String version) =>
    '// GENERATED — DO NOT EDIT BY HAND.\n'
    '//\n'
    '// Single source of truth for the `ball` CLI version (issue #363): this '
    'constant\n'
    '// is generated from `dart/cli/pubspec.yaml` so `ball version` can never '
    'drift\n'
    '// from the published package version.\n'
    '//\n'
    '// Regenerate:  cd dart/cli && dart run tool/gen_version.dart\n'
    '// CI drift guard: dart run tool/gen_version.dart --check\n'
    "const ballCliVersion = '$version';\n";

String _findPackageRoot() {
  var dir = Directory.current;
  while (true) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync()) {
      final text = pubspec.readAsStringSync();
      if (text.contains('name: ball_cli')) {
        return dir.path.replaceAll('\\', '/');
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate the ball_cli package root');
    }
    dir = parent;
  }
}
