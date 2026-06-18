/// CI gate: a conformance fixture whose NAME advertises a feature must
/// actually USE that feature's syntax. This prevents "false coverage" — a
/// fixture named for a construct it does not exercise, which reads as covered
/// to reviewers and tooling. (`92_list_comprehension.dart` was exactly this: an
/// imperative `for`+`.add()` loop, which let issue #55's collection-`for` bug
/// hide behind a green, plausibly-named test.)
///
/// Run from `dart/encoder`:
///   dart run bin/check_fixture_names.dart
library;

import 'dart:io';

/// name-substring -> a predicate the source must satisfy, with a human label.
class _Rule {
  final String nameContains;
  final bool Function(String src) sourceHas;
  final String requirement;
  const _Rule(this.nameContains, this.sourceHas, this.requirement);
}

final _rules = <_Rule>[
  _Rule(
    'comprehension',
    (s) => s.contains('[for') || s.contains('{for') || _hasCollectionFor(s),
    'a collection comprehension `[for ...]` / `{for ...}`',
  ),
  _Rule(
    'spread',
    (s) => s.contains('...'),
    'a spread element `...x` / `...?x`',
  ),
  _Rule(
    'null_aware',
    (s) => s.contains('?.') || s.contains('?['),
    'a null-aware access `?.` / `?[`',
  ),
  _Rule('cascade', (s) => s.contains('..'), 'a cascade `..`'),
];

/// `[ ... for (...) ... ]` / `{ ... for (...) ... }` where the `for` is a
/// collection element (after the opening bracket), not a leading `[for`.
bool _hasCollectionFor(String s) {
  final re = RegExp(r'[\[{][^\];}]*\bfor\s*\(');
  return re.hasMatch(s);
}

void main() {
  final repoRoot = _findRepoRoot();
  final srcDir = Directory('$repoRoot/tests/conformance/src');
  if (!srcDir.existsSync()) {
    stderr.writeln('Source directory not found: ${srcDir.path}');
    exit(2);
  }

  final violations = <String>[];
  final files =
      srcDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final f in files) {
    final name = f.uri.pathSegments.last;
    final lowerName = name.toLowerCase();
    final src = f.readAsStringSync();
    for (final rule in _rules) {
      if (lowerName.contains(rule.nameContains) && !rule.sourceHas(src)) {
        violations.add(
          '  - $name is named "*${rule.nameContains}*" but does not use '
          '${rule.requirement}',
        );
      }
    }
  }

  if (violations.isNotEmpty) {
    stderr.writeln(
      'ERROR: ${violations.length} conformance fixture(s) have a name that '
      'overstates their coverage:',
    );
    violations.forEach(stderr.writeln);
    stderr.writeln(
      'Either use the advertised construct, or rename the fixture to match '
      'what it actually tests.',
    );
    exit(1);
  }

  stdout.writeln(
    'OK: ${files.length} conformance fixtures — names match their content.',
  );
}

String _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path.replaceAll('\\', '/');
    }
    dir = dir.parent;
  }
  throw StateError('Cannot find repo root from ${Directory.current.path}');
}
