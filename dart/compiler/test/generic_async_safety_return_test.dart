/// `_asyncSafetyReturn` must not throw for a BARE TYPE-PARAMETER async result
/// that is instantiated with a nullable type argument (issue #766).
///
/// `DartCompiler._asyncSafetyReturn` picks the synthetic statement that closes
/// an `async`, non-generator, non-`void` body: `return null;` for a result that
/// accepts `null`, and a `Never`-typed `throw StateError(...)` otherwise (#488,
/// PR #647). The "otherwise" arm decided nullability SYNTACTICALLY, and a lone
/// type-variable name — the declared result of `Future<T> maybe<T>() async`
/// — is neither `dynamic` nor `?`-suffixed, so it landed in the throwing arm.
///
/// That is only sound while `T` is instantiated with a NON-nullable type. At
/// `maybe<int?>()` the declared result is `Future<int?>`, falling off the end
/// of a Ball body really does produce `null`, and the pre-#647 line
/// (`return null as dynamic;`) returned exactly that. #647 turned the same
/// program into an unconditional `StateError` — a behaviour change the
/// surrounding doc comment described as an unreachable-by-construction
/// cleanup.
///
/// Why nothing caught it: no `tests/conformance/` fixture declares a generic
/// async function whose result is a bare type parameter AND instantiates it
/// with a nullable type argument AND lets the Ball body fall through, and
/// `dart/compiler/test/` pinned `_asyncSafetyReturn` only for CONCRETE
/// declared results (`strict_casts_safety_return_test.dart` covers `int` and
/// `int?`). Neither the corpus-wide conformance run nor the Tier B per-file
/// measurement runs that shape, so both stayed green. This suite is that
/// missing instrument, and it measures BEHAVIOUR — it runs the compiled Dart
/// and reads its stdout — rather than pattern-matching the emitted source.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

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

/// The marker the generic body prints before falling off its end. Its presence
/// in stdout is this suite's positive floor: it proves the compiled program
/// actually ran and reached the synthetic trailing statement, so an empty or
/// missing stdout can never be read as a pass.
const _enterMarker = 'entered-generic-body';

/// A program with one generic `async` function whose declared result is the
/// bare type parameter `T` and whose body falls off the end, plus a `main`
/// that prints `maybe<[typeArg]>()`.
Program _program(TypeRef typeArg) {
  final maybe = FunctionDefinition()
    ..name = 'maybe'
    ..outputType = 'T'
    ..body = (Expression()
      ..block = (Block()
        ..statements.add(
          Statement()
            ..expression = _stdCall('print', [
              _field('message', _strLit(_enterMarker)),
            ]),
        )));
  maybe.mergeFromProto3Json({
    'metadata': {
      'is_async': true,
      'type_params': ['T'],
    },
  });

  final call = FunctionCall()
    ..module = 'main'
    ..function = 'maybe'
    ..input = _msg([]);
  call.typeArgs.add(typeArg);

  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = _stdCall('print', [_field('message', Expression()..call = call)]);

  final std = Module()
    ..name = 'std'
    ..functions.add(
      FunctionDefinition()
        ..name = 'print'
        ..isBase = true,
    );

  return Program()
    ..name = 'generic_async_safety_return_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([maybe, mainFn]),
    ]);
}

/// A non-generic control: a CONCRETE non-nullable async result, whose synthetic
/// trailing statement must stay the `Never`-typed throw (#488 / #647).
Program _concreteProgram() {
  final alwaysReturns = FunctionDefinition()
    ..name = 'alwaysReturns'
    ..outputType = 'int'
    ..body = (Expression()
      ..block = (Block()
        ..result = (Expression()..literal = (Literal()..intValue = Int64(1)))));
  alwaysReturns.mergeFromProto3Json({
    'metadata': {'is_async': true, 'has_return': true},
  });

  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = _stdCall('print', [_field('message', _strLit('m'))]);

  final std = Module()
    ..name = 'std'
    ..functions.add(
      FunctionDefinition()
        ..name = 'print'
        ..isBase = true,
    );

  return Program()
    ..name = 'generic_async_safety_return_concrete'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      std,
      Module()
        ..name = 'main'
        ..functions.addAll([alwaysReturns, mainFn]),
    ]);
}

/// The outcome of running one compiled Dart program.
typedef _RunResult = ({int exitCode, String stdout, String stderr});

/// Writes [source] into a scratch package whose `analysis_options.yaml` turns
/// `strict-casts` on, then returns that package directory.
Directory _scratchPackage(String source) {
  final dir = Directory.systemTemp.createTempSync('ball_generic_async');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: generic_async_probe\n'
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
  return dir;
}

/// Runs the compiled [source] with the real Dart VM and returns its outcome.
Future<_RunResult> _run(String source) async {
  final dir = _scratchPackage(source);
  final proc = await Process.run(
    'dart',
    ['run', '${dir.path}/bin/subject.dart'],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return (
    exitCode: proc.exitCode,
    stdout: proc.stdout as String,
    stderr: proc.stderr as String,
  );
}

/// Runs the real `dart analyze` (strict-casts on) over [source] and returns the
/// ERROR lines.
Future<List<String>> _analyzeStrict(String source) async {
  final dir = _scratchPackage(source);
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
    'bare type-parameter async safety return (#766)',
    timeout: const Timeout(Duration(minutes: 5)),
    () {
      test(
        'the runner observes a program that throws (instrument control)',
        () async {
          final result = await _run('''
void main() {
  print('$_enterMarker');
  throw StateError('deliberate');
}
''');
          expect(
            result.stdout,
            contains(_enterMarker),
            reason:
                'the probe runner produced no stdout for a program that '
                'definitely prints, so it did not run and its readings below '
                'prove nothing.',
          );
          expect(
            result.exitCode,
            isNot(0),
            reason:
                'the probe runner reported success for a program that throws, '
                'so it cannot tell a returning program from a throwing one.',
          );
          expect(
            result.stderr,
            contains('Bad state: deliberate'),
            reason:
                'the probe runner did not surface the thrown error text, so a '
                'reading of stderr below could not distinguish one failure '
                'from another.',
          );
        },
      );

      test(
        'Future<T> instantiated with a nullable T returns null, not a throw',
        () async {
          final source = DartCompiler(
            _program(
              TypeRef()
                ..name = 'int'
                ..nullable = true,
            ),
          ).compile();
          final result = await _run(source);

          expect(
            result.stdout,
            contains(_enterMarker),
            reason:
                'the compiled program never reached the generic body, so this '
                'measurement says nothing about the synthetic trailing '
                'statement. Compiled source was:\n$source',
          );
          expect(
            result.exitCode,
            0,
            reason:
                'falling off the end of a Ball body whose declared result is '
                '`Future<int?>` completes with null — it must not throw. '
                'stderr was:\n${result.stderr}\n\nCompiled source was:\n'
                '$source',
          );
          expect(
            const LineSplitter().convert(result.stdout.trim()).last.trim(),
            'null',
            reason:
                'expected the nullable instantiation to complete with null, '
                'matching the pre-#647 `return null as dynamic;` behaviour. '
                'stdout was:\n${result.stdout}\n\nCompiled source was:\n'
                '$source',
          );
        },
      );

      test(
        'Future<T> instantiated with a non-nullable T still fails loud',
        () async {
          final source = DartCompiler(
            _program(TypeRef()..name = 'int'),
          ).compile();
          final result = await _run(source);

          expect(
            result.stdout,
            contains(_enterMarker),
            reason:
                'the compiled program never reached the generic body. '
                'Compiled source was:\n$source',
          );
          expect(
            result.exitCode,
            isNot(0),
            reason:
                '`null` is not a value of `Future<int>`; the synthetic '
                'trailing statement must still fail loud rather than hand a '
                'caller a null it cannot hold. stdout was:\n${result.stdout}\n'
                '\nCompiled source was:\n$source',
          );
          expect(
            result.stderr,
            contains('unreachable: Ball async body already returned'),
            reason:
                'expected the #647 loud failure for a non-nullable '
                'instantiation; stderr was:\n${result.stderr}',
          );
        },
      );

      test('a concrete non-nullable async result keeps the loud throw', () {
        final source = DartCompiler(_concreteProgram()).compile();
        expect(
          source,
          contains(
            "throw StateError('unreachable: Ball async body already "
            "returned')",
          ),
          reason:
              'the #488 / #647 shape for a CONCRETE non-nullable result must '
              'not regress. Compiled source was:\n$source',
        );
        expect(
          source,
          isNot(contains('return null as dynamic;')),
          reason:
              '`dynamic` is not implicitly assignable to `int` under '
              'strict-casts. Compiled source was:\n$source',
        );
      });

      test(
        'the generic compiled output passes `dart analyze --strict-casts`',
        () async {
          final source = DartCompiler(
            _program(
              TypeRef()
                ..name = 'int'
                ..nullable = true,
            ),
          ).compile();
          final errors = await _analyzeStrict(source);
          expect(
            errors,
            isEmpty,
            reason:
                'dart analyze (strict-casts: true) rejected the compiled '
                'Dart:\n${errors.join('\n')}\n\nCompiled source was:\n$source',
          );
        },
      );
    },
  );
}
