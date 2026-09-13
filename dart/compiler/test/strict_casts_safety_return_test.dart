/// The `async` safety return must type-check under `strict-casts` (#488,
/// `async/lib/src/stream_queue.dart` + `async/lib/src/async_cache.dart`).
///
/// Every `async`, non-generator, non-`void` function got an unconditional
/// trailing `return null as dynamic;` so Dart's flow analysis would accept a
/// body whose Ball IR already returns (or throws) on every path. Under
/// `analyzer: language: strict-casts: true` — a common dart-lang-team setting,
/// and exactly what `dart-lang/async`'s own `analysis_options.yaml` sets —
/// `dynamic` is NOT implicitly assignable to a non-dynamic type, and
/// unreachable code is still type-checked. So the safety line itself was the
/// error:
///
///     ERROR|RETURN_OF_INVALID_TYPE|stream_queue.dart|128|
///       A value of type 'dynamic' can't be returned from the method
///       'withTransaction' because it has a return type of 'Future<bool>'.
///
/// No other gate in this repository runs `dart analyze` under ANY non-default
/// analysis options — not Tier A, not Tier B (both compile and RUN, never
/// lint), not the conformance/round-trip legs — so this shape was structurally
/// invisible. This suite is that missing instrument.
///
/// The fix must keep the two shapes apart:
///   * a NULLABLE declared result (`Future<int?>`, `Future<dynamic>`) — `null`
///     is a legitimate value there, and a body that falls off the end really
///     does produce it, so the safety line must stay a `return null;`;
///   * a NON-NULLABLE declared result (`Future<bool>`, `Future<T>`) — `null`
///     could never be returned from it (today's line throws a `TypeError` if
///     it is ever reached), so the line exists purely to satisfy flow
///     analysis and is spelled as a `Never`-typed `throw`.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));
Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);

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

/// One module with [functions] plus a trivial `main`.
Program _program(List<FunctionDefinition> functions) {
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = _stdCall('print', [_field('message', _strLit('m'))]);
  final std = Module()
    ..name = 'std'
    ..functions.addAll([
      for (final f in const ['print', 'throw'])
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  return Program()
    ..name = 'strict_casts_safety_return_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([...functions, mainFn]),
    ]);
}

FunctionDefinition _asyncFn(
  String name,
  String outputType,
  Expression body, {
  bool hasResult = true,
}) {
  final fn = FunctionDefinition()
    ..name = name
    ..outputType = outputType
    ..body = body;
  fn.mergeFromProto3Json({
    'metadata': {'is_async': true, if (hasResult) 'has_return': true},
  });
  return fn;
}

/// A body that always produces a value (the `stream_queue.dart` shape: the
/// trailing safety line is dead code the analyzer still type-checks).
Expression _alwaysReturns() =>
    Expression()..block = (Block()..result = _intLit(1));

/// A body that never returns (the fall-off-the-end shape: the safety line is
/// the ONLY way out, so a nullable result must still yield `null`).
Expression _neverReturns() => Expression()
  ..block = (Block()
    ..statements.add(
      Statement()
        ..expression = _stdCall('print', [_field('message', _strLit('x'))]),
    ));

String _compile(List<FunctionDefinition> functions) =>
    DartCompiler(_program(functions)).compile();

/// Runs the real `dart analyze` over [source] in a scratch package whose
/// `analysis_options.yaml` turns `strict-casts` on, and returns the ERROR
/// lines.
Future<List<String>> _analyzeStrict(String source) async {
  final dir = Directory.systemTemp.createTempSync('ball_strict_casts');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: strict_casts_probe\n'
    'environment:\n'
    "  sdk: '^3.9.0'\n",
  );
  File('${dir.path}/analysis_options.yaml').writeAsStringSync(
    'analyzer:\n'
    '  language:\n'
    '    strict-casts: true\n',
  );
  Directory('${dir.path}/bin').createSync();
  File('${dir.path}/bin/subject.dart').writeAsStringSync(source);

  final analyze = await Process.run(
    'dart',
    ['analyze', '--format=machine', dir.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return const LineSplitter()
      .convert('${analyze.stdout}\n${analyze.stderr}')
      .where((l) => l.startsWith('ERROR|'))
      .toList();
}

void main() {
  group(
    'async safety return under strict-casts (#488)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      test('a non-nullable async result never emits `null as dynamic`', () {
        final out = _compile([
          _asyncFn('alwaysReturns', 'int', _alwaysReturns()),
        ]);
        expect(
          out,
          isNot(contains('return null as dynamic;')),
          reason:
              '`dynamic` is not implicitly assignable to `int` under '
              'strict-casts, even in code flow analysis proved unreachable. '
              'Compiled output was:\n$out',
        );
      });

      test('a nullable async result still returns null, not a throw', () {
        final out = _compile([
          _asyncFn('mayFallThrough', 'int?', _neverReturns(), hasResult: false),
        ]);
        expect(
          out,
          contains('return null;'),
          reason:
              'a `Future<int?>` function that falls off the end really does '
              'complete with null — replacing that with a throw would be a '
              'behaviour regression, not a fix. Compiled output was:\n$out',
        );
      });

      // Negative control for the INSTRUMENT. The next test asserts that
      // strict-casts analysis of the compiled output is SILENT, and
      // silence cannot tell "the analyzer found nothing" from "the
      // analyzer never ran": a `dart` that is not on PATH, a change to
      // `--format=machine`, or a scratch package the analyzer declines to
      // load would each leave `errors` empty and pass it vacuously. This
      // feeds `_analyzeStrict` the exact PRE-FIX line and REQUIRES the
      // diagnostic back, so the gate is proven to bite before its silence
      // is read as a pass.
      test(
        '_analyzeStrict rejects the pre-fix `null as dynamic` line',
        () async {
          final errors = await _analyzeStrict('''
Future<int> preFix() async {
  return null as dynamic;
}

void main() {
  preFix();
}
''');
          expect(
            errors,
            isNotEmpty,
            reason:
                'strict-casts analysis produced NO error for the very line '
                'this suite exists to keep out, so it did not run and its '
                'silence on the compiled output proves nothing.',
          );
          expect(
            errors.join('\n'),
            contains('RETURN_OF_INVALID_TYPE'),
            reason:
                'expected the strict-casts return-type diagnostic; got:\n'
                '${errors.join('\n')}',
          );
        },
      );

      test(
        'compiled async output passes `dart analyze --strict-casts`',
        () async {
          final out = _compile([
            _asyncFn('alwaysReturns', 'int', _alwaysReturns()),
            _asyncFn(
              'mayFallThrough',
              'int?',
              _neverReturns(),
              hasResult: false,
            ),
          ]);
          final errors = await _analyzeStrict(out);
          expect(
            errors,
            isEmpty,
            reason:
                'dart analyze (strict-casts: true) rejected the compiled Dart:\n'
                '${errors.join('\n')}\n\nCompiled source was:\n$out',
          );
        },
      );
    },
  );
}
