/// Compiler-side base-function dispatch completeness (#488,
/// `collection/lib/src/wrappers.dart`).
///
/// `check_encoder_completeness.dart` audits the ENCODER — every base function
/// the encoder can emit must be executed by a fixture. Nothing audited the
/// other end: a base function the encoder happily emits but the DART COMPILER
/// has no `case` for falls to
/// `_ => '/* unsupported: std_collections.${call.function} */'`, which emits a
/// COMMENT where an expression belongs. `collection/lib/src/wrappers.dart`
/// measured exactly that:
///
///     bool containsValue(Object? input) {
///       Object? value = input;
///       return /* unsupported: std_collections.map_contains_value */;
///     }
///     ERROR|BODY_MIGHT_COMPLETE_NORMALLY|wrappers.dart|584|8
///
/// `std_collections.map_contains_value` is declared
/// (`dart/shared/lib/std_collections.dart`), encoder-routed (`collectionRoutes`
/// `'containsValue'`), engine-implemented (`dart/engine/lib/engine_std.dart`)
/// and implemented by every OTHER compiler (TS, Rust, C#, Go, Python, C++) —
/// the Dart compiler was the only one missing it, silently.
///
/// The gate below is scoped to the ENCODER-EMITTABLE population
/// (`encoderEmittable: true` in the generated
/// `tests/conformance/std_coverage.json`): those are precisely the names a real
/// Dart source file can make the pipeline produce, so a missing case there is a
/// reachable defect rather than an unused declaration. Declared-but-unroutable
/// names (`list_zip`, the whole `std_concurrency` module, …) are a different,
/// pre-existing gap and are deliberately NOT in this population — see the
/// issue #654, which enumerates all 20 of them and the three ways out.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

/// Walks up from the test's CWD (`dart/compiler`) to the repository root.
Directory _repoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/ball.schema.json').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('repository root not found from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir;
}

/// Every switch-arm pattern in the compiler's base-call dispatch, i.e. every
/// base-function name it actually handles. The dispatch is a chain of
/// `switch (call.function) { 'name' => …, 'a' || 'b' => …, }` expressions
/// spread over one per-module method each.
Set<String> _dispatchedNames(String compilerSource) {
  final out = <String>{};
  for (final m in RegExp(
    r"'([a-z][a-z0-9_]*)'\s*(?:=>|\|\|)",
  ).allMatches(compilerSource)) {
    out.add(m.group(1)!);
  }
  for (final m in RegExp(
    r"\|\|\s*'([a-z][a-z0-9_]*)'",
  ).allMatches(compilerSource)) {
    out.add(m.group(1)!);
  }
  for (final m in RegExp(
    r"case\s+'([a-z][a-z0-9_]*)'",
  ).allMatches(compilerSource)) {
    out.add(m.group(1)!);
  }
  return out;
}

void main() {
  test('every encoder-emittable base function has a compiler case', () {
    final root = _repoRoot();
    final inventory = File('${root.path}/tests/conformance/std_coverage.json');
    expect(
      inventory.existsSync(),
      isTrue,
      reason:
          'the generated std inventory is missing; regenerate with '
          '`cd dart/encoder && dart run bin/gen_std_coverage.dart`.',
    );
    final decoded =
        jsonDecode(inventory.readAsStringSync()) as Map<String, dynamic>;
    final rows = (decoded['functions'] as List).cast<Map<String, dynamic>>();
    final emittable = rows.where((r) => r['encoderEmittable'] == true).toList();
    expect(
      emittable.length,
      greaterThan(50),
      reason:
          'the emittable population collapsed — the inventory shape changed '
          'and this gate would pass vacuously.',
    );

    final source = File(
      '${root.path}/dart/compiler/lib/compiler.dart',
    ).readAsStringSync();
    final dispatched = _dispatchedNames(source);

    final missing = <String>[
      for (final row in emittable)
        if (!dispatched.contains(row['name'] as String))
          '${row['module']}.${row['name']}',
    ]..sort();

    expect(
      missing,
      isEmpty,
      reason:
          'these base functions can be emitted by the Dart encoder but have '
          'no case in the Dart compiler, so they compile to a '
          '`/* unsupported: … */` COMMENT instead of an expression:\n'
          '${missing.join('\n')}',
    );
  });

  test('map_contains_value compiles to Map.containsValue', () {
    final call = FunctionCall()
      ..module = 'std_collections'
      ..function = 'map_contains_value'
      ..input = (Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = ''
          ..fields.addAll([
            FieldValuePair()
              ..name = 'map'
              ..value = (Expression()..reference = (Reference()..name = 'm')),
            FieldValuePair()
              ..name = 'value'
              ..value = (Expression()
                ..literal = (Literal()..intValue = Int64(2))),
          ])));

    final program = Program()
      ..name = 'map_contains_value_probe'
      ..version = '1.0.0'
      ..entryModule = 'main'
      ..entryFunction = 'main'
      ..modules.addAll([
        Module()
          ..name = 'std_collections'
          ..functions.add(
            FunctionDefinition()
              ..name = 'map_contains_value'
              ..isBase = true,
          ),
        Module()
          ..name = 'main'
          ..functions.add(
            FunctionDefinition()
              ..name = 'main'
              ..body = (Expression()..call = call),
          ),
      ]);

    final out = DartCompiler(program, noFormat: true).compile();
    expect(
      out,
      contains('m.containsValue(2)'),
      reason: 'compiled output was:\n$out',
    );
    expect(out, isNot(contains('unsupported:')));
  });
}
