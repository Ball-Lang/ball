/// Explicit extension-override call syntax (issue #488,
/// `collection/lib/src/iterable_extensions.dart`).
///
/// `ExtensionName(receiver).member` is Dart's disambiguating call form. It is
/// a COMPILE-TIME construct only: it selects which extension's member to call
/// and then evaluates to exactly the same thing the plain `receiver.member`
/// would have, so erasing it to a plain member access is semantics-preserving.
///
/// The encoder had no `ast.ExtensionOverride` case at all, so the node fell to
/// `_encodeExpr`'s last-resort `/* unsupported: … */` STRING LITERAL and the
/// compiled Dart read
/// `'/* unsupported: ExtensionOverrideImpl: … */'.isSorted(compare)` — a method
/// call on a `String`. That is the shape `collection`'s
/// `IterableExtension(this).isSorted(compare)` measured.
///
/// An `ast.ExtensionOverride` node only ever exists in a RESOLVED AST (the
/// parser cannot know `IterableExtension` names an extension), so this suite
/// drives `PackageEncoder.prepareStaticTypes()`; the syntax-only
/// `encode(String)` path never builds the node and is unaffected.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

const _sourceUnderTest = r'''
extension NumberList on List<int> {
  int get doubledFirst => this[0] * 2;
  int scaled(int by) => this[0] * by;
}

class Holder {
  final List<int> items = <int>[2, 3];

  int viaOverrideCall() {
    return NumberList(items).scaled(3);
  }

  int viaOverrideGetter() {
    return NumberList(items).doubledFirst;
  }

  int viaPlainCall() {
    return items.scaled(3);
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

/// Every string literal in [root] — where the `/* unsupported: … */`
/// placeholder lands.
List<String> _stringLiterals(Expression root) {
  final out = <String>[];
  void walk(Expression x) {
    switch (x.whichExpr()) {
      case Expression_Expr.literal:
        if (x.literal.hasStringValue()) out.add(x.literal.stringValue);
      case Expression_Expr.call:
        if (x.call.hasInput()) walk(x.call.input);
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

  walk(root);
  return out;
}

void main() {
  group(
    'extension-override call syntax (#488)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Program program;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('extension_override_probe', _sourceUnderTest);
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

      test('an override CALL encodes to a real call, not a placeholder', () {
        expect(
          _stringLiterals(bodyOf('viaOverrideCall')),
          isNot(contains(contains('unsupported:'))),
          reason:
              '`NumberList(items).scaled(3)` must encode as a call on `items`; '
              'the unsupported placeholder compiles to a method call on a '
              'String literal.',
        );
      });

      test(
        'an override GETTER encodes to a real access, not a placeholder',
        () {
          expect(
            _stringLiterals(bodyOf('viaOverrideGetter')),
            isNot(contains(contains('unsupported:'))),
          );
        },
      );

      test('the compiled override call names the receiver, not a literal', () {
        expect(
          compiled,
          contains('items.scaled(3)'),
          reason:
              'an extension override erases to the plain member access on its '
              'single argument. Compiled output was:\n$compiled',
        );
        expect(
          compiled,
          contains('items.doubledFirst'),
          reason: 'compiled output was:\n$compiled',
        );
      });

      test('the compiled Dart passes the real `dart analyze`', () async {
        final out = _scratchPackage(
          'extension_override_analyze',
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
