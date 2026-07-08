/// Tests for the compiler's try/catch lowering (`_generateTry`).
///
/// Two dispatch strategies coexist:
///   - Real Dart classes — built-in exceptions AND user-defined types the
///     program declares (thus `throw`n as real instances) — emit a real
///     `on T catch (e)` clause with dotted field access (#305).
///   - Ball-tag types (a caught type that is neither a built-in nor declared in
///     the program) dispatch inside a single catch-all via the
///     `__ball_e is Map && __ball_e['__type'] == 'Tag'` discriminator, with
///     stack-trace aliasing, an untyped fallback, and a bare rethrow when only
///     tag catches are present.
///
/// The class/builtin shapes come from the Dart encoder (a source round-trip is
/// the most faithful driver); the Ball-tag shapes never arise from the encoder
/// for a declared type, so they are built as Ball IR directly.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

String _flat(String source) => DartCompiler(
  DartEncoder().encode(source),
  noFormat: true,
).compile().replaceAll(RegExp(r'\s+'), ' ');

// ── Ball-IR builders (for the Ball-tag dispatch path) ──────────────
Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);
Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);
FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;
Expression _msg(List<FieldValuePair> fields) =>
    Expression()
      ..messageCreation = (MessageCreation()
        ..typeName = ''
        ..fields.addAll(fields));
Expression _stdCall(String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = fn
        ..input = _msg(fields));
Statement _exprStmt(Expression e) => Statement()..expression = e;
Expression _block(List<Statement> stmts) =>
    Expression()..block = (Block()..statements.addAll(stmts));
Expression _list(List<Expression> elems) =>
    Expression()
      ..literal = (Literal()
        ..listValue = (ListLiteral()..elements.addAll(elems)));
Expression _print(Expression v) => _stdCall('print', [_field('value', v)]);
Expression _throwTag(String tag) => _stdCall('throw', [
  _field('value', _msg([_field('__type', _strLit(tag))])),
]);

/// Compile [helperBody] as the body of a standalone `helper()` function — the
/// production statement-generation path (`_generateFunctionBody`), which the
/// narrower entry-`main` builder does not exercise.
String _flatHelper(Expression helperBody) {
  final helper = FunctionDefinition()
    ..name = 'helper'
    ..body = helperBody;
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = _print(_strLit('m'));
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in const ['print', 'throw', 'rethrow', 'try', 'to_string'])
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  final program = Program()
    ..name = 'try_catch_emission_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([helper, mainFn]),
    ]);
  return DartCompiler(
    program,
    noFormat: true,
  ).compile().replaceAll(RegExp(r'\s+'), ' ');
}

void main() {
  group('real-class catch (`on T catch`)', () {
    test('user-declared type with stack trace + untyped fallback', () {
      final out = _flat('''
class MyError {}
void main() {
  try {
    throw MyError();
  } on MyError catch (e, st) {
    print(e.toString());
    print(st.toString());
  } catch (e2, st2) {
    print(e2.toString());
    print(st2.toString());
  }
}
''');
      // The declared class catches as a real `on T catch` clause binding its
      // own stack param — NOT the Ball `__type` map probe (#305).
      expect(out, contains('on MyError catch (e, st)'));
      expect(out, isNot(contains('__type')));
      // The untyped fallback is the sole tag-map catch-all.
      expect(out, contains('catch (__ball_e, __ball_st)'));
      expect(out, contains('final dynamic e2 = __ball_e;'));
      expect(out, contains('final st2 = __ball_st;'));
    });

    test('user-declared type only ⇒ no catch-all, exceptions propagate', () {
      final out = _flat('''
class MyError {}
void main() {
  try {
    throw MyError();
  } on MyError catch (e) {
    print(e.toString());
  }
}
''');
      expect(out, contains('on MyError catch (e)'));
      // No tag/untyped catch-all ⇒ unmatched exceptions propagate naturally.
      expect(out, isNot(contains('__type')));
      expect(out, isNot(contains('rethrow')));
    });

    test('builtin Dart exception keeps a real `on T catch` clause', () {
      final out = _flat('''
void main() {
  try {
    throw FormatException('x');
  } on FormatException catch (e) {
    print(e.toString());
  }
}
''');
      expect(out, contains('on FormatException catch (e)'));
    });
  });

  group('tag-catch dispatch (undeclared Ball-tag type)', () {
    test('tag catch with stack trace + untyped fallback with stack', () {
      // try { throw {__type: 'BallTag'}; }
      //   on BallTag catch (e, st) { print(e); }
      //   catch (e2, st2) { print(e2); }
      final tryCall = _stdCall('try', [
        _field('body', _block([_exprStmt(_throwTag('BallTag'))])),
        _field(
          'catches',
          _list([
            _msg([
              _field('type', _strLit('BallTag')),
              _field('variable', _strLit('e')),
              _field('stack_trace', _strLit('st')),
              _field('body', _block([_exprStmt(_print(_ref('e')))])),
            ]),
            _msg([
              _field('variable', _strLit('e2')),
              _field('stack_trace', _strLit('st2')),
              _field('body', _block([_exprStmt(_print(_ref('e2')))])),
            ]),
          ]),
        ),
      ]);
      final out = _flatHelper(_block([_exprStmt(tryCall)]));
      // A single catch-all binds the catch-level stack name.
      expect(out, contains('catch (__ball_e, __ball_st)'));
      // Tag dispatch on the Ball `__type` discriminator.
      expect(
        out,
        contains("__ball_e is Map && __ball_e['__type'] == 'BallTag'"),
      );
      // Per-branch stack aliases for both the tag and untyped catches.
      expect(out, contains('final st = __ball_st;'));
      expect(out, contains('final st2 = __ball_st;'));
      // Untyped fallback after the tag branch.
      expect(out, contains('else {'));
      expect(out, contains('final dynamic e2 = __ball_e;'));
    });

    test('tag catch only (no untyped) rethrows unmatched exceptions', () {
      final tryCall = _stdCall('try', [
        _field('body', _block([_exprStmt(_throwTag('BallTag'))])),
        _field(
          'catches',
          _list([
            _msg([
              _field('type', _strLit('BallTag')),
              _field('variable', _strLit('e')),
              _field('body', _block([_exprStmt(_print(_ref('e')))])),
            ]),
          ]),
        ),
      ]);
      final out = _flatHelper(_block([_exprStmt(tryCall)]));
      expect(out, contains("__ball_e['__type'] == 'BallTag'"));
      // No untyped fallback ⇒ rethrow so other exceptions propagate.
      expect(out, contains('else { rethrow; }'));
    });
  });
}
