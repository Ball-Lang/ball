/// `x.isNotEmpty` must stay `x.isNotEmpty` (issue #674).
///
/// The encoder used to rewrite every `.isNotEmpty` as the NEGATION of
/// `.isEmpty` (`getterRoutes` routed `isEmpty` to `std.string_is_empty` and a
/// dedicated branch below it wrapped that in `std.not`). For an ordinary
/// `dart:core` collection the two are interchangeable. For a **delegating
/// receiver** they are not: the rewrite changes WHICH member the receiver is
/// asked for, and a wrapper, a mock, a proxy or a `noSuchMethod` forwarder can
/// see the difference.
///
/// That is not hypothetical. `collection/lib/src/wrappers.dart` @ 96afcc2 is
/// built on exactly this shape —
///
/// ```dart
/// bool get isNotEmpty => _base.isNotEmpty;
/// ```
///
/// — and `collection`'s own `wrapper_test.dart` asserts the forwarded
/// `Invocation`'s symbol. Compiled back through
/// `PackageEncoder.prepareStaticTypes()` → `DartCompiler.compileModule()` and
/// substituted in place, the Tier B harness measured 5 failures of the form
/// `Expected: Symbol:<Symbol("isEmpty")> Actual: Symbol:<Symbol("isNotEmpty")>`
/// for the `Iterable`, `List`, `Set`, `Queue` and `Map` wrappers (#674).
///
/// This suite is the in-repo, PR-gated version of that Tier B row: a scratch
/// package whose receiver RECORDS the member it was asked for, run for real
/// through `dart run` both as written and as compiled back. A member-identity
/// change is a behavioural change, so only executing it can see it — which is
/// precisely why nothing caught this before.
///
/// Note the receiver-type seam cannot fix this one: in `wrappers.dart` the
/// delegate's static type IS a `dart:core` `Iterable`. The member itself has
/// to round-trip, which is why `std.string_is_not_empty` exists.
///
/// So the property — "the receiver is asked for the member the source named" —
/// is kept by TWO different encodings, and this suite pins each on the receiver
/// kind that produces it:
///
///  * a `dart:core` delegate (`CoreWrapper`, the real `wrappers.dart` shape)
///    keeps the by-name route, and `.isNotEmpty` must reach
///    `std.string_is_not_empty` rather than `std.not(std.string_is_empty(...))`;
///  * a delegate whose own type DECLARES the member (`Wrapper` over `Probe`)
///    encodes as a plain `fieldAccess` naming that member, because #697's
///    receiver seam suppresses the route on proof — which asks the receiver for
///    the member even more directly, and is the only encoding that answers
///    `Probe`'s getter at all.
///
/// Both directions must hold at once; a change that collapsed either one back
/// onto `std.string_is_empty` is #674 returning.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

/// `Probe` records every member it is asked for and answers `true` to BOTH
/// `isEmpty` and `isNotEmpty`, so the negation rewrite is observable twice
/// over: in the recorded member name and in the answer itself.
const _sourceUnderTest = r'''
class Probe {
  final List<String> seen = <String>[];

  bool get isEmpty {
    seen.add('isEmpty');
    return true;
  }

  bool get isNotEmpty {
    seen.add('isNotEmpty');
    return true;
  }
}

/// The `collection/lib/src/wrappers.dart` shape: a wrapper that FORWARDS the
/// member to its base instead of computing it. This delegate's type is a class
/// THIS unit declares, and that class declares the member, so #697's receiver
/// seam suppresses the by-name route and the forward encodes as a plain member
/// access — the only encoding that reaches `Probe`'s getter.
class Wrapper {
  Wrapper(this._base);

  final Probe _base;

  bool get isEmpty => _base.isEmpty;
  bool get isNotEmpty => _base.isNotEmpty;
}

/// The same forward over a `dart:core` delegate — literally `wrappers.dart`'s
/// `Iterable<E> _base`. Nothing is provable about that receiver, so the by-name
/// route stands and the member has to survive AS a base function.
class CoreWrapper {
  CoreWrapper(this._base);

  final Iterable<String> _base;

  bool get isEmpty => _base.isEmpty;
  bool get isNotEmpty => _base.isNotEmpty;
}

void main() {
  final probe = Probe();
  final wrapper = Wrapper(probe);
  print(wrapper.isNotEmpty);
  print(probe.seen.join(','));
  final core = CoreWrapper(<String>['x']);
  print(core.isNotEmpty);
  print(core.isEmpty);
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

/// Runs [source] with the SDK that is running this test and returns its
/// normalised stdout. A non-zero exit is a test failure, never a silent empty
/// string.
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

/// Every field name the expression tree reads, flattened.
Set<String> _fieldAccessNames(Expression e) {
  final out = <String>{};
  void walk(Expression x) {
    switch (x.whichExpr()) {
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
        out.add(x.fieldAccess.field_2);
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
    'isNotEmpty keeps its own member identity (#674)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Directory scratch;
      late Program program;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('is_not_empty_probe', _sourceUnderTest);
        scratch = Directory.systemTemp.createTempSync('ball_is_not_empty_run_');
        final encoder = PackageEncoder(pkg);
        await encoder.prepareStaticTypes();
        expect(
          encoder.hasStaticTypes,
          isTrue,
          reason:
              'the analyzer resolved no file in the scratch package, so this '
              'suite would be vacuous. Warnings: ${encoder.warnings}',
        );
        program = encoder.encode(entryFile: 'lib/subject.dart');
        compiled = DartCompiler(program).compileModule('lib.subject');
      });

      tearDownAll(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
        if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      });

      Expression bodyOf(String member) {
        final subject = program.modules.firstWhere(
          (m) => m.name == 'lib.subject',
        );
        return subject.functions
            .firstWhere((f) => f.name.endsWith(member))
            .body;
      }

      test('a dart:core delegate forwards through its OWN std function', () {
        final called = _calledFunctions(bodyOf(':CoreWrapper.isNotEmpty'));
        expect(
          called,
          contains('std.string_is_not_empty'),
          reason:
              '`_base.isNotEmpty` on a `dart:core` receiver must round-trip as '
              'itself. Calls were: $called',
        );
        expect(
          called,
          isNot(contains('std.string_is_empty')),
          reason:
              'negating `isEmpty` asks the receiver for a DIFFERENT member '
              '(#674). Calls were: $called',
        );
      });

      test('isEmpty is untouched by the fix (no over-correction)', () {
        final called = _calledFunctions(bodyOf(':CoreWrapper.isEmpty'));
        expect(called, contains('std.string_is_empty'));
        expect(called, isNot(contains('std.string_is_not_empty')));
      });

      // #697's receiver seam and #674's route meet here: when the delegate's
      // own type declares the member, the route is suppressed on proof and the
      // forward encodes as a plain member access. That keeps #674's property —
      // the receiver is asked for the member the source named — by the more
      // direct means, and it is the ONLY encoding that reaches `Probe`'s
      // getter: `std.string_is_not_empty` would ask the runtime's polymorphic
      // emptiness predicate about an instance it knows nothing about.
      test('a delegate that DECLARES the member keeps the member (#697)', () {
        final body = bodyOf(':Wrapper.isNotEmpty');
        final called = _calledFunctions(body);
        final fields = _fieldAccessNames(body);
        expect(
          fields,
          contains('isNotEmpty'),
          reason:
              '`Probe` declares `isNotEmpty`, so the forward must read that '
              'member. Calls were: $called, fields were: $fields',
        );
        expect(
          called,
          isNot(contains('std.string_is_empty')),
          reason: '#674: never the negation. Calls were: $called',
        );
        expect(
          called,
          isNot(contains('std.string_is_not_empty')),
          reason:
              '#697: a user-declared member must not be answered by the '
              'built-in predicate. Calls were: $called',
        );
      });

      test('the same holds for isEmpty on a declaring delegate (#697)', () {
        final body = bodyOf(':Wrapper.isEmpty');
        final called = _calledFunctions(body);
        final fields = _fieldAccessNames(body);
        expect(fields, contains('isEmpty'), reason: 'calls were: $called');
        expect(called, isNot(contains('std.string_is_empty')));
        expect(called, isNot(contains('std.string_is_not_empty')));
      });

      test('the compiled Dart asks for `.isNotEmpty`, not `!….isEmpty`', () {
        expect(
          compiled,
          contains('_base.isNotEmpty'),
          reason: 'compiled output was:\n$compiled',
        );
        expect(
          compiled,
          isNot(contains('!_base.isEmpty')),
          reason: 'compiled output was:\n$compiled',
        );
      });

      test('the compiled-back program behaves like the original', () {
        final original = _runDart(_sourceUnderTest, scratch, 'original');
        final roundTripped = _runDart(compiled, scratch, 'round_tripped');
        expect(
          roundTripped,
          equals(original),
          reason:
              'the delegating receiver saw a different member after the '
              'round trip — the exact Tier B failure #674 measured on '
              '`collection/lib/src/wrappers.dart`.\n'
              '--- original ---\n$original\n'
              '--- round-tripped ---\n$roundTripped\n'
              '--- compiled ---\n$compiled',
        );
        expect(
          original,
          equals('true\nisNotEmpty\ntrue\nfalse'),
          reason:
              'the probe must actually record a member; if this changes the '
              'suite is no longer measuring what it claims to.',
        );
      });
    },
  );
}
