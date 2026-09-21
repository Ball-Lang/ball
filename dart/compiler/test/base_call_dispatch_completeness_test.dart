/// Compiler-side base-function dispatch completeness — a CLOSED SET over the
/// std builders (#488 → #647 → #654).
///
/// `check_encoder_completeness.dart` audits the ENCODER — every base function
/// the encoder can emit must be executed by a fixture. Nothing audited the
/// other end: a base function the Dart COMPILER has no `case` for used to fall
/// to `_ => '/* unsupported: std_collections.${call.function} */'`, which emits
/// a COMMENT where an expression belongs. `collection/lib/src/wrappers.dart`
/// measured exactly that:
///
///     bool containsValue(Object? input) {
///       Object? value = input;
///       return /* unsupported: std_collections.map_contains_value */;
///     }
///     ERROR|BODY_MIGHT_COMPLETE_NORMALLY|wrappers.dart|584|8
///
/// PR #647 added this gate over the ENCODER-EMITTABLE population only, and
/// issue #654 enumerated what that deliberately left out: the base functions
/// the `dart/shared/lib/std*.dart` builders DECLARE but the Dart encoder cannot
/// produce — reachable from hand-authored Ball IR and from a program encoded
/// from any other language, and invisible to every other gate. FOURTEEN of them
/// had no case when #654 was re-measured on `origin/main` after #663 landed the
/// `std_concurrency` routing: `std.int_to_double`, `std.double_to_int`,
/// `std.string_interpolation` and eleven `std_collections` names.
///
/// The fourteenth, `std_collections.set_create`, is the one #654's own count
/// missed and the reason this gate COMPILES rather than greps: the name is
/// present in `compiler.dart` — in the `std` switch, because the Dart encoder
/// emits every std call under the module name `std`
/// (`DartEncoder._moduleForFunction` answers `'std'` unconditionally) — so a
/// source scan sees it as handled while `std_collections.set_create`, the
/// spelling its own declaration implies, reached the default arm.
///
/// This gate is therefore scoped to the DECLARED set, with **no exclusion**,
/// which is what #654 asks for. Two things make it a real closed set rather
/// than a source-text scan:
///
///  * the population is built IN PROCESS from the eight `buildStd*Module()`
///    builders — the source of truth `dart/shared/std.json`,
///    `tests/conformance/std_coverage.json` and
///    `dart/shared/test/std_routed_declarations_test.dart` are all derived
///    from — so a `_fn(...)` added there joins this gate with no test edit;
///  * each name is probed by COMPILING a call to it, not by matching switch-arm
///    patterns in `compiler.dart`. An unimplemented name now reaches the shared
///    fail-loud default arm (`_unimplementedBaseCall`), whose message this file
///    matches on; before the #654 fix it left the `/* unsupported: … */`
///    marker. Either outcome fails, so the gate is meaningful on both sides of
///    that change.
///
/// `ball_proto` is the one base module NOT in the population, because it has no
/// switch to be complete: `_compileBallProtoCall` lowers EVERY name to
/// `<receiver>.<name>()`, so its dispatch is closed by construction. Adding a
/// declaration there needs no compiler change, and a test over it would assert
/// nothing.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/std.dart' show buildStdModule;
import 'package:ball_base/std_collections.dart' show buildStdCollectionsModule;
import 'package:ball_base/std_concurrency.dart' show buildStdConcurrencyModule;
import 'package:ball_base/std_convert.dart' show buildStdConvertModule;
import 'package:ball_base/std_fs.dart' show buildStdFsModule;
import 'package:ball_base/std_io.dart' show buildStdIoModule;
import 'package:ball_base/std_memory.dart' show buildStdMemoryModule;
import 'package:ball_base/std_time.dart' show buildStdTimeModule;
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

/// The substring `DartCompiler._unimplementedBaseCall` puts in its message.
/// Single-sourced there; matched here.
const String _loudDefaultArm = 'is not implemented by the Dart compiler';

/// The eight universal std modules, built from the canonical builders.
List<Module> _declaredModules() => <Module>[
  buildStdModule(),
  buildStdCollectionsModule(),
  buildStdIoModule(),
  buildStdMemoryModule(),
  buildStdConcurrencyModule(),
  buildStdConvertModule(),
  buildStdFsModule(),
  buildStdTimeModule(),
];

Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);

Expression _int(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));

Expression _str(String s) =>
    Expression()..literal = (Literal()..stringValue = s);

Expression _list(List<Expression> elements) =>
    Expression()
      ..literal = (Literal()
        ..listValue = (ListLiteral()..elements.addAll(elements)));

FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

/// A program whose `main` is exactly one base call to [module].[function].
Program _probeProgram(
  String module,
  String function,
  List<FieldValuePair> fields,
) {
  final call = FunctionCall()
    ..module = module
    ..function = function
    ..input = (Expression()
      ..messageCreation = (MessageCreation()
        ..typeName = ''
        ..fields.addAll(fields)));
  return Program()
    ..name = 'base_call_dispatch_probe'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      Module()
        ..name = module
        ..functions.add(
          FunctionDefinition()
            ..name = function
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
}

String _compileProbe(
  String module,
  String function,
  List<FieldValuePair> fields,
) => DartCompiler(
  _probeProgram(module, function, fields),
  noFormat: true,
).compile();

/// Every field of [function]'s DECLARED input type, bound to a reference named
/// after the field itself.
///
/// The declared type is looked up in the same builder module, so the probe
/// hands each arm exactly the operands its declaration promises — an arm that
/// dereferences a field the type does not declare fails on that null check
/// (a `TypeError`), which is NOT the outcome this gate reports.
List<FieldValuePair> _declaredInput(Module module, FunctionDefinition fn) {
  for (final td in module.typeDefs) {
    if (td.descriptor.name != fn.inputType) continue;
    return [for (final f in td.descriptor.field) _field(f.name, _ref(f.name))];
  }
  return const <FieldValuePair>[];
}

/// `null` when [function] is dispatched; otherwise the way it is NOT.
String? _undispatchedReason(Module module, FunctionDefinition fn) {
  try {
    final out = _compileProbe(module.name, fn.name, _declaredInput(module, fn));
    if (out.contains('/* unsupported: ${module.name}.${fn.name}')) {
      return 'emits the `/* unsupported: … */` COMMENT placeholder';
    }
    return null;
  } on StateError catch (e) {
    if (e.message.contains(_loudDefaultArm)) {
      return 'reaches the fail-loud default arm';
    }
    // Any other StateError comes from an arm that EXISTS and disliked this
    // synthetic input (a missing optional operand, say) — dispatched.
    return null;
    // A TypeError (`f['x']!` on an operand the declared type does not carry)
    // likewise means the arm exists.
  } catch (_) {
    return null;
  }
}

/// Runs the real `dart analyze` over [source] in a scratch package and returns
/// the ERROR lines. The compiled program is only a proof if it is VALID Dart —
/// a helper preamble with a typo would otherwise pass every `contains` check.
Future<List<String>> _analyze(String source) async {
  final dir = Directory.systemTemp.createTempSync('ball_dispatch_analyze');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: dispatch_probe\n'
    'environment:\n'
    "  sdk: '^3.9.0'\n",
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
  group('the dispatch is a closed set over the std builders (#654)', () {
    test('every DECLARED base function has a compiler case', () {
      final modules = _declaredModules();
      var population = 0;
      final undispatched = <String>[];
      for (final module in modules) {
        for (final fn in module.functions) {
          if (!fn.isBase) continue;
          population++;
          final reason = _undispatchedReason(module, fn);
          if (reason != null) {
            undispatched.add('${module.name}.${fn.name} — $reason');
          }
        }
      }

      // Positive floor: 306 base functions are declared today. A builder that
      // stops returning functions would otherwise make this gate pass while
      // checking nothing.
      expect(
        population,
        greaterThanOrEqualTo(300),
        reason:
            'only $population declared base functions were found — the '
            'builders changed shape and this gate would pass vacuously.',
      );

      expect(
        undispatched,
        isEmpty,
        reason:
            'these base functions are DECLARED by dart/shared/lib/std*.dart '
            'but the Dart compiler has no lowering for them, so a program '
            'that calls one (hand-authored Ball IR, or a program encoded from '
            'another language) cannot be compiled:\n'
            '${undispatched.join('\n')}',
      );
    });

    test('an UNDECLARED name in every base module fails loud', () {
      // The other half of "closed set": a name outside the declared set must
      // stop the compile, never yield a comment spliced where an expression
      // belongs. Before #654 six of these eight modules returned a marker.
      final modules = _declaredModules().map((m) => m.name).toList();
      expect(modules.length, 8, reason: 'the base-module set changed shape');
      for (final module in modules) {
        expect(
          () =>
              _compileProbe(module, 'definitely_not_a_base_function', const []),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains(_loudDefaultArm),
                contains('$module.definitely_not_a_base_function'),
              ),
            ),
          ),
          reason: '$module must fail loud on an undeclared function name',
        );
      }
    });
  });

  group('the fourteen lowerings #654 added', () {
    test('std.int_to_double / std.double_to_int reuse the numeric casts', () {
      expect(
        _compileProbe('std', 'int_to_double', [_field('value', _ref('n'))]),
        contains('n.toDouble()'),
      );
      expect(
        _compileProbe('std', 'double_to_int', [_field('value', _ref('x'))]),
        contains('x.toInt()'),
      );
    });

    test('std.string_interpolation concatenates stringified parts', () {
      final out = _compileProbe('std', 'string_interpolation', [
        _field('parts', _list([_str('a='), _ref('n')])),
      ]);
      expect(out, contains("('a=').toString() + (n).toString()"));
    });

    test('std.string_interpolation with an EMPTY parts list is `\'\'`', () {
      expect(
        _compileProbe('std', 'string_interpolation', [
          _field('parts', _list(const [])),
        ]),
        contains("''"),
      );
    });

    test(
      'std.string_interpolation keeps a NON-literal parts list portable',
      () {
        // The TypeScript compiler answers `''` here — a silently EMPTY string
        // where the program asked for its parts. This target keeps the meaning.
        final out = _compileProbe('std', 'string_interpolation', [
          _field('parts', _ref('parts')),
        ]);
        expect(out, contains(r"parts.map((e) => '$e').join()"));
      },
    );

    test('std.string_interpolation falls back to the single value', () {
      expect(
        _compileProbe('std', 'string_interpolation', [
          _field('value', _ref('v')),
        ]),
        contains('(v).toString()'),
      );
    });

    test('std.string_interpolation with nothing to interpolate fails loud', () {
      // `_probeProgram` always supplies a MessageCreation input, so reaching
      // the "no parts, no value, no input" arm needs an input-less call.
      final call = FunctionCall()
        ..module = 'std'
        ..function = 'string_interpolation';
      final program = Program()
        ..name = 'interp_no_input'
        ..version = '1.0.0'
        ..entryModule = 'main'
        ..entryFunction = 'main'
        ..modules.addAll([
          Module()
            ..name = 'std'
            ..functions.add(
              FunctionDefinition()
                ..name = 'string_interpolation'
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
      expect(
        () => DartCompiler(program, noFormat: true).compile(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('nothing to interpolate'),
          ),
        ),
      );
    });

    test('list_single is `.single` — the declared throw contract', () {
      final out = _compileProbe('std_collections', 'list_single', [
        _field('list', _ref('xs')),
      ]);
      expect(out, contains('xs.single'));
      // NOT `.isEmpty ? null : .first`: an empty or over-long list must throw
      // the same StateError the reference engine raises.
      expect(out, isNot(contains('isEmpty')));
    });

    test('list_none negates `any`', () {
      expect(
        _compileProbe('std_collections', 'list_none', [
          _field('list', _ref('xs')),
          _field('callback', _ref('cb')),
        ]),
        contains('(!xs.any(cb))'),
      );
    });

    test('list_take / list_drop materialize under both count spellings', () {
      expect(
        _compileProbe('std_collections', 'list_take', [
          _field('list', _ref('xs')),
          _field('value', _int(2)),
        ]),
        contains('xs.take(2).toList()'),
      );
      expect(
        _compileProbe('std_collections', 'list_drop', [
          _field('list', _ref('xs')),
          _field('index', _int(3)),
        ]),
        contains('xs.skip(3).toList()'),
      );
    });

    test('list_sort_by / list_zip route to their helpers', () {
      final sortBy = _compileProbe('std_collections', 'list_sort_by', [
        _field('list', _ref('xs')),
        _field('callback', _ref('key')),
      ]);
      expect(sortBy, contains('_ballListSortBy(xs, key)'));
      expect(sortBy, contains('List<Object?> _ballListSortBy('));

      final zip = _compileProbe('std_collections', 'list_zip', [
        _field('list', _ref('xs')),
        _field('value', _ref('ys')),
      ]);
      expect(zip, contains('_ballListZip(xs, ys)'));
      expect(zip, contains('List<Object?> _ballListZip('));
    });

    test('the four map lowerings route to their helpers', () {
      final cases = <String, String>{
        'map_from_entries': '_ballMapFromEntries(',
        'map_merge': '_ballMapMerge(',
        'map_map': '_ballMapMap(',
        'map_filter': '_ballMapFilter(',
      };
      cases.forEach((fn, fragment) {
        final out = _compileProbe('std_collections', fn, [
          _field('list', _ref('es')),
          _field('map', _ref('m')),
          _field('value', _ref('other')),
          _field('callback', _ref('cb')),
        ]);
        expect(out, contains(fragment), reason: 'compiled output was:\n$out');
      });
    });

    test('set_create is dispatched under its DECLARED module too', () {
      // Same lowering as the `std` spelling the Dart encoder emits; what
      // differs is only which module's switch has to carry it.
      for (final module in const ['std', 'std_collections']) {
        expect(
          _compileProbe(module, 'set_create', [
            _field('elements', _list([_int(1), _int(2)])),
          ]),
          contains('{1, 2}'),
          reason: '$module.set_create must lower to a set literal',
        );
      }
    });

    test('a helper is emitted ONLY when the program declares its function', () {
      // An unused private top-level function is an analyzer warning in the
      // compiled output, so the preamble is per-declaration, not per-module.
      final out = _compileProbe('std_collections', 'list_length', [
        _field('list', _ref('xs')),
      ]);
      expect(out, isNot(contains('_ballMapMerge')));
      expect(out, isNot(contains('_ballListSortBy')));
    });
  });

  group('map_contains_value — the #488 row PR #647 closed', () {
    test('compiles to Map.containsValue', () {
      final out = _compileProbe('std_collections', 'map_contains_value', [
        _field('map', _ref('m')),
        _field('value', _int(2)),
      ]);
      expect(out, contains('m.containsValue(2)'));
      expect(out, isNot(contains('unsupported:')));
    });
  });

  group(
    'the emitted helpers are valid Dart',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      test(
        'the analyze harness reports a real error (negative control)',
        () async {
          // A gate that cannot fail proves nothing: if `dart analyze` were
          // unresolvable or its output shape changed, the clean-analyze test
          // below would pass vacuously.
          final errors = await _analyze('int f() => notAThing;');
          expect(
            errors,
            isNotEmpty,
            reason:
                'the `dart analyze` harness did not report an undefined '
                'identifier, so it cannot see a broken helper either.',
          );
        },
      );

      test('a program using every #654 helper analyzes clean', () async {
        // One program that declares all six helper-backed functions, so the
        // whole preamble is emitted and analyzed together.
        final helpers = <String>[
          'list_sort_by',
          'list_zip',
          'map_from_entries',
          'map_merge',
          'map_map',
          'map_filter',
        ];
        final statements = <Statement>[
          for (final fn in helpers)
            Statement()
              ..expression = (Expression()
                ..call = (FunctionCall()
                  ..module = 'std_collections'
                  ..function = fn
                  ..input = (Expression()
                    ..messageCreation = (MessageCreation()
                      ..typeName = ''
                      ..fields.addAll([
                        _field('list', _ref('xs')),
                        _field('map', _ref('m')),
                        _field('value', _ref('other')),
                        _field('callback', _ref('cb')),
                      ]))))),
        ];
        final program = Program()
          ..name = 'collections_helpers_analyze'
          ..version = '1.0.0'
          ..entryModule = 'main'
          ..entryFunction = 'main'
          ..modules.addAll([
            Module()
              ..name = 'std_collections'
              ..functions.addAll([
                for (final fn in helpers)
                  FunctionDefinition()
                    ..name = fn
                    ..isBase = true,
              ]),
            Module()
              ..name = 'main'
              ..functions.add(
                FunctionDefinition()
                  ..name = 'main'
                  ..body = (Expression()
                    ..block = (Block()..statements.addAll(statements))),
              ),
          ]);

        final source = DartCompiler(program).compile();
        for (final helper in const [
          '_ballListSortBy',
          '_ballListZip',
          '_ballMapFromEntries',
          '_ballMapMerge',
          '_ballMapMap',
          '_ballMapFilter',
        ]) {
          expect(source, contains(helper));
        }

        // The probe's own `xs`/`m`/`other`/`cb` are undefined identifiers, so
        // analyze the PREAMBLE alone: everything above the entry point.
        final marker = '// Ball std_collections runtime helpers (#654)';
        expect(source, contains(marker));
        final preamble = source.substring(source.indexOf(marker));
        final body = preamble.substring(0, preamble.indexOf('void main('));
        final errors = await _analyze(body);
        expect(
          errors,
          isEmpty,
          reason: 'the emitted helpers do not analyze:\n$body',
        );
      });
    },
  );
}
