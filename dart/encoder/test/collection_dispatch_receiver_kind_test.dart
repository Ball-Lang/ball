/// Receiver-TYPE-aware dispatch, slice 2 (issue #488).
///
/// `collection_dispatch_receiver_type_test.dart` (slice 1) proved the seam on
/// the `Set` receiver. This file covers the three shapes the issue's own
/// follow-up comment scoped as what was left:
///
///  1. **`Map…toList` vs `List.toList`.** `collectionRoutes['map']` is
///     unconditionally `std_collections.list_map`, whose Dart codegen ALWAYS
///     appends `.toList()`. `Map.map()` takes a two-parameter callback and
///     returns a new `Map`, so the compiled Dart called `.toList()` on a `Map`
///     — verbatim the issue's `"method 'toList' isn't defined for
///     'Map<K2, V2>'"` on `collection/lib/src/canonicalized_map.dart`.
///  2. **`String.contains` vs `Iterable.contains`.** A `String` receiver routed
///     into the `list_*` family exactly like a `List` one. It compiles to the
///     same text today, so this one is a modelling fix rather than a measured
///     failure — declining keeps a future `list_contains` refinement from
///     silently changing what `'abc'.contains(p)` means.
///  3. **Nullable-receiver `?.` preservation.** `x?.foo` was desugared to
///     `std.if(equals(x, null), null, x.foo)` with the receiver named TWICE.
///     For a local that is fine — Dart's flow analysis promotes it on the
///     else-branch. For a mutable FIELD (`Sink? _inner;`) promotion never
///     applies, so the compiled `_inner == null ? null : _inner.isPaused` is
///     rejected outright. That is the `async` family's failure in #488
///     (`stream_subscription_transformer.dart`, `cancelable_operation.dart`,
///     `stream_group.dart`).
///
/// Every fix here is gated on a RESOLVED receiver type, so the syntax-only
/// `encode(String)` / `encodeModule(String, …)` APIs — and therefore
/// `dart/self_host/engine.ball.json` and the whole cross-language self-hosted
/// engine pipeline — are bit-for-bit unchanged. `PackageEncoder
/// .prepareStaticTypes()` is the opt-in that supplies the resolved AST.
///
/// Like its slice-1 sibling, the final test runs the compiled-back Dart
/// through the REAL `dart analyze`: a receiver-type bug that only Dart's own
/// front end can see is exactly what this suite exists to catch.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

const _sourceUnderTest = r'''
class Sink {
  bool get isPaused => false;
  int notify(int value) => value;
}

class Probe {
  final Map<String, int> base = <String, int>{};
  final List<int> items = <int>[];
  final String text = 'abc';
  Sink? _inner;

  Map<String, String> remap() {
    return base.map((k, v) => MapEntry(k, '$v'));
  }

  List<String> listMap() {
    return items.map((x) => '$x').toList();
  }

  bool hasChar() {
    return text.contains('b');
  }

  bool hasItem() {
    return items.contains(3);
  }

  bool paused() {
    return _inner?.isPaused ?? false;
  }

  int? ping() {
    return _inner?.notify(1);
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

/// Every `module.function` the expression tree calls, flattened.
Set<String> _calledFunctions(Expression e) {
  final out = <String>{};
  void walk(Expression x) {
    switch (x.whichExpr()) {
      case Expression_Expr.call:
        final c = x.call;
        out.add('${c.module}.${c.function}');
        if (c.hasInput()) walk(c.input);
      case Expression_Expr.block:
        for (final s in x.block.statements) {
          if (s.hasExpression()) walk(s.expression);
          if (s.hasLet() && s.let.hasValue()) walk(s.let.value);
        }
        if (x.block.hasResult()) walk(x.block.result);
      case Expression_Expr.messageCreation:
        for (final f in x.messageCreation.fields) {
          walk(f.value);
        }
      case Expression_Expr.fieldAccess:
        if (x.fieldAccess.hasObject()) walk(x.fieldAccess.object);
      case Expression_Expr.lambda:
        if (x.lambda.hasBody()) walk(x.lambda.body);
      case _:
        break;
    }
  }

  walk(e);
  return out;
}

void main() {
  // The analyzer has a multi-second cold start and the last test spawns a real
  // `dart analyze`; the 30s default is uncomfortably tight on a loaded runner.
  group(
    'receiver-kind-aware dispatch, slice 2 (#488)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Program program;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('receiver_kind_probe', _sourceUnderTest);
        final encoder = PackageEncoder(pkg);
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

      Expression bodyOf(String method) {
        final subject = program.modules.firstWhere(
          (m) => m.name == 'lib.subject',
        );
        // Encoded member names are module-qualified: `lib.subject:Probe.remap`.
        return subject.functions
            .firstWhere((f) => f.name.endsWith(':Probe.$method'))
            .body;
      }

      test('Map.map() is not routed into the list_* family', () {
        expect(
          _calledFunctions(bodyOf('remap')),
          isNot(contains('std_collections.list_map')),
          reason:
              'std_collections.list_map models Iterable.map: its Dart codegen '
              'always appends .toList(), which a Map does not have (#488).',
        );
      });

      test('the compiled Map.map() has no trailing .toList()', () {
        expect(
          compiled,
          contains('base.map((k, v) => MapEntry(k, '),
          reason: 'compiled output was:\n$compiled',
        );
        expect(
          compiled,
          isNot(contains('.toList();\n  }\n\n  List<String> listMap')),
          reason:
              'remap() must not end in .toList(). Compiled output was:\n'
              '$compiled',
        );
      });

      test(
        'List.map().toList() still routes to list_map (no over-correction)',
        () {
          expect(
            _calledFunctions(bodyOf('listMap')),
            contains('std_collections.list_map'),
            reason:
                'a genuine Iterable receiver must keep its std_collections '
                'route — the fix declines only for a resolved Map/Set/String.',
          );
        },
      );

      test('String.contains is not routed into the list_* family', () {
        expect(
          _calledFunctions(bodyOf('hasChar')),
          isNot(contains('std_collections.list_contains')),
          reason:
              'a String receiver is not an Iterable receiver; modelling it as '
              'one is what issue #488 names as the String.contains case.',
        );
      });

      test('List.contains still routes to list_contains', () {
        expect(
          _calledFunctions(bodyOf('hasItem')),
          contains('std_collections.list_contains'),
        );
      });

      test('a null-aware access on a mutable field binds a local first', () {
        expect(
          compiled,
          isNot(contains('(_inner == null) ? null : _inner.isPaused')),
          reason:
              'Dart never promotes a non-final FIELD, so an unconditional '
              '`_inner.isPaused` on the else-branch is rejected outright. The '
              'fix binds the receiver to a local, which IS promotable. '
              'Compiled output was:\n$compiled',
        );
      });

      test('a null-aware call on a mutable field binds a local first', () {
        expect(
          compiled,
          isNot(contains('_inner.notify(1)')),
          reason:
              'same as the access case, for `_inner?.notify(1)`. Compiled '
              'output was:\n$compiled',
        );
      });

      test('the compiled Dart passes the real `dart analyze`', () async {
        final out = _scratchPackage('receiver_kind_analyze', 'const _ = 0;\n');
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

        // `--format=machine` prints one `SEVERITY|TYPE|CODE|FILE|…` line per
        // diagnostic; count only ERRORs so a lint or hint never reds the gate.
        final errors = const LineSplitter()
            .convert('${analyze.stdout}\n${analyze.stderr}')
            .where((l) => l.startsWith('ERROR|'))
            .toList();

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
