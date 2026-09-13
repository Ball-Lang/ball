/// Type arguments the SOURCE elided but the analyzer INFERRED must be carried
/// through `MessageCreation.metadata['type_args']` (issue #573, case 2).
///
/// `async/lib/src/stream_sink_transformer/typed.dart`:
///
/// ```dart
/// StreamSink<S> bind(StreamSink<T> sink) =>
///     StreamController(sync: true)..stream.cast<dynamic>().pipe(sink);
/// ```
///
/// `StreamController(sync: true)` writes no type argument — Dart infers `<S>`
/// from the declared return type. `_encodeInstanceCreation` only ever read
/// `namedType.typeArguments?.toSource()` (type arguments written in SOURCE
/// syntax), so the round trip emitted a bare `StreamController(sync: true)`,
/// which in the compiled-back file has no return-type context to infer from
/// and defaults to `StreamController<dynamic>`:
///
/// ```
/// A value of type 'StreamController<dynamic>' can't be returned from the
/// method 'bind' because it has a return type of 'StreamSink<S>'.
/// ```
///
/// The fix reads the already-resolved `expr.staticType` and feeds it through
/// the SAME `_setTypeArgsMetadata` / `_setTypeArgsField` pair the explicit
/// (`Map<String, String>.from(...)`) path has always used — no new metadata
/// key, no proto change, and nothing at all outside the
/// `PackageEncoder.prepareStaticTypes()`-resolved path (`encode(String)` and
/// `encodeModule` leave `staticType` null, so they are untouched).
///
/// The pre-existing generics tests only ever covered explicit source syntax,
/// which is why the "resolved but elided" branch was never exercised.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:test/test.dart';

const _sourceUnderTest = '''
import 'dart:async';

/// Mirrors `async/lib/src/stream_sink_transformer/typed.dart`.
class TypedStreamSinkTransformer<S, T> {
  StreamSink<S> bind(StreamSink<T> sink) =>
      StreamController(sync: true)..stream.cast<dynamic>().pipe(sink);
}

/// Explicit source-syntax type arguments must be untouched.
Map<String, String> copy(Map<String, String> m) => Map<String, String>.from(m);

/// Nothing useful was inferred here, so nothing must be added.
dynamic anonymous() => StreamController(sync: true);
''';

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

/// Every `MessageCreation` reachable from [e], in encounter order.
List<MessageCreation> _messageCreations(Expression e) {
  final out = <MessageCreation>[];
  void walk(Expression x) {
    switch (x.whichExpr()) {
      case Expression_Expr.messageCreation:
        out.add(x.messageCreation);
        for (final f in x.messageCreation.fields) {
          walk(f.value);
        }
      case Expression_Expr.call:
        if (x.call.hasInput()) walk(x.call.input);
      case Expression_Expr.block:
        for (final s in x.block.statements) {
          if (s.hasExpression()) walk(s.expression);
          if (s.hasLet() && s.let.hasValue()) walk(s.let.value);
        }
        if (x.block.hasResult()) walk(x.block.result);
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

/// The `<…>` source string stored in the redundant `__type_args__` field.
String? _typeArgsField(MessageCreation msg) => msg.fields
    .where((f) => f.name == '__type_args__')
    .map((f) => f.value.literal.stringValue)
    .firstOrNull;

MessageCreation _soleCreationIn(Program program, String functionName) {
  final subject = program.modules.firstWhere((m) => m.name == 'lib.subject');
  FunctionDefinition? found;
  for (final f in subject.functions) {
    if (f.name == functionName || f.name.endsWith('.$functionName')) {
      found = f;
    }
  }
  expect(
    found,
    isNotNull,
    reason:
        'no function named $functionName among '
        '${subject.functions.map((f) => f.name).toList()}',
  );
  final creations = _messageCreations(found!.body);
  expect(
    creations,
    isNotEmpty,
    reason: '$functionName encoded no MessageCreation',
  );
  return creations.first;
}

void main() {
  group(
    'inferred constructor type arguments (#573 case 2)',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      late Directory pkg;
      late Program program;
      late String compiled;

      setUpAll(() async {
        pkg = _scratchPackage('inferred_type_args_probe', _sourceUnderTest);
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
        compiled = DartCompiler(program).compileModule('lib.subject');
      });

      tearDownAll(() {
        if (pkg.existsSync()) pkg.deleteSync(recursive: true);
      });

      test('the inferred <S> reaches type_args metadata', () {
        final msg = _soleCreationIn(program, 'bind');
        expect(
          msg.typeName,
          endsWith(':StreamController'),
          reason: 'unexpected creation: ${msg.typeName}',
        );
        expect(
          msg.hasMetadata() && msg.metadata.fields.containsKey('type_args'),
          isTrue,
          reason:
              'the analyzer resolved this call to StreamController<S>; the '
              'encoder must carry that through the existing type_args path. '
              'Encoded: ${msg.toProto3Json()}',
        );
        expect(_typeArgsField(msg), '<S>');
      });

      test('the compiled Dart names the type argument', () {
        expect(
          compiled,
          contains('StreamController<S>('),
          reason: 'compiled output was:\n$compiled',
        );
      });

      test('explicit source type arguments are not duplicated', () {
        final msg = _soleCreationIn(program, 'copy');
        expect(_typeArgsField(msg), '<String, String>');
        expect(compiled, contains('Map<String, String>.from('));
        expect(
          compiled,
          isNot(contains('Map<Map<')),
          reason: 'compiled output was:\n$compiled',
        );
      });

      test('an all-dynamic inference adds nothing', () {
        final msg = _soleCreationIn(program, 'anonymous');
        expect(
          _typeArgsField(msg),
          isNull,
          reason:
              '`dynamic anonymous() => StreamController(sync: true)` infers '
              'StreamController<dynamic> — annotating that is pure noise. '
              'Encoded: ${msg.toProto3Json()}',
        );
        expect(compiled, isNot(contains('StreamController<dynamic>(')));
      });

      test('the compiled Dart passes the real `dart analyze`', () async {
        final out = _scratchPackage(
          'inferred_type_args_analyze',
          'const _ = 0;\n',
        );
        addTearDown(() {
          if (out.existsSync()) out.deleteSync(recursive: true);
        });
        File('${out.path}/lib/subject.dart').writeAsStringSync(compiled);

        final analyze = await Process.run(
          'dart',
          ['analyze', '--format=machine', out.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        final errors = const LineSplitter()
            .convert('${analyze.stdout}\n${analyze.stderr}')
            .where((l) => l.startsWith('ERROR|'))
            .toList();

        expect(
          errors,
          isEmpty,
          reason:
              'dart analyze rejected the compiled-back Dart:\n'
              '${errors.join('\n')}\n\n'
              'Compiled source was:\n$compiled',
        );
      });
    },
  );
}
