/// Cross-check: every std / std_collections base function the Dart ENCODER
/// routes a method call to must be DECLARED by the canonical module builder.
///
/// `std_builders_test.dart` only proves a builder is self-consistent (it
/// reproduces its committed JSON and has unique, body-less base functions). It
/// never compares a builder's declared set against any *consumer*. That blind
/// spot is what let issue #505 sit unnoticed: `dart/encoder/lib/encoder.dart`'s
/// `collectionRoutes` table routed `list.join(sep)` to
/// `std_collections.list_join`, `dart/compiler` emitted it, and
/// `dart/engine/lib/engine_std.dart` dispatched it — while
/// `buildStdCollectionsModule()` never declared it.
///
/// Nothing else in CI can see that class of drift:
///   * runtime never reads `std.json` — each encoder builds a program's
///     `modules[]` from the names it actually used, so a fixture that calls
///     `.join()` embeds its own ad-hoc `list_join` declaration and runs fine on
///     every engine;
///   * `check_encoder_completeness.dart` checks the OPPOSITE direction (every
///     encoder-emittable function has an executed fixture);
///   * `gen_std_coverage.dart` derives its canonical list from these very same
///     builders, so an omitted name can never surface there either.
///
/// This suite closes the loop by re-deriving the encoder's real routing surface
/// from its source text and asserting it is a SUBSET of what the builders
/// declare. It is deliberately scoped to `collectionRoutes`-shaped tuples
/// (`('<module>', '<function>', '<selfField>', minArgs, maxArgs)`), the one
/// emit site in the encoder that is a machine-readable table of
/// (module, function) pairs — extracting the encoder's *whole* emit surface
/// would need `gen_std_coverage.dart`'s deliberately over-matching heuristics,
/// which are fine for a report but would produce false positives in a gate.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart';
import 'package:test/test.dart';

/// Matches a `collectionRoutes`-style tuple literal, e.g.
/// `'join': ('std_collections', 'list_join', 'list', 0, 1),` — including the
/// multi-line form the formatter produces for long entries.
final _routeTuple = RegExp(
  r"\(\s*'(std|std_collections)'\s*,\s*'([A-Za-z0-9_]+)'\s*,",
  multiLine: true,
);

/// Locates a repo-relative file, tolerating whichever directory the suite is
/// launched from (package dir, repo root, sibling package).
File _repoFile(String relative) {
  for (final base in ['.', '..', '../..', '../../..']) {
    final f = File('$base/$relative');
    if (f.existsSync()) return f;
  }
  throw StateError(
    'could not locate $relative relative to ${Directory.current.path}',
  );
}

Map<String, Set<String>> _routedNames() {
  final src = _repoFile('dart/encoder/lib/encoder.dart').readAsStringSync();
  final routed = <String, Set<String>>{
    'std': <String>{},
    'std_collections': <String>{},
  };
  for (final m in _routeTuple.allMatches(src)) {
    routed[m.group(1)!]!.add(m.group(2)!);
  }
  return routed;
}

void main() {
  group('encoder routes vs. canonical std builders', () {
    late final Map<String, Set<String>> routed;

    setUpAll(() => routed = _routedNames());

    // POSITIVE FLOOR — a regex that silently stops matching (the table is
    // renamed, reformatted, or moved) would make every subset assertion below
    // pass vacuously. Assert the extraction actually found a realistic table.
    test('the route extraction is non-vacuous', () {
      expect(
        routed['std_collections'],
        hasLength(greaterThanOrEqualTo(20)),
        reason:
            'extracted ${routed['std_collections']!.length} std_collections '
            'routes from dart/encoder/lib/encoder.dart — the collectionRoutes '
            'table has always had 20+. The regex has stopped matching; fix it '
            'before trusting the subset assertions below.',
      );
      expect(
        routed['std'],
        hasLength(greaterThanOrEqualTo(15)),
        reason:
            'extracted ${routed['std']!.length} std routes from '
            'dart/encoder/lib/encoder.dart — the collectionRoutes table has '
            'always had 15+. The regex has stopped matching.',
      );
    });

    for (final (module, declaredNames) in <(String, Set<String> Function())>[
      ('std', () => buildStdModule().functions.map((f) => f.name).toSet()),
      (
        'std_collections',
        () => buildStdCollectionsModule().functions.map((f) => f.name).toSet(),
      ),
    ]) {
      test('every $module function the encoder routes to is declared by its '
          'builder', () {
        final declared = declaredNames();
        final missing = routed[module]!.difference(declared).toList()..sort();
        expect(
          missing,
          isEmpty,
          reason:
              'MISSING (routed but not declared) in $module: '
              '{${missing.join(', ')}}\n'
              'dart/encoder/lib/encoder.dart routes method calls to these '
              'base functions, and dart/compiler + dart/engine implement '
              'them by hardcoded name, but build${module == 'std' ? 'Std' : 'StdCollections'}Module() '
              'never declares them — so they are absent from the canonical '
              'inventory (dart/shared/std.json, std.bin, '
              'tests/conformance/std_coverage.json). Add an _fn(...) entry '
              'in dart/shared/lib/$module.dart and regenerate with '
              '`cd dart/shared && dart run bin/gen_std.dart` plus '
              '`cd dart/encoder && dart run bin/gen_std_coverage.dart` '
              '(issue #505).',
        );
      });
    }
  });
}
