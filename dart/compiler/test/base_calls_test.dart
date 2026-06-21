/// Unit tests for the compiler's base-function emit cases.
///
/// These build Ball-IR [Program]s directly (no encoder round-trip) so they can
/// exercise the full `_compileBaseCall` dispatch surface — including std-module
/// functions the Dart encoder never emits but other languages (or hand-written
/// Ball) do (std_memory, std_io, std_fs, std_time, std_convert, ball_proto, and
/// the long tail of std math/string/collection ops).
///
/// Each program wraps a single base call as the body of `main`; we assert the
/// emitted Dart source contains the expected construct. This pins the exact
/// lowering for every dispatch arm.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

// ── Tiny Ball-IR builders ─────────────────────────────────────────
Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);

Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));

Expression _doubleLit(double d) =>
    Expression()..literal = (Literal()..doubleValue = d);

Expression _boolLit(bool b) =>
    Expression()..literal = (Literal()..boolValue = b);

Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);

FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

Expression _msg(String typeName, List<FieldValuePair> fields) =>
    Expression()
      ..messageCreation = (MessageCreation()
        ..typeName = typeName
        ..fields.addAll(fields));

/// A base-module call `module.fn(field=...)` with a MessageCreation input.
Expression _call(String module, String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = module
        ..function = fn
        ..input = _msg('', fields));

/// Build a single-module program whose `main` body is [expr], wiring up the
/// std-family base modules that the compiler recognizes as "base" by checking
/// every function `isBase`.
Program _program(Expression expr) {
  Module baseModule(String name, List<String> fns) => Module()
    ..name = name
    ..functions.addAll([
      for (final f in fns)
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);

  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = expr;
  final mainModule = Module()
    ..name = 'main'
    ..functions.add(mainFn);

  // Each base module needs at least one base function so the compiler marks
  // the whole module as base (see _buildLookupTables). The exact function list
  // doesn't matter for emit — dispatch is by call.function string.
  return Program()
    ..name = 'base_calls_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      baseModule('std', ['print']),
      baseModule('std_memory', ['memory_alloc']),
      baseModule('std_collections', ['list_push']),
      baseModule('std_io', ['exit']),
      baseModule('std_convert', ['json_encode']),
      baseModule('std_fs', ['file_read']),
      baseModule('std_time', ['now']),
      baseModule('ball_proto', ['whichExpr']),
      mainModule,
    ]);
}

/// Compile [expr] (as main's body) and return the emitted Dart source.
String _compile(Expression expr) =>
    DartCompiler(_program(expr), noFormat: true).compile();

/// Compile [expr] and collapse all runs of whitespace to a single space.
///
/// `noFormat: true` emits via code_builder's scoped emitter, which inserts
/// stray newlines/spaces around brackets (`'Hello'  [\n0\n]`). Collapsing
/// whitespace lets assertions match the logical shape regardless of layout.
String _compileFlat(Expression expr) =>
    _compile(expr).replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('std arithmetic / comparison / logic / bitwise', () {
    final l = _intLit(7), r = _intLit(3);
    final cases = <String, ({String fn, String contains})>{
      'add': (fn: 'add', contains: '7 + 3'),
      'subtract': (fn: 'subtract', contains: '7 - 3'),
      'multiply': (fn: 'multiply', contains: '7 * 3'),
      'divide': (fn: 'divide', contains: '7 ~/ 3'),
      'divide_double': (fn: 'divide_double', contains: '7 / 3'),
      'modulo': (fn: 'modulo', contains: '7 % 3'),
      'equals': (fn: 'equals', contains: '7 == 3'),
      'not_equals': (fn: 'not_equals', contains: '7 != 3'),
      'less_than': (fn: 'less_than', contains: '7 < 3'),
      'greater_than': (fn: 'greater_than', contains: '7 > 3'),
      'lte': (fn: 'lte', contains: '7 <= 3'),
      'gte': (fn: 'gte', contains: '7 >= 3'),
      'bitwise_and': (fn: 'bitwise_and', contains: '7 & 3'),
      'bitwise_or': (fn: 'bitwise_or', contains: '7 | 3'),
      'bitwise_xor': (fn: 'bitwise_xor', contains: '7 ^ 3'),
      'left_shift': (fn: 'left_shift', contains: '7 << 3'),
      'right_shift': (fn: 'right_shift', contains: '7 >> 3'),
      'unsigned_right_shift': (fn: 'unsigned_right_shift', contains: '7 >>> 3'),
      'concat': (fn: 'concat', contains: '7 + 3'),
      'null_coalesce': (fn: 'null_coalesce', contains: '7 ?? 3'),
    };
    cases.forEach((label, spec) {
      test(label, () {
        final out = _compile(
          _call('std', spec.fn, [_field('left', l), _field('right', r)]),
        );
        expect(out, contains(spec.contains));
      });
    });

    test('and / or', () {
      final t = _boolLit(true), fl = _boolLit(false);
      expect(
        _compile(_call('std', 'and', [_field('left', t), _field('right', fl)])),
        contains('true && false'),
      );
      expect(
        _compile(_call('std', 'or', [_field('left', t), _field('right', fl)])),
        contains('true || false'),
      );
    });

    test('binOp with missing operand emits invalid marker', () {
      final out = _compile(_call('std', 'add', [_field('left', l)]));
      expect(out, contains('/* invalid + */'));
    });
  });

  group('std prefix / mutation operators', () {
    test('negate', () {
      expect(
        _compile(_call('std', 'negate', [_field('value', _intLit(5))])),
        contains('-5'),
      );
    });
    test('not', () {
      expect(
        _compile(_call('std', 'not', [_field('value', _boolLit(true))])),
        contains('!true'),
      );
    });
    test('bitwise_not', () {
      expect(
        _compile(_call('std', 'bitwise_not', [_field('value', _intLit(5))])),
        contains('~5'),
      );
    });
    test('stacked negate parenthesizes', () {
      final inner = _call('std', 'negate', [_field('value', _intLit(5))]);
      final out = _compile(_call('std', 'negate', [_field('value', inner)]));
      expect(out, contains('-(-5)'));
    });
    test('stacked not parenthesizes', () {
      final inner = _call('std', 'not', [_field('value', _boolLit(true))]);
      final out = _compile(_call('std', 'not', [_field('value', inner)]));
      expect(out, contains('!(!true)'));
    });
    test('pre_increment / pre_decrement', () {
      expect(
        _compile(_call('std', 'pre_increment', [_field('value', _ref('x'))])),
        contains('++x'),
      );
      expect(
        _compile(_call('std', 'pre_decrement', [_field('value', _ref('x'))])),
        contains('--x'),
      );
    });
    test('post_increment / post_decrement', () {
      expect(
        _compile(_call('std', 'post_increment', [_field('value', _ref('x'))])),
        contains('x++'),
      );
      expect(
        _compile(_call('std', 'post_decrement', [_field('value', _ref('x'))])),
        contains('x--'),
      );
    });
    test('null_check postfix', () {
      expect(
        _compile(_call('std', 'null_check', [_field('value', _ref('x'))])),
        contains('x!'),
      );
    });
    test('prefix op with missing value emits invalid marker', () {
      expect(_compile(_call('std', 'negate', [])), contains('/* invalid - */'));
    });
  });

  group('std string ↔ conversion', () {
    test('to_string on simple value', () {
      expect(
        _compile(_call('std', 'to_string', [_field('value', _ref('x'))])),
        contains('x.toString()'),
      );
    });
    test('to_string on Type reference uses interpolation', () {
      final out = _compile(
        _call('std', 'to_string', [_field('value', _ref('MyType'))]),
      );
      expect(out, contains(r"'$MyType'"));
    });
    test('to_string parenthesizes infix receiver', () {
      final infix = _call('std', 'add', [
        _field('left', _intLit(1)),
        _field('right', _intLit(2)),
      ]);
      final out = _compile(_call('std', 'to_string', [_field('value', infix)]));
      // The infix receiver is parenthesized so `.toString()` binds correctly.
      expect(out, contains('(1 + 2)).toString()'));
    });
    test('length property', () {
      expect(
        _compile(_call('std', 'length', [_field('value', _ref('s'))])),
        contains('s.length'),
      );
    });
    test('int_to_string / double_to_string', () {
      expect(
        _compile(_call('std', 'int_to_string', [_field('value', _intLit(5))])),
        contains('5.toString()'),
      );
      expect(
        _compile(
          _call('std', 'double_to_string', [_field('value', _doubleLit(1.5))]),
        ),
        contains('1.5.toString()'),
      );
    });
    test('string_to_int / string_to_double', () {
      expect(
        _compile(
          _call('std', 'string_to_int', [_field('value', _strLit('5'))]),
        ),
        contains("int.parse('5')"),
      );
      expect(
        _compile(
          _call('std', 'string_to_double', [_field('value', _strLit('1.5'))]),
        ),
        contains("double.parse('1.5')"),
      );
    });
  });

  group('std type ops', () {
    test('is / is_not / as', () {
      final v = _field('value', _ref('x'));
      final t = _field('type', _strLit('String'));
      expect(_compile(_call('std', 'is', [v, t])), contains('x is String'));
      expect(
        _compile(_call('std', 'is_not', [v, t])),
        contains('x is! String'),
      );
      expect(_compile(_call('std', 'as', [v, t])), contains('x as String'));
    });
    test('type op with missing value/type emits invalid marker', () {
      expect(
        _compile(_call('std', 'is', [_field('value', _ref('x'))])),
        contains('/* invalid is */'),
      );
    });
    test('symbol literal', () {
      expect(
        _compile(_call('std', 'symbol', [_field('value', _strLit('foo'))])),
        contains('#foo'),
      );
    });
    test('type_literal', () {
      expect(
        _compile(
          _call('std', 'type_literal', [_field('type', _strLit('int'))]),
        ),
        contains('int'),
      );
    });
    test('paren', () {
      expect(
        _compile(_call('std', 'paren', [_field('value', _intLit(5))])),
        contains('(5)'),
      );
    });
  });

  group('std string operations', () {
    final s = _field('value', _strLit('Hello'));
    test('string_length / string_is_empty', () {
      expect(
        _compile(_call('std', 'string_length', [s])),
        contains("'Hello'.length"),
      );
      expect(
        _compile(_call('std', 'string_is_empty', [s])),
        contains("'Hello'.isEmpty"),
      );
    });
    test('string_concat', () {
      expect(
        _compile(
          _call('std', 'string_concat', [
            _field('left', _strLit('a')),
            _field('right', _strLit('b')),
          ]),
        ),
        contains("'a' + 'b'"),
      );
    });
    test('string_contains / starts_with / ends_with', () {
      final l = _field('left', _strLit('Hello'));
      final r = _field('right', _strLit('ell'));
      expect(
        _compile(_call('std', 'string_contains', [l, r])),
        contains("'Hello'.contains('ell')"),
      );
      expect(
        _compile(_call('std', 'string_starts_with', [l, r])),
        contains("'Hello'.startsWith('ell')"),
      );
      expect(
        _compile(_call('std', 'string_ends_with', [l, r])),
        contains("'Hello'.endsWith('ell')"),
      );
    });
    test('string_index_of / last_index_of', () {
      final l = _field('left', _strLit('Hello'));
      final r = _field('right', _strLit('l'));
      expect(
        _compile(_call('std', 'string_index_of', [l, r])),
        contains("'Hello'.indexOf('l')"),
      );
      expect(
        _compile(_call('std', 'string_last_index_of', [l, r])),
        contains("'Hello'.lastIndexOf('l')"),
      );
    });
    test('string_substring with and without end', () {
      expect(
        _compile(
          _call('std', 'string_substring', [s, _field('start', _intLit(1))]),
        ),
        contains("'Hello'.substring(1)"),
      );
      expect(
        _compile(
          _call('std', 'string_substring', [
            s,
            _field('start', _intLit(1)),
            _field('end', _intLit(3)),
          ]),
        ),
        contains("'Hello'.substring(1, 3)"),
      );
    });
    test('string_char_at', () {
      expect(
        _compileFlat(
          _call('std', 'string_char_at', [
            _field('target', _strLit('Hello')),
            _field('index', _intLit(0)),
          ]),
        ),
        contains("'Hello' [ 0 ]"),
      );
    });
    test('string_char_code_at', () {
      expect(
        _compile(
          _call('std', 'string_char_code_at', [
            _field('target', _strLit('Hello')),
            _field('index', _intLit(0)),
          ]),
        ),
        contains("'Hello'.codeUnitAt(0)"),
      );
    });
    test('string_from_char_code', () {
      expect(
        _compile(
          _call('std', 'string_from_char_code', [_field('value', _intLit(65))]),
        ),
        contains('String.fromCharCode(65)'),
      );
    });
    test('case + trim family', () {
      final cases = {
        'string_to_upper': 'toUpperCase()',
        'string_to_lower': 'toLowerCase()',
        'string_trim': 'trim()',
        'string_trim_start': 'trimLeft()',
        'string_trim_end': 'trimRight()',
      };
      cases.forEach((fn, method) {
        expect(_compile(_call('std', fn, [s])), contains("'Hello'.$method"));
      });
    });
    test('string_replace / replace_all', () {
      final fields = [
        _field('value', _strLit('Hello')),
        _field('from', _strLit('l')),
        _field('to', _strLit('L')),
      ];
      expect(
        _compile(_call('std', 'string_replace', fields)),
        contains("'Hello'.replaceFirst('l', 'L')"),
      );
      expect(
        _compile(_call('std', 'string_replace_all', fields)),
        contains("'Hello'.replaceAll('l', 'L')"),
      );
    });
    test('string_split', () {
      expect(
        _compile(
          _call('std', 'string_split', [
            _field('left', _strLit('a,b')),
            _field('right', _strLit(',')),
          ]),
        ),
        contains("'a,b'.split(',')"),
      );
    });
    test('string_repeat', () {
      expect(
        _compile(
          _call('std', 'string_repeat', [
            _field('value', _strLit('ab')),
            _field('count', _intLit(3)),
          ]),
        ),
        contains("'ab' * 3"),
      );
    });
    test('string_pad_left / pad_right with and without fill', () {
      expect(
        _compile(
          _call('std', 'string_pad_left', [s, _field('width', _intLit(8))]),
        ),
        contains("'Hello'.padLeft(8)"),
      );
      expect(
        _compile(
          _call('std', 'string_pad_right', [
            s,
            _field('width', _intLit(8)),
            _field('fill', _strLit('*')),
          ]),
        ),
        contains("'Hello'.padRight(8, '*')"),
      );
    });
    test('string_join with and without separator', () {
      final list = _field('list', _ref('items'));
      expect(
        _compile(_call('std', 'string_join', [list])),
        contains('items.join()'),
      );
      expect(
        _compile(
          _call('std', 'string_join', [
            list,
            _field('separator', _strLit('-')),
          ]),
        ),
        contains("items.join('-')"),
      );
    });
    test('string_code_unit_at / compare_to / to_string_as_fixed', () {
      expect(
        _compile(
          _call('std', 'string_code_unit_at', [
            _field('left', _strLit('Hi')),
            _field('right', _intLit(0)),
          ]),
        ),
        contains("'Hi'.codeUnitAt(0)"),
      );
      expect(
        _compile(
          _call('std', 'compare_to', [
            _field('left', _intLit(1)),
            _field('right', _intLit(2)),
          ]),
        ),
        contains('1.compareTo(2)'),
      );
      expect(
        _compile(
          _call('std', 'to_string_as_fixed', [
            _field('left', _doubleLit(3.14159)),
            _field('right', _intLit(2)),
          ]),
        ),
        contains('toStringAsFixed(2)'),
      );
    });
    test('to_double / to_int', () {
      expect(
        _compile(_call('std', 'to_double', [_field('value', _intLit(5))])),
        contains('5.toDouble()'),
      );
      expect(
        _compile(_call('std', 'to_int', [_field('value', _doubleLit(5.0))])),
        contains('5.0.toInt()'),
      );
    });
  });

  group('std regex', () {
    final input = _field('left', _strLit('abc123'));
    final pattern = _field('right', _strLit(r'\d+'));
    // The pattern's backslash is escaped in the emitted Dart string literal,
    // so `\d+` becomes `\\d+` in source.
    test('regex_match', () {
      expect(
        _compile(_call('std', 'regex_match', [input, pattern])),
        contains(r"RegExp('\\d+').hasMatch('abc123')"),
      );
    });
    test('regex_find', () {
      expect(
        _compile(_call('std', 'regex_find', [input, pattern])),
        contains('firstMatch'),
      );
    });
    test('regex_find_all', () {
      final out = _compile(_call('std', 'regex_find_all', [input, pattern]));
      expect(out, contains('allMatches'));
      expect(out, contains('.map((m) => m.group(0)!).toList()'));
    });
    test('regex_replace / replace_all', () {
      final fields = [
        _field('value', _strLit('abc123')),
        _field('from', _strLit(r'\d+')),
        _field('to', _strLit('#')),
      ];
      expect(
        _compile(_call('std', 'regex_replace', fields)),
        contains(r"replaceFirst(RegExp('\\d+'), '#')"),
      );
      expect(
        _compile(_call('std', 'regex_replace_all', fields)),
        contains(r"replaceAll(RegExp('\\d+'), '#')"),
      );
    });
  });

  group('std math', () {
    final v = _field('value', _doubleLit(2.0));
    test('unary math methods', () {
      final cases = {
        'math_abs': 'abs()',
        'math_floor': 'floor()',
        'math_ceil': 'ceil()',
        'math_round': 'round()',
        'math_trunc': 'truncate()',
      };
      cases.forEach((fn, method) {
        expect(_compile(_call('std', fn, [v])), contains('.$method'));
      });
    });
    test('math functions sqrt/log/exp/trig', () {
      for (final fn in [
        'math_sqrt',
        'math_log',
        'math_exp',
        'math_sin',
        'math_cos',
        'math_tan',
        'math_asin',
        'math_acos',
        'math_atan',
      ]) {
        final out = _compile(_call('std', fn, [v]));
        final name = fn.substring('math_'.length);
        expect(out, contains('$name('));
      }
    });
    test('math_log2 / math_log10', () {
      expect(_compile(_call('std', 'math_log2', [v])), contains('/ ln2'));
      expect(_compile(_call('std', 'math_log10', [v])), contains('/ ln10'));
    });
    test('math binary pow/atan2/min/max', () {
      final fields = [
        _field('left', _doubleLit(2.0)),
        _field('right', _doubleLit(3.0)),
      ];
      expect(_compile(_call('std', 'math_pow', fields)), contains('pow('));
      expect(_compile(_call('std', 'math_atan2', fields)), contains('atan2('));
      expect(_compile(_call('std', 'math_min', fields)), contains('min('));
      expect(_compile(_call('std', 'math_max', fields)), contains('max('));
    });
    test('math constants', () {
      expect(_compile(_call('std', 'math_pi', [])), contains('pi'));
      expect(_compile(_call('std', 'math_e', [])), contains(' e'));
      expect(
        _compile(_call('std', 'math_infinity', [])),
        contains('double.infinity'),
      );
      expect(_compile(_call('std', 'math_nan', [])), contains('double.nan'));
    });
    test('math is-predicates and sign', () {
      expect(_compile(_call('std', 'math_is_nan', [v])), contains('.isNaN'));
      expect(
        _compile(_call('std', 'math_is_finite', [v])),
        contains('.isFinite'),
      );
      expect(
        _compile(_call('std', 'math_is_infinite', [v])),
        contains('.isInfinite'),
      );
      expect(_compile(_call('std', 'math_sign', [v])), contains('.sign'));
    });
    test('math_gcd / math_lcm', () {
      final fields = [_field('left', _intLit(12)), _field('right', _intLit(8))];
      expect(_compile(_call('std', 'math_gcd', fields)), contains('.gcd('));
      final lcm = _compile(_call('std', 'math_lcm', fields));
      expect(lcm, contains('.abs() ~/'));
      expect(lcm, contains('.gcd('));
    });
    test('math_clamp 2-arg and 3-arg', () {
      expect(
        _compile(
          _call('std', 'math_clamp', [
            _field('value', _intLit(15)),
            _field('min', _intLit(0)),
            _field('max', _intLit(10)),
          ]),
        ),
        contains('15.clamp(0, 10)'),
      );
      expect(
        _compile(
          _call('std', 'math_clamp', [
            _field('value', _ref('MathUtils')),
            _field('min', _intLit(15)),
            _field('max', _intLit(0)),
            _field('arg2', _intLit(10)),
          ]),
        ),
        contains('MathUtils.clamp(15, 0, 10)'),
      );
    });
  });

  group('std dart-specific + datetime accessors', () {
    test('list_generate / list_filled', () {
      expect(
        _compile(
          _call('std', 'list_generate', [
            _field('count', _intLit(3)),
            _field('generator', _ref('gen')),
          ]),
        ),
        contains('List.generate(3, gen)'),
      );
      expect(
        _compile(
          _call('std', 'list_filled', [
            _field('count', _intLit(3)),
            _field('value', _intLit(0)),
          ]),
        ),
        contains('List.filled(3, 0)'),
      );
    });
    test('datetime component accessors', () {
      for (final comp in [
        'year',
        'month',
        'day',
        'hour',
        'minute',
        'second',
        'millisecond',
        'weekday',
      ]) {
        expect(
          _compile(_call('std', comp, [_field('value', _ref('dt'))])),
          contains('dt.$comp'),
        );
      }
    });
    test('unsupported std function emits marker', () {
      expect(
        _compile(_call('std', 'totally_unknown_fn', [])),
        contains('/* unsupported: std.totally_unknown_fn */'),
      );
    });
  });
}
