/// Gate: `std_concurrency` is a BASE module to the Dart compiler, and every
/// module a `dart/shared` builder declares is one.
///
/// WHY THIS EXISTS (issue #606). `DartCompiler._isBaseModule` enumerated eight
/// module names by hand — `std`, `std_memory`, `std_collections`, `std_io`,
/// `std_convert`, `std_fs`, `std_time`, `ball_proto` — and `std_concurrency`
/// was simply absent. `_compileCall` therefore never routed a
/// `std_concurrency.*` call into `_compileBaseCall`: it fell through to the
/// USER-function path and emitted a bare `thread_spawn(ThreadInput(...))`,
/// which does not compile (`Method not found`), with no diagnostic at all — not
/// even the `/* unsupported: std.<fn> */` marker the `std` switch's default arm
/// produces. That is the silent-degradation class CLAUDE.md's "fail loud" rule
/// forbids.
///
/// Nothing could see it. `base_modules_test.dart` pins the lowering of each
/// module the dispatcher already KNOWS about, so a module missing from the
/// dispatcher is missing from that test too — the blind spot is the same shape
/// as issue #505's (`dart/shared/test/std_routed_declarations_test.dart`), and
/// so is the fix: derive the expected set from the canonical builders instead of
/// from a second hand-written list, and re-read the dispatcher's own source so
/// the two can be compared at all.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

// ── Ball IR builders (same shape as base_modules_test.dart) ────────────────

Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));

Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);

FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

Expression _call(String module, String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = module
        ..function = fn
        ..input = (Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = ''
            ..fields.addAll(fields))));

/// A program whose `main` body is [expr], declaring every `std_concurrency`
/// base function the canonical builder declares.
Program _program(Expression expr) {
  final concurrency = Module()
    ..name = 'std_concurrency'
    ..functions.addAll([
      for (final f in buildStdConcurrencyModule().functions)
        FunctionDefinition()
          ..name = f.name
          ..isBase = true,
    ]);
  return Program()
    ..name = 'std_concurrency_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      Module()
        ..name = 'std'
        ..functions.add(
          FunctionDefinition()
            ..name = 'print'
            ..isBase = true,
        ),
      concurrency,
      Module()
        ..name = 'main'
        ..functions.add(
          FunctionDefinition()
            ..name = 'main'
            ..body = expr,
        ),
    ]);
}

String _compile(Expression expr) =>
    DartCompiler(_program(expr), noFormat: true).compile();

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

/// The module names `DartCompiler._isBaseModule` accepts, re-derived from its
/// own source text. It is a private static with no runtime seam, and the point
/// of the gate is exactly that its hand-written list can fall behind the
/// builders — so the list itself is what has to be read.
Set<String> _dispatcherModules() {
  final src = _repoFile('dart/compiler/lib/compiler.dart').readAsStringSync();
  final start = src.indexOf('static bool _isBaseModule(String module) =>');
  if (start < 0) {
    throw StateError(
      '_isBaseModule is no longer declared as '
      '`static bool _isBaseModule(String module) =>` in '
      'dart/compiler/lib/compiler.dart — this gate can no longer read it. '
      'Update the extraction rather than deleting the gate.',
    );
  }
  final end = src.indexOf(';', start);
  final body = src.substring(start, end);
  return RegExp(
    r"module == '([A-Za-z0-9_]+)'",
  ).allMatches(body).map((m) => m.group(1)!).toSet();
}

void main() {
  group('_isBaseModule covers every declared base module', () {
    late final Set<String> dispatcher;

    setUpAll(() => dispatcher = _dispatcherModules());

    // POSITIVE FLOOR — an extraction that silently stops matching would make
    // the subset assertion below pass vacuously ("nothing found" must never
    // read as "nothing drifted").
    test('the dispatcher extraction is non-vacuous', () {
      expect(
        dispatcher,
        hasLength(greaterThanOrEqualTo(8)),
        reason:
            'extracted ${dispatcher.length} module names from '
            '_isBaseModule — it has always listed 8+. The extraction has '
            'stopped matching; fix it before trusting the assertion below.',
      );
    });

    test('every std module builder names a module _isBaseModule accepts', () {
      final declared = <String>{
        for (final m in <Module>[
          buildStdModule(),
          buildStdCollectionsModule(),
          buildStdIoModule(),
          buildStdMemoryModule(),
          buildStdConvertModule(),
          buildStdFsModule(),
          buildStdTimeModule(),
          buildStdConcurrencyModule(),
        ])
          m.name,
      };
      final missing = declared.difference(dispatcher).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason:
            'MISSING from DartCompiler._isBaseModule: {${missing.join(', ')}}\n'
            'A base module the canonical builders declare but the dispatcher '
            'does not know about is compiled as a USER function call: the '
            'emitted Dart names an identifier that does not exist, and the '
            'compiler says nothing. Add the module to _isBaseModule in '
            'dart/compiler/lib/compiler.dart AND give it a lowering in '
            '_compileBaseCall (issue #606).',
      );
    });
  });

  group('std_concurrency lowers instead of emitting a bare identifier', () {
    test('thread_spawn routes through the base-call path', () {
      final out = _compile(
        _call('std_concurrency', 'thread_spawn', [_field('body', _ref('cb'))]),
      );
      expect(
        out,
        isNot(contains('thread_spawn(')),
        reason:
            'the compiler emitted a bare `thread_spawn(...)` call — the '
            'user-function path — so the generated Dart names an identifier '
            'that does not exist (issue #606). Output:\n$out',
      );
      expect(
        out,
        isNot(contains('unsupported')),
        reason: 'the base-call path reached its default arm. Output:\n$out',
      );
    });

    test('no declared std_concurrency function survives as a bare call', () {
      // Derived from the canonical builder, so a function ADDED there without
      // a compiler lowering fails here rather than silently compiling to an
      // undefined identifier.
      final inputs = <String, List<FieldValuePair>>{
        'thread_spawn': [_field('body', _ref('cb'))],
        'thread_join': [_field('value', _ref('h'))],
        'mutex_create': [],
        'mutex_lock': [_field('value', _ref('h'))],
        'mutex_unlock': [_field('value', _ref('h'))],
        'scoped_lock': [_field('mutex', _ref('h')), _field('body', _ref('cb'))],
        'atomic_create': [_field('value', _intLit(1))],
        'atomic_load': [_field('value', _ref('h'))],
        'atomic_store': [
          _field('atomic', _ref('h')),
          _field('value', _intLit(2)),
        ],
        'atomic_compare_exchange': [
          _field('atomic', _ref('h')),
          _field('expected', _intLit(1)),
          _field('value', _intLit(2)),
        ],
      };
      final declared = buildStdConcurrencyModule().functions
          .map((f) => f.name)
          .toList();
      expect(
        declared.toSet().difference(inputs.keys.toSet()),
        isEmpty,
        reason:
            'std_concurrency.dart declares a function this test has no input '
            'shape for — add it to `inputs` so the lowering is actually '
            'exercised.',
      );
      for (final fn in declared) {
        final out = _compile(_call('std_concurrency', fn, inputs[fn]!));
        expect(
          out,
          isNot(contains('$fn(')),
          reason:
              'std_concurrency.$fn compiled to a bare `$fn(...)` call — an '
              'identifier the generated Dart never defines (issue #606). '
              'Output:\n$out',
        );
        expect(
          out,
          isNot(contains('unsupported')),
          reason:
              'std_concurrency.$fn reached an unsupported marker. '
              'Output:\n$out',
        );
      }
    });
  });
}
