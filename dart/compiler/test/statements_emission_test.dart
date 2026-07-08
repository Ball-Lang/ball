/// Unit tests for the compiler's function-body statement generation: the
/// `notSet` statement, scope/destructure block-as-statement, the async
/// throw-only safety `return null as dynamic;`, the `throw null;` statement, a
/// standalone `label` statement (and an unsupported control statement), a
/// for-loop whose loop var is captured by a body lambda (per-iteration
/// binding), and goto/label appearing as a block's *result* (the branch the
/// existing goto/label tests don't reach).
///
/// These build Ball IR directly because the Dart encoder never emits goto/label
/// and only emits the malformed/edge shapes through specific source.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);
Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));
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
Statement _letStmt(String name, Expression value) =>
    Statement()
      ..let = (LetBinding()
        ..name = name
        ..value = value);

Expression _block(List<Statement> statements, {Expression? result}) {
  final b = Block()..statements.addAll(statements);
  if (result != null) b.result = result;
  return Expression()..block = b;
}

/// Build a single-module program with a standalone function `helper`
/// (carrying [body] / [outputType] / [metadata]) plus a trivial `main`. The
/// standalone function routes through `_buildMethodFromMeta` →
/// `_generateFunctionBody`, the production statement-generation path (the entry
/// `main` uses a separate, narrower builder).
Program _program(
  Expression body, {
  String outputType = '',
  Map<String, Object?>? metadata,
}) {
  final helper = FunctionDefinition()
    ..name = 'helper'
    ..body = body;
  if (outputType.isNotEmpty) helper.outputType = outputType;
  if (metadata != null) helper.mergeFromProto3Json({'metadata': metadata});
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = (Expression()
      ..call = (FunctionCall()
        ..module = 'std'
        ..function = 'print'
        ..input = _msg([_field('value', _strLit('m'))])));
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in const [
        'print',
        'label',
        'goto',
        'throw',
        'rethrow',
        'for',
        'lambda',
        'assert',
        'yield',
        'yield_each',
      ])
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  return Program()
    ..name = 'statements_emission_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([helper, mainFn]),
    ]);
}

String _compile(
  Expression body, {
  String outputType = '',
  Map<String, Object?>? metadata,
}) => DartCompiler(
  _program(body, outputType: outputType, metadata: metadata),
  noFormat: true,
).compile();

String _flat(
  Expression body, {
  String outputType = '',
  Map<String, Object?>? metadata,
}) => _compile(
  body,
  outputType: outputType,
  metadata: metadata,
).replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('block-as-statement forms', () {
    test('plain inner scope block is wrapped in braces', () {
      final inner = _block([
        _letStmt('y', _intLit(20)),
        _exprStmt(_stdCall('print', [_field('message', _ref('y'))])),
      ]);
      // A block statement (no result) nested as a statement of the body.
      final body = _block([_exprStmt(inner)]);
      final out = _flat(body);
      expect(out, contains('final y = 20'));
      // Inner scope braces emitted.
      expect(out, contains('{ final y = 20;'));
    });

    test('pattern-destructure block (__ball_rec_) is inlined, not braced', () {
      final inner = _block([
        _letStmt('__ball_rec_0', _intLit(1)),
        _letStmt('a', _ref('__ball_rec_0')),
      ]);
      final body = _block([
        _exprStmt(inner),
        _exprStmt(_stdCall('print', [_field('message', _ref('a'))])),
      ]);
      final out = _flat(body);
      expect(out, contains('final __ball_rec_0 = 1'));
      expect(out, contains('final a = __ball_rec_0'));
    });

    test('notSet statement is skipped (no output)', () {
      // A Statement with no oneof set must be ignored, not crash.
      final body = _block([
        Statement(),
        _exprStmt(_stdCall('print', [_field('message', _strLit('ok'))])),
      ]);
      final out = _flat(body);
      expect(out, contains("print('ok')"));
    });
  });

  group('throw statements', () {
    test('throw with no value emits `throw null;`', () {
      final body = _block([_exprStmt(_stdCall('throw', const []))]);
      final out = _flat(body);
      expect(out, contains('throw null;'));
    });
  });

  group('async safety return', () {
    test('async non-void throw-only body gets `return null as dynamic;`', () {
      // Body just throws — no return — so a safety return is appended.
      final body = _block([
        _exprStmt(_stdCall('throw', [_field('value', _ref('e'))])),
      ]);
      final out = _flat(body, outputType: 'int', metadata: {'is_async': true});
      expect(out, contains('return null as dynamic;'));
    });
  });

  group('standalone label / unsupported statement', () {
    test('a lone label statement emits its own switch-case', () {
      // A single label among non-label statements: _generateGotoSwitchBlock
      // groups labels, but a label as the only-result still emits a case.
      final body = _block(
        [
          _exprStmt(_stdCall('print', [_field('message', _strLit('a'))])),
        ],
        result: _stdCall('label', [
          _field('name', _strLit('done')),
          _field('body', _stdCall('print', [_field('message', _strLit('b'))])),
        ]),
      );
      final out = _flat(body);
      expect(out, contains('switch (0)'));
      expect(out, contains('done:'));
    });

    test('goto as block result emits a labelled continue', () {
      final body = _block([
        _exprStmt(
          _stdCall('label', [
            _field('name', _strLit('top')),
            _field(
              'body',
              _stdCall('print', [_field('message', _strLit('x'))]),
            ),
          ]),
        ),
      ], result: _stdCall('goto', [_field('label', _strLit('top'))]));
      final out = _flat(body);
      expect(out, contains('continue top;'));
    });

    test('yield / yield_each statements in a generator body', () {
      // yield / yield* statement forms (the _generateStdStatement arms).
      final body = _block([
        _exprStmt(_stdCall('yield', [_field('value', _intLit(1))])),
        _exprStmt(_stdCall('yield_each', [_field('value', _ref('xs'))])),
      ]);
      final out = _flat(body, metadata: {'is_sync_star': true});
      expect(out, contains('yield 1;'));
      expect(out, contains('yield* xs;'));
    });
  });

  group('for-loop loop var captured by a body lambda', () {
    test('loop var captured by a lambda stays in the for-init clause', () {
      // for (var i = 0; i < n; i = i + 1) { final f = () => i; }
      final initBlock = _block([_letStmt('i', _intLit(0))]);
      // A lambda body that references `i` (captures the loop variable).
      final lambda = Expression()
        ..lambda = (FunctionDefinition()
          ..name = '_l'
          ..body = (Expression()
            ..fieldAccess = (FieldAccess()
              ..object = _ref('i')
              ..field_2 = 'isEven')));
      final forBody = _block([_letStmt('f', lambda)]);
      final forCall = _stdCall('for', [
        _field('init', initBlock),
        _field('condition', _ref('cond')),
        _field('update', _ref('upd')),
        _field('body', forBody),
      ]);
      final body = _block([_exprStmt(forCall)]);
      final out = _flat(body);
      // The declaration must stay INSIDE the for header so Dart gives each
      // iteration a fresh binding — a captured closure snapshots that
      // iteration's value, not the shared final value (#303).
      expect(out, contains('for (var i = 0; cond; upd)'));
      expect(out, isNot(contains('for (; cond; upd)')));
    });
  });

  group('local function (lambda assigned to let)', () {
    test('async non-void local fn gets `return null as dynamic;`', () {
      // final f = () async { throw e; };  → safety return appended.
      final lambdaFn = FunctionDefinition()
        ..name = '_f'
        ..outputType = 'int';
      lambdaFn.mergeFromProto3Json({
        'metadata': {'is_async': true},
      });
      lambdaFn.body = _block([
        _exprStmt(_stdCall('throw', [_field('value', _ref('e'))])),
      ]);
      final body = _block([_letStmt('f', Expression()..lambda = lambdaFn)]);
      final out = _flat(body);
      expect(out, contains('return null as dynamic;'));
    });

    test('sync* local fn emits sync* and uses yield', () {
      final lambdaFn = FunctionDefinition()
        ..name = '_g'
        ..outputType = 'List<int>';
      lambdaFn.mergeFromProto3Json({
        'metadata': {'is_sync_star': true},
      });
      lambdaFn.body = _block([
        _exprStmt(_stdCall('yield', [_field('value', _intLit(1))])),
      ]);
      final body = _block([_letStmt('g', Expression()..lambda = lambdaFn)]);
      final out = _flat(body);
      expect(out, contains('sync*'));
      expect(out, contains('yield 1;'));
    });
  });
}
