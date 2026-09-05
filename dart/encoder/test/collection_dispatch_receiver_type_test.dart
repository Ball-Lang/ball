/// Receiver-TYPE-aware collection dispatch (issue #488).
///
/// `collection_dispatch_receiver_ambiguity_test.dart` covers the sibling
/// name+ARITY guard (#494). This file covers the other half: two methods that
/// share a name AND an arity but live on different receiver types.
///
/// `DartEncoder`'s `collectionRoutes` table maps `'add'` to
/// `std_collections.list_push`, which the Dart compiler emits as a CASCADE
/// (`xs..add(v)`) because `List.add` returns `void` and the cascade keeps the
/// receiver as the expression's value. On a `Set` that is wrong twice over:
/// `Set.add` returns `bool`, and Dart's own front end rejects the cascade —
/// `return s..add(x);` fails `return_of_invalid_type` in a `bool` function.
/// That is the exact defect issue #488 measured on `path/lib/src/path_set.dart`.
///
/// The syntax-only `encode(String)` / `encodeModule(String, ...)` APIs cannot
/// see this: `parseString` yields an unresolved AST where `staticType` is
/// always null. `PackageEncoder.prepareStaticTypes()` is the opt-in seam that
/// supplies a type-resolved AST, and these tests exercise it end to end:
///
///   1. **routing** — the encoded IR must not route a `Set` receiver into the
///      `list_*` family, and the compiled Dart must be a plain `s.add(x)`.
///   2. **the analyzer gate** — the compiled-back Dart is written to disk and
///      handed to the REAL `dart analyze`. Nothing in CI does this today:
///      `dart/encoder/tool/roundtrip_engine.dart` and its siblings already own
///      the machinery, but every call site in `ci.yml`,
///      `conformance-matrix.yml`, `regression-gates.yml` and the TS suites
///      passes `--skip-analyze`, so the checker never actually runs. This test
///      runs it, scoped to a small scratch package so it stays fast enough to
///      gate every PR.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:test/test.dart';

/// The #488 minimal repro, verbatim from the issue's own follow-up comment.
const _sourceUnderTest = '''
bool addFoo(Set<String> s, String x) {
  return s.add(x);
}

bool addBar(List<String> xs, String x) {
  xs.add(x);
  return true;
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

/// Every (module, function) pair the program calls, flattened.
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
  // The analyzer has a multi-second cold start and test 4 spawns a real
  // `dart analyze`, so the 30s default is uncomfortably tight on a loaded CI
  // runner. Raised deliberately — these tests do real work, they do not wait.
  group(
    'receiver-type-aware collection dispatch (#488)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Program program;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('receiver_type_probe', _sourceUnderTest);
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

      test('Set<T>.add(v) is not routed into the list_* family', () {
        final subject = program.modules.firstWhere(
          (m) => m.name == 'lib.subject',
        );
        final addFoo = subject.functions.firstWhere((f) => f.name == 'addFoo');
        expect(
          _calledFunctions(addFoo.body),
          isNot(contains('std_collections.list_push')),
          reason:
              'addFoo takes a Set<String>; routing its .add() through '
              'std_collections.list_push makes the Dart compiler emit the '
              'List-flavored cascade `s..add(x)` (issue #488).',
        );
      });

      test('List<T>.add(v) still routes to list_push (no over-correction)', () {
        final subject = program.modules.firstWhere(
          (m) => m.name == 'lib.subject',
        );
        final addBar = subject.functions.firstWhere((f) => f.name == 'addBar');
        expect(
          _calledFunctions(addBar.body),
          contains('std_collections.list_push'),
          reason:
              'a genuine List receiver must keep its std_collections route — the '
              'fix declines the route only when the receiver resolves to a Set.',
        );
      });

      test('the compiled Dart calls Set.add directly, not as a cascade', () {
        expect(
          compiled,
          contains('return s.add(x);'),
          reason: 'compiled output was:\n$compiled',
        );
        // Anchored on `return ` so `addBar`'s legitimate statement-position
        // `xs..add(x);` (which merely ENDS with `s..add(x)`) cannot satisfy it.
        expect(
          compiled,
          isNot(contains('return s..add(x)')),
          reason:
              'the cascade `s..add(x)` evaluates to the Set, not the bool '
              'Set.add returns (issue #488). Compiled output was:\n$compiled',
        );
      });

      test('the compiled Dart passes the real `dart analyze`', () async {
        final out = _scratchPackage('receiver_type_analyze', 'const _ = 0;\n');
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

        // `--format=machine` prints one `SEVERITY|TYPE|CODE|FILE|...` line per
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
