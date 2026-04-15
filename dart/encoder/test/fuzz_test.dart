/// Lightweight encoder fuzz: generate small pseudo-random Dart programs
/// from a narrow grammar, run them through `DartEncoder(strict: true)`,
/// and assert no crash and no silent drop.
///
/// This is NOT a full property-based fuzzer — the grammar is fixed and
/// covers a small surface (arithmetic + variables + print + if). It's
/// here to catch crashes on pathological combinations of constructs
/// that the hand-written fixtures don't cover.
///
/// Deterministic seed: every run produces the same sequence, so any
/// failure reproduces exactly.
@TestOn('vm')
library;

import 'dart:math';

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Tiny arithmetic grammar: integer constant, variable ref, binary op.
String _genExpr(Random rng, List<String> vars, int depth) {
  if (depth <= 0) {
    if (vars.isNotEmpty && rng.nextBool()) {
      return vars[rng.nextInt(vars.length)];
    }
    return rng.nextInt(100).toString();
  }
  final choice = rng.nextInt(4);
  if (choice == 0) return rng.nextInt(100).toString();
  if (choice == 1 && vars.isNotEmpty) {
    return vars[rng.nextInt(vars.length)];
  }
  const ops = ['+', '-', '*'];
  final op = ops[rng.nextInt(ops.length)];
  final left = _genExpr(rng, vars, depth - 1);
  final right = _genExpr(rng, vars, depth - 1);
  return '($left $op $right)';
}

String _genStatement(Random rng, List<String> vars, int depth) {
  final choice = rng.nextInt(3);
  if (choice == 0) {
    // print an expression
    final e = _genExpr(rng, vars, depth);
    return 'print(($e).toString());';
  }
  if (choice == 1 && vars.isNotEmpty) {
    // assign to an existing variable
    final v = vars[rng.nextInt(vars.length)];
    final e = _genExpr(rng, vars, depth);
    return '$v = $e;';
  }
  // if statement with no-op body
  final cond = '(${_genExpr(rng, vars, depth)}) > 0';
  final inner = _genExpr(rng, vars, depth - 1);
  return 'if ($cond) { print(($inner).toString()); }';
}

String _genProgram(int seed) {
  final rng = Random(seed);
  final buf = StringBuffer('void main() {\n');
  // Declare 2-4 variables
  final varCount = 2 + rng.nextInt(3);
  final vars = <String>[];
  for (var i = 0; i < varCount; i++) {
    final name = 'v$i';
    vars.add(name);
    buf.writeln('  var $name = ${rng.nextInt(50)};');
  }
  // 1-5 statements
  final stmtCount = 1 + rng.nextInt(5);
  for (var i = 0; i < stmtCount; i++) {
    buf.writeln('  ${_genStatement(rng, vars, 2)}');
  }
  buf.writeln('}');
  return buf.toString();
}

void main() {
  group('encoder fuzz: strict mode must not crash', () {
    // 50 seeds is plenty to exercise the grammar's surface. Each seed
    // runs in <50ms so the whole sweep fits under 2.5s.
    for (var seed = 0; seed < 50; seed++) {
      test('seed $seed', () {
        final source = _genProgram(seed);
        // Strict mode: any silent-drop path throws.
        late final program = DartEncoder(strict: true).encode(source);
        expect(
          () => program.modules,
          returnsNormally,
          reason: 'encoder crashed on:\n$source',
        );
        expect(program.modules, isNotEmpty);
        // Sanity: the engine can also interpret the result without
        // throwing a runtime error on well-typed programs.
        final lines = <String>[];
        BallEngine(program, stdout: lines.add).run();
      });
    }
  });
}
