/// Coverage + freshness guard for the std MODULE BUILDERS.
///
/// The builders in `std.dart`, `std_collections.dart`, `std_memory.dart`,
/// `std_io.dart`, `std_time.dart`, `std_fs.dart`, `std_concurrency.dart`,
/// `std_convert.dart` and `ball_proto.dart` construct the universal module
/// definitions every target compiler/engine implements. At runtime engines
/// read the *embedded* std (from a program's JSON), so these Dart builders are
/// only otherwise exercised by the `gen_std`/`gen_ball_proto` tools — leaving
/// them at ~0% line coverage.
///
/// This suite calls every builder (covering them) and asserts two things:
///  1. **Freshness** — `buildStdModule()` and `buildBallProtoModule()` must
///     reproduce the committed `std.json` / `ball_proto.json` byte-for-byte
///     (same path `gen_std.dart`/`gen_ball_proto.dart` use). A drift here means
///     the artifact was hand-edited or a builder changed without regenerating.
///  2. **Well-formedness** — every module has a name + functions, names are
///     unique, and a base function (impl supplied per-platform) carries NO body.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart';
import 'package:test/test.dart';

/// Re-serializes [m] exactly as `gen_std.dart`/`gen_ball_proto.dart` do.
String _genJson(Module m) =>
    '${const JsonEncoder.withIndent('  ').convert(encodeBallFileJson(m))}\n';

String _norm(String s) => s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// Locates a committed artifact under `dart/shared/`, tolerating whichever
/// directory the suite is launched from (package dir, repo root, sibling pkg).
File _sharedArtifact(String name) {
  for (final base in ['.', 'dart/shared', '../shared', '../../dart/shared']) {
    final f = File('$base/$name');
    if (f.existsSync()) return f;
  }
  throw StateError(
    'could not locate $name relative to ${Directory.current.path}',
  );
}

void main() {
  group('std module builders', () {
    test('buildStdModule() is byte-for-byte in sync with std.json', () {
      expect(
        _norm(_genJson(buildStdModule())),
        _norm(_sharedArtifact('std.json').readAsStringSync()),
        reason:
            'std.json is stale — regenerate with '
            '`cd dart/shared && dart run bin/gen_std.dart .`',
      );
    });

    test(
      'buildBallProtoModule() is byte-for-byte in sync with ball_proto.json',
      () {
        expect(
          _norm(_genJson(buildBallProtoModule())),
          _norm(_sharedArtifact('ball_proto.json').readAsStringSync()),
          reason:
              'ball_proto.json is stale — regenerate with '
              '`cd dart/shared && dart run bin/gen_ball_proto.dart .`',
        );
      },
    );

    // Every builder → its expected module name. Calling each one covers its
    // source file; the invariants below make it a real test, not a no-op.
    final builders = <String, Module Function()>{
      'std': buildStdModule,
      'std_collections': buildStdCollectionsModule,
      'std_memory': buildStdMemoryModule,
      'std_io': buildStdIoModule,
      'std_time': buildStdTimeModule,
      'std_fs': buildStdFsModule,
      'std_concurrency': buildStdConcurrencyModule,
      'std_convert': buildStdConvertModule,
      'ball_proto': buildBallProtoModule,
    };

    builders.forEach((expectedName, build) {
      test('$expectedName: well-formed module', () {
        final m = build();
        expect(m.name, expectedName, reason: 'unexpected module name');
        expect(m.functions, isNotEmpty, reason: 'module declares no functions');

        final names = m.functions.map((f) => f.name).toList();
        expect(
          names.toSet().length,
          names.length,
          reason: 'duplicate function name(s) in $expectedName',
        );

        for (final f in m.functions) {
          expect(f.name, isNotEmpty, reason: 'function with empty name');
          // Core invariant: base functions get their impl per-platform and
          // MUST have no body (CLAUDE.md "Base functions have no body").
          if (f.isBase) {
            expect(
              f.hasBody(),
              isFalse,
              reason: '${m.name}.${f.name} is base but carries a body',
            );
          }
        }
      });
    });
  });
}
