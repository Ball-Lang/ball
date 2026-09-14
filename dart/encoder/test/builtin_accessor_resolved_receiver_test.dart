/// The RESOLVED half of #697's receiver seam.
///
/// `builtin_accessor_user_member_test.dart` covers the SYNTACTIC proof — the
/// one `encode(String)` has, where the receiver's declared type name must be a
/// class this same unit declares. That proof is deliberately unit-local, so it
/// cannot see a member declared in another FILE, which is the ordinary shape in
/// a real package.
///
/// `PackageEncoder.prepareStaticTypes()` is the opt-in seam that supplies a
/// type-resolved AST (issue #488), and with it the encoder asks the analyzer
/// instead: does `isEmpty` resolve, on this receiver's static type, to a
/// declaration outside the SDK? This suite exercises exactly that path — the
/// subject file declares no class at all, so a pass here can only come from
/// resolution — plus its control, a `dart:core` `String` receiver whose route
/// must survive.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

const _holderSource = '''
class Holder {
  int isEmpty;
  Holder(this.isEmpty);
}
''';

/// The subject declares NO type, so the syntactic proof cannot fire here.
const _subjectSource = '''
import 'holder.dart';

Object? userMember(Holder h) {
  return h.isEmpty;
}

Object? coreMember(String s) {
  return s.isEmpty;
}
''';

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

/// Whether [e] contains a `fieldAccess` naming [field].
bool readsField(Expression e, String field) {
  var found = false;
  void walk(Expression x) {
    if (found) return;
    switch (x.whichExpr()) {
      case Expression_Expr.fieldAccess:
        if (x.fieldAccess.field_2 == field) {
          found = true;
          return;
        }
        if (x.fieldAccess.hasObject()) walk(x.fieldAccess.object);
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
      case Expression_Expr.lambda:
        if (x.lambda.hasBody()) walk(x.lambda.body);
      case _:
        break;
    }
  }

  walk(e);
  return found;
}

void main() {
  // The analyzer has a multi-second cold start; raised deliberately.
  group(
    'the RESOLVED receiver proof (#697)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Program program;

      setUpAll(() async {
        pkg = _scratchPackage('builtin_accessor_resolved_probe', {
          'holder.dart': _holderSource,
          'subject.dart': _subjectSource,
        });
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
      });

      tearDownAll(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
      });

      Expression bodyOf(String fn) => program.modules
          .firstWhere((m) => m.name == 'lib.subject')
          .functions
          .firstWhere((f) => f.name == fn)
          .body;

      test('a member declared in ANOTHER file still wins', () {
        expect(
          readsField(bodyOf('userMember'), 'isEmpty'),
          isTrue,
          reason:
              '`Holder.isEmpty` lives in holder.dart, so the unit-local '
              'syntactic proof cannot see it — only resolution can, and it '
              'must.',
        );
      });

      test('a dart:core receiver KEEPS its route under resolution', () {
        expect(
          readsField(bodyOf('coreMember'), 'isEmpty'),
          isFalse,
          reason:
              '`String.isEmpty` is declared in the SDK, so the route must '
              'still fire — the seam is a refinement, not a removal.',
        );
      });
    },
  );
}
