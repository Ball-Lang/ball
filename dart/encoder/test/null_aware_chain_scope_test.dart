/// Null-aware CHAIN scope (issue #488, `async/lib/src/cancelable_operation.dart`).
///
/// Dart's `?.` short-circuits **everything to its right** in a postfix chain,
/// not just its own link: `x?.a.b(c)` means `x == null ? null : x.a.b(c)`, NOT
/// `(x == null ? null : x.a).b(c)`. The encoder lowered each link in isolation
/// (`_buildNullAwareAccess` / `_buildNullAwareCall` are leaf-level and cannot
/// see what follows them), so the guard collapsed one link early and every
/// FOLLOWING link was applied unconditionally to its result.
///
/// That is a semantics bug on every target, not only a `dart analyze` one: on a
/// null receiver the guard evaluates to `null` and the engine then still
/// invokes `.b(c)` on it. It is what `async/lib/src/cancelable_operation.dart`
/// measured as
/// `The method 'then' can't be unconditionally invoked because the receiver can
/// be 'null'` — the source there is
/// `_completer._inner?.future.then((value) { … })`, a `?.` in the MIDDLE of a
/// three-link chain.
///
/// The fix is chain-aware, so unlike #488's receiver-TYPE slices it is NOT
/// gated on resolved types — `?.` is a syntactic fact. This suite still drives
/// it through `PackageEncoder.prepareStaticTypes()` because only a resolved,
/// compilable package can be handed to the REAL `dart analyze`, which is the
/// ground-truth assertion here: a lowering that type-checks is a lowering whose
/// guard covers the whole chain.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

const _sourceUnderTest = r'''
class Leaf {
  int value = 1;
  int twice(int x) => x * 2;
}

class Node {
  Leaf leaf = Leaf();
  int tag = 7;
}

class Holder {
  Node? _node;

  // Two links after the `?.`: a field access, then a method call.
  int? callThroughChain() {
    return _node?.leaf.twice(2);
  }

  // One link after the `?.`: a plain field access.
  int? readThroughChain() {
    return _node?.leaf.value;
  }

  // The single-link shape the encoder already got right — a regression guard
  // so the chain fix does not change what it emits.
  int? readSingleLink() {
    return _node?.tag;
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

/// True when [e] is the `std.if(equals(x, null), null, …)` guard the encoder
/// emits for `?.`, or the `Block` that binds a temp before one.
bool _isNullGuard(Expression e) {
  if (e.whichExpr() == Expression_Expr.call) {
    return e.call.module == 'std' && e.call.function == 'if';
  }
  if (e.whichExpr() == Expression_Expr.block) {
    for (final s in e.block.statements) {
      if (s.hasLet() && s.let.hasMetadata()) {
        final kind = s.let.metadata.fields['kind']?.stringValue;
        if (kind == 'null_aware_access' || kind == 'null_aware_call') {
          return true;
        }
      }
    }
  }
  return false;
}

/// Every place a null guard is used as the RECEIVER of a further chain link —
/// exactly the mis-scoping this suite exists to forbid.
List<String> _guardsUsedAsReceiver(Expression root) {
  final out = <String>[];
  void walk(Expression x) {
    switch (x.whichExpr()) {
      case Expression_Expr.fieldAccess:
        if (x.fieldAccess.hasObject()) {
          if (_isNullGuard(x.fieldAccess.object)) {
            out.add('fieldAccess .${x.fieldAccess.field_2} on a null guard');
          }
          walk(x.fieldAccess.object);
        }
      case Expression_Expr.call:
        if (x.call.hasInput()) {
          final input = x.call.input;
          if (input.whichExpr() == Expression_Expr.messageCreation) {
            for (final f in input.messageCreation.fields) {
              // Receiver-position field names only. `value` is deliberately
              // absent: it is also an ordinary OPERAND name (`std.throw`,
              // `std.to_string`), where a guard is a legitimate argument.
              const receiverFields = {'self', 'list', 'map', 'set'};
              if (receiverFields.contains(f.name) && _isNullGuard(f.value)) {
                out.add(
                  '${x.call.module}.${x.call.function} receiver '
                  '(${f.name}) is a null guard',
                );
              }
            }
          }
          walk(input);
        }
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
      case Expression_Expr.lambda:
        if (x.lambda.hasBody()) walk(x.lambda.body);
      case _:
        break;
    }
  }

  walk(root);
  return out;
}

void main() {
  group(
    'null-aware chain scope (#488)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Program program;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('null_aware_chain_probe', _sourceUnderTest);
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
        return subject.functions
            .firstWhere((f) => f.name.endsWith(':Holder.$method'))
            .body;
      }

      test('a `?.` guards every FOLLOWING link of the chain (call)', () {
        expect(
          _guardsUsedAsReceiver(bodyOf('callThroughChain')),
          isEmpty,
          reason:
              '`_node?.leaf.twice(2)` must lower to '
              '`_node == null ? null : _node.leaf.twice(2)`. A guard used as a '
              'receiver means the short-circuit stopped one link early, so on '
              'a null receiver every engine evaluates the guard to null and '
              'then invokes the next link ON null.',
        );
      });

      test('a `?.` guards every FOLLOWING link of the chain (access)', () {
        expect(
          _guardsUsedAsReceiver(bodyOf('readThroughChain')),
          isEmpty,
          reason:
              '`_node?.leaf.value` must lower with one guard over `.value` '
              'too, not `(_node == null ? null : _node.leaf).value`.',
        );
      });

      test('the single-link shape still emits exactly one guard', () {
        final body = bodyOf('readSingleLink');
        expect(
          _isNullGuard(body) ||
              (body.whichExpr() == Expression_Expr.block &&
                  body.block.hasResult() &&
                  _isNullGuard(body.block.result)),
          isTrue,
          reason:
              'no over-correction: `_node?.tag` is a one-link chain and keeps '
              'the lowering it already had. Body was: $body',
        );
      });

      test('the syntax-only encoder lowers the chain identically', () {
        // `?.` is syntactic, so unlike #488's receiver-TYPE slices this fix is
        // NOT gated on resolved types — `encode(String)` must fix it too.
        final syntactic = DartEncoder().encode(
          'void main() {\n'
          '  final h = Holder();\n'
          '  print(h.leaf?.inner.twice(2));\n'
          '}\n',
        );
        final fn = syntactic.modules
            .firstWhere((m) => m.name == 'main')
            .functions
            .firstWhere((f) => f.name.endsWith('main'));
        expect(_guardsUsedAsReceiver(fn.body), isEmpty);
      });

      test('the compiled Dart passes the real `dart analyze`', () async {
        final out = _scratchPackage(
          'null_aware_chain_analyze',
          'const _ = 0;\n',
        );
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
