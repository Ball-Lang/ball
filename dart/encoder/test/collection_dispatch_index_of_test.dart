/// `indexOf(needle, start)` must not lose its needle (issue #488).
///
/// `collectionRoutes['indexOf']` models `List.indexOf` with the arity window
/// `(1, 2)`, so a two-argument call was accepted by the route. The rename pass
/// that follows then gave BOTH arguments the same field name: `arg0` hits the
/// explicit `'list_index_of' => 'value'` case, and `arg1` — which has no
/// `list_index_of` case at all — fell through to the `_ => 'value'` default.
/// Two `FieldValuePair`s named `'value'` reached the compiler's field map and
/// the second silently overwrote the first, so `path.indexOf('\\', 2)` compiled
/// back as `path.indexOf(2)`: the needle discarded and the *start index*
/// masquerading as the pattern. Dart's own front end then rejects it —
/// `The argument type 'int' can't be assigned to the parameter type 'Pattern'`
/// — which is verbatim the failure issue #488 recorded for
/// `path/lib/src/style/windows.dart` and `path/lib/src/style/url.dart` (the
/// issue's table filed both under "contains"; they are `indexOf` calls).
///
/// This is a PURE FIELD-NAMING defect: it needs no receiver type at all, so
/// unlike its `collection_dispatch_receiver_type_test.dart` siblings this suite
/// runs against the resolution-free `encode(String)` API and is fast.
///
/// The fix narrows the route's arity window to `(1, 1)` — the shape
/// `std_collections.list_index_of` can actually model, since neither the
/// function's declared input nor any engine implements a start offset — and
/// lets the two-argument form fall through to the generic method-call encoding,
/// which re-emits the source's own call verbatim. That is the same
/// decline-rather-than-mis-model rule the arity gate (#494/#510) and the
/// receiver-type gate (#488 slice 1) already apply.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

const _source = '''
int listTwoArg(List<int> xs) {
  return xs.indexOf(3, 1);
}

int listOneArg(List<int> xs) {
  return xs.indexOf(3);
}

int stringTwoArg(String s) {
  return s.indexOf('b', 2);
}

int stringOneArg(String s) {
  return s.indexOf('b');
}
''';

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
  group('two-argument indexOf keeps both arguments (#488)', () {
    late Program program;
    late String compiled;

    setUpAll(() {
      program = DartEncoder().encode(_source, name: 'main');
      compiled = DartCompiler(program).compileModule('main');
    });

    Expression bodyOf(String name) => program.modules
        .firstWhere((m) => m.name == 'main')
        .functions
        .firstWhere((f) => f.name == name)
        .body;

    test('the needle survives a List receiver', () {
      expect(
        compiled,
        contains('xs.indexOf(3, 1)'),
        reason:
            'both arguments must reach the compiled Dart; the pre-fix output '
            'was `xs.indexOf(1)` — the start index in the needle position. '
            'Compiled output was:\n$compiled',
      );
    });

    test('the needle survives a String receiver', () {
      expect(
        compiled,
        contains("s.indexOf('b', 2)"),
        reason:
            'the pre-fix output was `s.indexOf(2)`, which Dart rejects with '
            "\"The argument type 'int' can't be assigned to the parameter "
            'type \'Pattern\'" — verbatim the #488 failure for '
            'path/lib/src/style/windows.dart. Compiled output was:\n$compiled',
      );
    });

    test('the two-argument form declines the list_index_of route', () {
      expect(
        _calledFunctions(bodyOf('listTwoArg')),
        isNot(contains('std_collections.list_index_of')),
        reason:
            'std_collections.list_index_of declares no start-offset operand '
            'and no engine implements one, so routing a two-argument indexOf '
            'into it can only drop an argument.',
      );
      expect(
        _calledFunctions(bodyOf('stringTwoArg')),
        isNot(contains('std_collections.list_index_of')),
      );
    });

    test('the one-argument form still routes to list_index_of', () {
      expect(
        _calledFunctions(bodyOf('listOneArg')),
        contains('std_collections.list_index_of'),
        reason:
            'the fix narrows the arity window; it must not stop routing the '
            'shape the std function does model.',
      );
      expect(
        _calledFunctions(bodyOf('stringOneArg')),
        contains('std_collections.list_index_of'),
      );
      expect(compiled, contains('xs.indexOf(3)'));
      expect(compiled, contains("s.indexOf('b')"));
    });
  });
}
