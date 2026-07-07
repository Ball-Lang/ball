import 'dart:async';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Regression test for #246: two nameless functions (lambdas) in one module
/// must NOT share a `_paramCache` entry.
///
/// The engine keys its parameter cache by `"$module.$funcName"`. A lambda's
/// `name` is always the empty string, so every lambda in a module collapses to
/// the single key `"$module."`. Before the fix, the second lambda's parameter
/// list clobbered the first's in the cache, and a later call that resolved to
/// the FIRST lambda's `FunctionDefinition` (via the module-unqualified linear
/// scan, which returns the first name match) read the SECOND lambda's params —
/// binding the argument to the wrong name and leaving the body's own parameter
/// reference unbound ("Undefined variable").
Future<List<String>> _runAndCapture(Program program) async {
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add);
  await engine.run();
  return lines;
}

Map<String, dynamic> _stdModule() => {
  'name': 'std',
  'functions': [
    {'name': 'print', 'isBase': true},
  ],
};

/// A lambda-shaped module function: empty `name`, a non-empty `inputType`
/// (so the cache-consulting param-extraction path in `_callFunction` runs),
/// a single typed parameter [param], and a body that prints that parameter.
Map<String, dynamic> _lambda(String param) => {
  'name': '',
  'inputType': 'LambdaArg',
  'metadata': {
    'kind': 'function',
    'params': [
      {'name': param, 'type': 'String'},
    ],
  },
  'body': {
    'call': {
      'module': 'std',
      'function': 'print',
      'input': {
        'messageCreation': {
          'typeName': 'PrintInput',
          'fields': [
            {
              'name': 'message',
              'value': {
                'reference': {'name': param},
              },
            },
          ],
        },
      },
    },
  },
};

/// Builds a program whose `lib` module holds two nameless lambdas — the first
/// binds parameter [firstParam], the second binds [secondParam] — and whose
/// `main` invokes the FIRST lambda through an unqualified call (which resolves
/// via the linear scan to the first name match) passing a positional `arg0`.
Program _twoLambdaProgram({
  required String firstParam,
  required String secondParam,
  required String argValue,
}) {
  final programJson = {
    'name': 'lambda_paramcache',
    'version': '1.0.0',
    'modules': [
      _stdModule(),
      {
        'name': 'lib',
        'functions': [_lambda(firstParam), _lambda(secondParam)],
      },
      {
        'name': 'main',
        'functions': [
          {
            'name': 'main',
            'body': {
              'call': {
                // Unqualified: misses `_functions["main."]`, hits the linear
                // scan, which returns the FIRST nameless function (lib's first
                // lambda binding [firstParam]).
                'function': '',
                'input': {
                  'messageCreation': {
                    'typeName': 'LambdaArg',
                    'fields': [
                      {
                        'name': 'arg0',
                        'value': {
                          'literal': {'stringValue': argValue},
                        },
                      },
                    ],
                  },
                },
              },
            },
          },
        ],
      },
    ],
    'entryModule': 'main',
    'entryFunction': 'main',
  };

  return Program()..mergeFromProto3Json(programJson);
}

void main() {
  group('engine: lambda paramCache collision (#246)', () {
    test(
      'two nameless lambdas in one module do not share cached params',
      () async {
        // The invoked (first) lambda binds parameter 'a'; the sibling binds 'b'.
        // Pre-fix, the sibling's ['b'] params clobbered the cache and the call
        // threw `Undefined variable: "a"`. Post-fix, the first lambda's own
        // params ['a'] are used and its body prints the argument.
        final program = _twoLambdaProgram(
          firstParam: 'a',
          secondParam: 'b',
          argValue: 'HELLO',
        );
        expect(await _runAndCapture(program), ['HELLO']);
      },
    );

    test(
      'parameter names stay independent regardless of sibling order',
      () async {
        // Same shape with different, longer parameter names to guard against any
        // accidental positional coupling between the two cache entries.
        final program = _twoLambdaProgram(
          firstParam: 'first',
          secondParam: 'second',
          argValue: 'WORLD',
        );
        expect(await _runAndCapture(program), ['WORLD']);
      },
    );
  });
}
