/// Cross-language drift guard: every std function the Dart ENCODER can emit
/// must be recognized by the Dart COMPILER.
///
/// The encoder maps Dart syntax (operators, control flow, string/list/math
/// helpers) onto `std`/`std_collections`/`std_io`/etc. function names. If the
/// compiler's dispatch table drifts out of sync — e.g. the encoder starts
/// emitting `lte` for `<=` but the compiler only knows `less_than_or_equal`
/// — the round-tripped Dart silently degrades into a `/* unsupported: ... */`
/// or `/* unknown ... */` comment instead of real code, which still
/// "compiles" to a string and slips past behavioural tests.
///
/// This suite drives small Dart snippets through encoder -> compiler and
/// fails on any such leaked marker. Each snippet is chosen to make the
/// encoder emit a specific std function.
@TestOn('vm')
library;

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

/// Encode `source` and compile it back to raw (unformatted) Dart.
String _roundTrip(String source) {
  final program = DartEncoder().encode(source);
  return DartCompiler(program, noFormat: true).compile();
}

/// Markers the compiler emits when it has no handler for a function/node.
final _markerPattern = RegExp(r'/\*\s*(unsupported|unknown)\b');

void _expectNoMarkers(String source, {required String feature}) {
  final out = _roundTrip(source);
  final match = _markerPattern.firstMatch(out);
  expect(
    match,
    isNull,
    reason:
        'Compiler emitted an unsupported/unknown marker for "$feature". '
        'Encoder/compiler dispatch tables have drifted. Output near marker:\n'
        '${match == null ? '' : out.substring(match.start, (match.start + 80).clamp(0, out.length))}',
  );
}

void main() {
  group('std dispatch drift guard (encoder -> compiler)', () {
    // ── Binary operators (the lte/gte regression class) ──────────────
    const binaryOps = <String, String>{
      '+': 'add',
      '-': 'subtract',
      '*': 'multiply',
      '~/': 'divide',
      '/': 'divide_double',
      '%': 'modulo',
      '==': 'equals',
      '!=': 'not_equals',
      '<': 'less_than',
      '>': 'greater_than',
      '<=': 'lte',
      '>=': 'gte',
      '&': 'bitwise_and',
      '|': 'bitwise_or',
      '^': 'bitwise_xor',
      '<<': 'left_shift',
      '>>': 'right_shift',
      '>>>': 'unsigned_right_shift',
    };
    for (final entry in binaryOps.entries) {
      test('binary operator ${entry.key} (std.${entry.value})', () {
        _expectNoMarkers(
          'void main() { var a = 5; var b = 3; var c = a ${entry.key} b; print(c); }',
          feature: 'operator ${entry.key} -> std.${entry.value}',
        );
      });
    }

    test('logical && / ||', () {
      _expectNoMarkers(
        'void main() { var a = true; var b = false; print(a && b || a); }',
        feature: '&& and ||',
      );
    });

    test('null-coalesce ??', () {
      _expectNoMarkers(
        'void main() { int? a; var b = a ?? 0; print(b); }',
        feature: '?? -> null_coalesce',
      );
    });

    // ── Unary / prefix / postfix ──────────────────────────────────────
    test('negate, not, bitwise_not', () {
      _expectNoMarkers(
        'void main() { var a = 5; print(-a); print(!(a > 0)); print(~a); }',
        feature: 'unary operators',
      );
    });

    test('increment / decrement', () {
      _expectNoMarkers(
        'void main() { var a = 0; a++; ++a; a--; --a; print(a); }',
        feature: 'inc/dec',
      );
    });

    // ── Control flow std fns ──────────────────────────────────────────
    test('if / else', () {
      _expectNoMarkers(
        'void main() { var a = 1; if (a > 0) { print("y"); } else { print("n"); } }',
        feature: 'if/else',
      );
    });

    test('for loop', () {
      _expectNoMarkers(
        'void main() { for (var i = 0; i < 3; i++) { print(i); } }',
        feature: 'for',
      );
    });

    test('for-in loop', () {
      _expectNoMarkers(
        'void main() { for (var x in [1, 2, 3]) { print(x); } }',
        feature: 'for_in',
      );
    });

    test('while / do-while', () {
      _expectNoMarkers(
        'void main() { var i = 0; while (i < 3) { i++; } do { i--; } while (i > 0); print(i); }',
        feature: 'while/do_while',
      );
    });

    test('switch', () {
      _expectNoMarkers(
        'void main() { var a = 1; switch (a) { case 1: print("one"); break; default: print("x"); } }',
        feature: 'switch',
      );
    });

    test('try / catch / finally / throw', () {
      _expectNoMarkers(
        'void main() { try { throw "x"; } catch (e) { print(e); } finally { print("done"); } }',
        feature: 'try',
      );
    });

    // ── String / type / null ops ──────────────────────────────────────
    test('string concat and interpolation', () {
      _expectNoMarkers(
        r'void main() { var a = "x"; var b = "y"; print(a + b); print("$a-$b"); }',
        feature: 'concat / interpolation',
      );
    });

    test('is / is! / as', () {
      _expectNoMarkers(
        'void main() { Object a = 1; print(a is int); print(a is! String); print((a as int) + 1); }',
        feature: 'type ops',
      );
    });

    test('null-aware access and null-check', () {
      _expectNoMarkers(
        'void main() { String? a; print(a?.length); print((a ?? "x")!.length); }',
        feature: 'null-aware',
      );
    });

    test('ternary conditional', () {
      _expectNoMarkers(
        'void main() { var a = 1; print(a > 0 ? "pos" : "neg"); }',
        feature: 'ternary',
      );
    });

    test('await / async', () {
      _expectNoMarkers(
        'Future<void> main() async { var x = await Future.value(1); print(x); }',
        feature: 'await',
      );
    });

    // ── Collections (std_collections via method calls) ────────────────
    test('list ops: map / where / length', () {
      _expectNoMarkers(
        'void main() { var xs = [1, 2, 3]; print(xs.length); var ys = xs.where((x) => x > 1).map((x) => x * 2).toList(); print(ys); }',
        feature: 'list ops',
      );
    });

    test('spread in collection literal', () {
      _expectNoMarkers(
        'void main() { var a = [1, 2]; var b = [0, ...a, 3]; print(b); }',
        feature: 'spread',
      );
    });

    test('cascade', () {
      _expectNoMarkers(
        'void main() { var b = StringBuffer()..write("a")..write("b"); print(b.toString()); }',
        feature: 'cascade',
      );
    });
  });
}
