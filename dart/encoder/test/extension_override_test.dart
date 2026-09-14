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

import 'dart:convert';
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

  bool get flagged => length > 0;

  int tally() => length;
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

  // Every member below is ALSO declared by `ByCompare`, so the override is the
  // only thing selecting the other one.
  bool get flagged => false;

  int tally() => -1;

  bool otherFlagged() => ByCompare(this).flagged;

  int otherTally() => ByCompare(this).tally();
}
''';

/// An override the encoder must still REFUSE: the extension lives in another
/// library, so this module cannot name its Ball function soundly.
const _importedOverrideSource = r'''
import 'elsewhere.dart';

int firstOrZero(List<int> xs) => Elsewhere(xs).firstOrZero();

int head(List<int> xs) => Elsewhere(xs).headOrZero;

int viaCascade(List<int> xs) {
  Elsewhere(xs)..firstOrZero();
  return 0;
}
''';

const _elsewhereSource = r'''
extension Elsewhere on List<int> {
  int firstOrZero() => isEmpty ? 0 : this[0];

  int get headOrZero => isEmpty ? 0 : this[0];
}
''';

/// Type arguments written on the overridden MEMBER. They are not cosmetic:
/// `conv<String>()` and `conv()` reify DIFFERENT types, so dropping them turns
/// a loud refusal into a silently different answer — the failure mode the whole
/// override path exists to prevent. Runnable, because only executing it can
/// see a reified type.
const _memberTypeArgsSource = r'''
extension Convert on List<int> {
  List<R> conv<R>() => <R>[];

  List<R> pair<R>(R a, R b) => <R>[a, b];
}

void main() {
  print(Convert([1, 2]).conv<String>().runtimeType);
  print(Convert([1, 2]).conv<num>().runtimeType);
  print(Convert([1, 2]).pair<Object>('a', 1).runtimeType);
}
''';

/// An override in a WRITE position selects the extension's SETTER. It encodes
/// exactly like the getter read — a `self`-carrying call wrapped by
/// `std.assign` — so the ACCESSOR SHAPE the compiler picks is the whole
/// question. A setter-only member is absent from the getter set, so before the
/// fix it came back as `Slot(xs).only() = 9`: not parseable Dart, which made
/// `dart_style` throw out of `DartCompiler.compileModule` and the WHOLE module
/// produce no output at all — a far larger blast radius than the one broken
/// expression.
///
/// Runnable, because an accessor shape that merely PARSES can still write to
/// the wrong place.
const _writeTargetSource = r'''
extension Slot on List<int> {
  set only(int v) {
    this[0] = v;
  }

  int get slot => this[1];

  set slot(int v) {
    this[1] = v;
  }

  int get peek => this[0];
}

void main() {
  final xs = [1, 2];
  Slot(xs).only = 9;
  Slot(xs).slot += 1;
  Slot(xs).slot++;
  print(xs.join(','));
  print(Slot(xs).peek);
}
''';

/// Runs [source] with the SDK running this test and returns its normalised
/// stdout. A non-zero exit is a failure, never a silent empty string.
String _runDart(String source, Directory scratch, String name) {
  final file = File('${scratch.path}/$name.dart');
  file.writeAsStringSync(source);
  final result = Process.runSync(
    Platform.resolvedExecutable,
    ['run', file.absolute.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    fail(
      '`dart run` of $name failed (rc=${result.exitCode})\n'
      'stderr:\n${result.stderr}\n'
      '--- source ---\n$source',
    );
  }
  return (result.stdout as String).replaceAll('\r\n', '\n').trim();
}

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

      test('an override GETTER keeps its accessor shape', () {
        // `Ext(x).member` and `Ext(x).member()` encode identically (a call
        // carrying only `self`), so which one comes back is read from the
        // member's own `is_getter` — the accessor-shape family of #501/#664.
        expect(
          _calledFunctions(bodyOf(':Natural.otherFlagged')),
          contains('lib.subject.lib.subject:ByCompare.flagged'),
        );
        expect(
          compiled,
          contains('ByCompare(this).flagged;'),
          reason:
              'a getter must NOT be emitted as a call. Compiled output was:\n'
              '$compiled',
        );
      });

      test('an override zero-argument METHOD keeps its parentheses', () {
        expect(
          _calledFunctions(bodyOf(':Natural.otherTally')),
          contains('lib.subject.lib.subject:ByCompare.tally'),
        );
        expect(
          compiled,
          contains('ByCompare(this).tally()'),
          reason:
              'a zero-argument method must NOT be emitted as a tear-off. '
              'Compiled output was:\n$compiled',
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

      test('every refused shape is reported, not just the first', () {
        final reported = encoder.warnings
            .where((w) => w.contains('Extension-override'))
            .toList();
        // The method call, the getter access and the cascade target each reach
        // the refusal through a DIFFERENT encoder path.
        expect(
          reported.where((w) => w.contains('Elsewhere(xs).firstOrZero()')),
          isNotEmpty,
        );
        expect(
          reported.where((w) => w.contains('Elsewhere(xs).headOrZero')),
          isNotEmpty,
        );
        expect(
          reported.where((w) => w.endsWith('Elsewhere(xs)')),
          isNotEmpty,
          reason:
              'a bare override (here a cascade target) reaches `_encodeExpr` '
              'itself. All warnings were: ${encoder.warnings}',
        );
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

  group(
    "an override MEMBER's type arguments survive the round trip (#670)",
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Directory scratch;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('extension_override_type_args', {
          'subject.dart': _memberTypeArgsSource,
        });
        scratch = Directory.systemTemp.createTempSync(
          'ball_ext_type_args_run_',
        );
        final encoder = PackageEncoder(pkg);
        await encoder.prepareStaticTypes();
        expect(
          encoder.hasStaticTypes,
          isTrue,
          reason:
              'the analyzer resolved no file in the scratch package, so this '
              'suite would be vacuous. Warnings: ${encoder.warnings}',
        );
        final program = encoder.encode(entryFile: 'lib/subject.dart');
        compiled = DartCompiler(program).compileModule('lib.subject');
      });

      tearDownAll(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
        if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      });

      test('the compiled Dart keeps the member type argument', () {
        expect(
          compiled,
          contains('.conv<String>()'),
          reason:
              'dropping `<String>` reifies `List<dynamic>` instead. Compiled '
              'output was:\n$compiled',
        );
        expect(
          compiled,
          isNot(contains('.conv()')),
          reason:
              'a bare `conv()` is the silently-different instantiation. '
              'Compiled output was:\n$compiled',
        );
      });

      test('an override with BOTH type arguments and arguments keeps both', () {
        // The zero-argument and argument-bearing emissions are separate
        // branches of `_tryCompileExtensionOverride`; only covering the first
        // would leave the second free to drop them again.
        expect(
          compiled,
          contains(".pair<Object>('a', 1)"),
          reason: 'compiled output was:\n$compiled',
        );
      });

      test('the compiled-back program reifies the SAME types', () {
        final original = _runDart(_memberTypeArgsSource, scratch, 'original');
        final roundTripped = _runDart(compiled, scratch, 'round_tripped');
        expect(
          original,
          equals('List<String>\nList<num>\nList<Object>'),
          reason:
              'the probe must actually observe a reified type; if this changes '
              'the suite is no longer measuring what it claims to.',
        );
        expect(
          roundTripped,
          equals(original),
          reason:
              'the round trip reified a different type than the source named.\n'
              '--- original ---\n$original\n'
              '--- round-tripped ---\n$roundTripped\n'
              '--- compiled ---\n$compiled',
        );
      });
    },
  );

  group(
    'an override in a WRITE position round-trips (#670)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Directory scratch;
      late PackageEncoder encoder;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('extension_override_write', {
          'subject.dart': _writeTargetSource,
        });
        scratch = Directory.systemTemp.createTempSync('ball_ext_write_run_');
        encoder = PackageEncoder(pkg);
        await encoder.prepareStaticTypes();
        expect(encoder.hasStaticTypes, isTrue);
        final program = encoder.encode(entryFile: 'lib/subject.dart');
        // The regression this pins: this call used to THROW a
        // `FormatterException` ('Illegal assignment to non-assignable
        // expression'), so ONE mis-shaped expression produced no module output
        // at all.
        compiled = DartCompiler(program).compileModule('lib.subject');
      });

      tearDownAll(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
        if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      });

      test('the module still produces output', () {
        expect(
          compiled,
          isNotEmpty,
          reason:
              'a single mis-shaped expression must not take the whole '
              "module's output down with it.",
        );
        expect(compiled, contains('void main('));
      });

      test('no unassignable left-hand side is emitted', () {
        expect(
          compiled,
          isNot(contains('.only() =')),
          reason:
              '`Slot(xs).only() = 9` is not parseable Dart — this is exactly '
              'what threw. Compiled output was:\n$compiled',
        );
        expect(compiled, isNot(contains('.slot() +=')));
        expect(compiled, isNot(contains('.slot()++')));
      });

      test('each write shape keeps the override and the accessor shape', () {
        expect(compiled, contains('Slot(xs).only = 9'));
        expect(compiled, contains('Slot(xs).slot += 1'));
        expect(compiled, contains('Slot(xs).slot++'));
      });

      test('a READ through the same override is NOT over-refused', () {
        expect(
          compiled,
          contains('Slot(xs).peek'),
          reason: 'compiled output was:\n$compiled',
        );
        expect(
          compiled,
          isNot(contains('unsupported:')),
          reason:
              'a same-module override must never fall to the placeholder. '
              'Compiled output was:\n$compiled',
        );
      });

      test('the encoder reports nothing about these overrides', () {
        expect(
          encoder.warnings.where((w) => w.contains('Extension-override')),
          isEmpty,
          reason:
              'every extension here is local and unprefixed, so none of them '
              'is refused. Warnings were: ${encoder.warnings}',
        );
      });

      test('the compiled-back program writes to the SAME places', () {
        final original = _runDart(_writeTargetSource, scratch, 'original');
        final roundTripped = _runDart(compiled, scratch, 'round_tripped');
        expect(
          original,
          equals('9,4\n9'),
          reason:
              'the probe must actually observe each write; if this changes '
              'the suite is no longer measuring what it claims to.',
        );
        expect(
          roundTripped,
          equals(original),
          reason:
              'the round trip wrote somewhere else.\n'
              '--- original ---\n$original\n'
              '--- round-tripped ---\n$roundTripped\n'
              '--- compiled ---\n$compiled',
        );
      });

      test('the compiled Dart passes the real `dart analyze`', () async {
        final out = _scratchPackage('extension_override_write_analyze', {
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
              'the compiled-back write must be valid Dart. Compiled output '
              'was:\n$compiled',
        );
      });
    },
  );
}
