/// Explicit extension-override call syntax (issue #488 →  #670,
/// `collection/lib/src/iterable_extensions.dart`).
///
/// `ExtensionName(receiver).member` names WHICH extension supplies the member.
/// It is written precisely when the plain `receiver.member` would resolve to
/// something ELSE — `collection`'s own source is the canonical case:
///
/// ```dart
/// extension IterableComparableExtension<T extends Comparable<T>> on Iterable<T> {
///   bool isSorted([Comparator<T>? compare]) {
///     if (compare != null) {
///       return IterableExtension(this).isSorted(compare);   // the OTHER one
///     }
///     …
///   }
/// }
/// ```
///
/// Before #670's encoder slice the node had no `_encodeExpr` case at all, so it
/// fell to the last-resort `/* unsupported: … */` STRING LITERAL and the
/// compiled Dart called the member ON that string. The obvious repair — erase
/// the override to its single argument — is **unsound**, and that measurement
/// is why this file exists: erasing the snippet above makes `isSorted` call
/// ITSELF. Measured with the real Tier B harness against `collection@96afcc2`:
/// `1706 → 1702 passing, 4 failing` (`.isSorted empty` / `single` / `same`).
/// Trading a loud build error for a silently wrong answer is strictly worse.
///
/// The sound encoding names the extension member in the CALL, which the IR can
/// already express: the encoder declares extension members as module functions
/// called `<module>:<Ext>.<member>` (`_encodeExtensionDeclaration` →
/// `_encodeMethodDeclaration`), so an override encodes as a `FunctionCall` with
/// that `function` name and the receiver in `self`. No schema change — the name
/// carries the meaning, so it survives metadata stripping (invariant 2; see
/// `docs/METADATA_SPEC.md`). `dart/compiler` re-emits the override form from
/// the `kind: 'extension'` typeDef.
///
/// The contract this suite pins, in both directions:
///   * an override on an extension THIS module declares encodes as that
///     extension's member and compiles back to the override form;
///   * an override the encoder cannot name soundly (an imported or
///     cross-module extension, or one carrying explicit type arguments) is
///     REFUSED LOUDLY — a warning that names the construct, and a placeholder
///     that breaks the front end — never a plain member access, because that
///     can resolve to a different member than the source named.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

/// The shape `collection/lib/src/iterable_extensions.dart` actually uses: two
/// extensions on the same type declaring the SAME member name, where the
/// override is the only thing keeping the call from recursing into itself.
const _sourceUnderTest = r'''
extension ByCompare on List<int> {
  bool isSorted(int Function(int, int) compare) {
    for (var i = 1; i < length; i++) {
      if (compare(this[i - 1], this[i]) > 0) return false;
    }
    return true;
  }
}

extension Natural on List<int> {
  bool isSorted([int Function(int, int)? compare]) {
    if (compare != null) {
      return ByCompare(this).isSorted(compare);
    }
    for (var i = 1; i < length; i++) {
      if (this[i - 1] > this[i]) return false;
    }
    return true;
  }
}
''';

/// An override the encoder must still REFUSE: the extension lives in another
/// library, so this module cannot name its Ball function soundly.
const _importedOverrideSource = r'''
import 'elsewhere.dart';

int firstOrZero(List<int> xs) => Elsewhere(xs).firstOrZero();
''';

const _elsewhereSource = r'''
extension Elsewhere on List<int> {
  int firstOrZero() => isEmpty ? 0 : this[0];
}
''';

/// Creates a self-contained scratch package: `pubspec.yaml` + library files.
Directory _scratchPackage(String name, Map<String, String> libFiles) {
  final dir = Directory.systemTemp.createTempSync('ball_$name');
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: $name\n'
    'environment:\n'
    "  sdk: '^3.9.0'\n",
  );
  Directory('${dir.path}/lib').createSync();
  for (final MapEntry(key: relName, value: source) in libFiles.entries) {
    File('${dir.path}/lib/$relName').writeAsStringSync(source);
  }
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
  group(
    'extension-override call syntax (#488 / #670)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late PackageEncoder encoder;
      late Program program;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('extension_override_probe', {
          'subject.dart': _sourceUnderTest,
        });
        encoder = PackageEncoder(pkg);
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

      Expression bodyOf(String suffix) {
        final subject = program.modules.firstWhere(
          (m) => m.name == 'lib.subject',
        );
        return subject.functions
            .firstWhere((f) => f.name.endsWith(suffix))
            .body;
      }

      test('the override encodes as the NAMED extension member', () {
        final called = _calledFunctions(bodyOf(':Natural.isSorted'));
        expect(
          called,
          contains('lib.subject.lib.subject:ByCompare.isSorted'),
          reason:
              'the call must name WHICH extension supplies `isSorted`; a bare '
              '`isSorted` resolves to `Natural.isSorted`, i.e. itself. Calls '
              'were: $called',
        );
      });

      test('the receiver travels in `self`', () {
        final subject = program.modules.firstWhere(
          (m) => m.name == 'lib.subject',
        );
        final fn = subject.functions.firstWhere(
          (f) => f.name.endsWith(':Natural.isSorted'),
        );
        FunctionCall? found;
        void walk(Expression x) {
          switch (x.whichExpr()) {
            case Expression_Expr.call:
              if (x.call.function.endsWith(':ByCompare.isSorted')) {
                found = x.call;
              }
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

        walk(fn.body);
        expect(found, isNotNull, reason: 'no qualified extension call found');
        expect(
          found!.input.whichExpr(),
          Expression_Expr.messageCreation,
          reason: 'the call input must be an argument message',
        );
        expect(
          found!.input.messageCreation.fields.map((f) => f.name),
          contains('self'),
          reason:
              'the override receiver is the extension member\'s `self`, the '
              'same field every other instance call uses.',
        );
      });

      test('the compiled Dart re-emits the override form', () {
        expect(
          compiled,
          contains('ByCompare(this).isSorted(compare)'),
          reason:
              'the compiler must rebuild `Ext(receiver).member(args)` from the '
              'qualified name + `self`. Compiled output was:\n$compiled',
        );
      });

      test('the override is NOT erased into a self-recursive call', () {
        // `ByCompare(this).isSorted(compare)` erased to `this.isSorted(compare)`
        // resolves, inside `Natural.isSorted`, to `Natural.isSorted` itself.
        // Tier B measures that as 4 real test failures on `collection`; here it
        // is forbidden outright.
        expect(
          compiled,
          isNot(contains('this.isSorted(compare)')),
          reason:
              'an erased override calls the WRONG member. Compiled output '
              'was:\n$compiled',
        );
        expect(compiled, isNot(contains('return isSorted(compare)')));
      });

      test('the same-module override leaves no placeholder behind', () {
        expect(
          compiled,
          isNot(contains('unsupported:')),
          reason: 'compiled output was:\n$compiled',
        );
      });

      test('the compiled Dart passes the real `dart analyze`', () async {
        final out = _scratchPackage('extension_override_analyze', {
          'subject.dart': compiled,
        });
        addTearDown(() {
          if (out.existsSync()) out.deleteSync(recursive: true);
        });

        final analyze = await Process.run('dart', [
          'analyze',
          '--format=machine',
          out.path,
        ]);
        final diagnostics = (analyze.stdout as String)
            .split('\n')
            .where((l) => l.startsWith('ERROR|'))
            .toList();
        expect(
          diagnostics,
          isEmpty,
          reason:
              'the compiled-back extension override must be valid Dart. '
              'Compiled output was:\n$compiled',
        );
      });
    },
  );

  group(
    'an unnameable extension override is refused LOUDLY (#670)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late PackageEncoder encoder;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('extension_override_imported', {
          'subject.dart': _importedOverrideSource,
          'elsewhere.dart': _elsewhereSource,
        });
        encoder = PackageEncoder(pkg);
        await encoder.prepareStaticTypes();
        expect(encoder.hasStaticTypes, isTrue);
        final program = encoder.encode();
        compiled = DartCompiler(program).compileModule('lib.subject');
      });

      tearDownAll(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
      });

      test('the encoder REPORTS the construct instead of dropping it', () {
        expect(
          encoder.warnings.where((w) => w.contains('Extension-override')),
          isNotEmpty,
          reason:
              'silence is what made this shape invisible to every gate. All '
              'warnings were: ${encoder.warnings}',
        );
      });

      test('the warning names the offending source and the issue', () {
        final warning = encoder.warnings.firstWhere(
          (w) => w.contains('Extension-override'),
        );
        expect(warning, contains('Elsewhere(xs)'));
        expect(warning, contains('#670'));
      });

      test('the refusal is a placeholder, never a plain member access', () {
        // Not an endorsement of the placeholder — a guard that the construct
        // stays LOUD (it breaks the front end) rather than compiling to
        // something plausible that resolves elsewhere.
        expect(compiled, contains('unsupported:'));
        expect(
          compiled,
          isNot(contains('xs.firstOrZero()')),
          reason:
              'erasing the override to the plain access is the measured-unsound '
              'repair (#670). Compiled output was:\n$compiled',
        );
      });
    },
  );
}
