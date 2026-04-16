/// Cross-language fuzzer: generates small pseudo-random Dart programs
/// and runs each through every available Ball pipeline, asserting all
/// pipelines produce byte-identical stdout.
///
/// Unlike the fixture-based harness, this one exists to find DIVERGENCE
/// bugs: pipelines that disagree on the same input. The fixture harness
/// catches "pipeline X doesn't compile" failures; the fuzzer catches
/// "pipeline X gives a different answer from Y" failures.
///
/// Grammar is narrow — integer arithmetic, comparisons, if/else, simple
/// functions, recursion — chosen so every program is known to terminate
/// and stay under the C++ runner's stack budget. Deterministic seed, so
/// any failure reproduces exactly.
@TestOn('vm')
@Tags(['slow'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Grammar ──────────────────────────────────────────────────────
//
// Expressions: int literal, variable ref, binary arithmetic, comparisons.
// Statements: print(expr), var-init, if/else, while with bounded counter.
// Top-level: 1-3 helper functions + main. All functions take 1 int param
// and return an int, to keep the IR shape uniform.

class _Gen {
  final Random rng;
  final List<String> vars;
  final List<String> fns;
  int depth = 0;
  int _loopCounter = 0;
  _Gen(this.rng, this.vars, this.fns);

  /// Integer-valued expression.
  String expr({int maxDepth = 3}) {
    if (depth >= maxDepth) return _atom();
    final choice = rng.nextInt(9);
    depth++;
    try {
      if (choice == 0) return _atom();
      if (choice == 1) {
        final op = ['+', '-', '*'][rng.nextInt(3)];
        return '(${expr(maxDepth: maxDepth)} $op ${expr(maxDepth: maxDepth)})';
      }
      if (choice == 2) return '(-${expr(maxDepth: maxDepth)})';
      // Division/modulo: strictly positive divisor so we never throw
      // IntegerDivisionByZeroException.
      if (choice == 3) {
        final div = 1 + rng.nextInt(10);
        return '(${expr(maxDepth: maxDepth)} ~/ $div)';
      }
      if (choice == 4) {
        final mod = 1 + rng.nextInt(10);
        return '(${expr(maxDepth: maxDepth)} % $mod)';
      }
      // Function call on a helper.
      if (choice == 5 && fns.isNotEmpty) {
        final fn = fns[rng.nextInt(fns.length)];
        return '$fn(${expr(maxDepth: maxDepth)})';
      }
      // Ternary.
      if (choice == 6) {
        return '(${boolExpr(maxDepth: maxDepth - 1)} '
            '? ${expr(maxDepth: maxDepth)} : ${expr(maxDepth: maxDepth)})';
      }
      // .abs() on an integer expression.
      if (choice == 7) {
        return '(${expr(maxDepth: maxDepth)}).abs()';
      }
      // List index: `[a, b, c][idx % 3]`. Modulo guarantees a valid
      // index so we never hit RangeError.
      if (choice == 8) {
        final a = expr(maxDepth: maxDepth);
        final b = expr(maxDepth: maxDepth);
        final c = expr(maxDepth: maxDepth);
        return '([$a, $b, $c])[(${expr(maxDepth: maxDepth)} % 3).abs()]';
      }
      return _atom();
    } finally {
      depth--;
    }
  }

  /// String-valued expression. Concats, method calls, interpolation.
  String stringExpr({int maxDepth = 2}) {
    if (depth >= maxDepth) return _stringAtom();
    depth++;
    try {
      final choice = rng.nextInt(5);
      if (choice == 0) return _stringAtom();
      if (choice == 1) {
        // Concat.
        return '(${stringExpr(maxDepth: maxDepth)} + '
            '${stringExpr(maxDepth: maxDepth)})';
      }
      if (choice == 2) {
        // Integer stringification: `i.toString()`.
        return '(${expr(maxDepth: maxDepth)}).toString()';
      }
      if (choice == 3) {
        // Method call on string.
        final m = ['toUpperCase', 'toLowerCase', 'trim'][rng.nextInt(3)];
        return '(${stringExpr(maxDepth: maxDepth)}).$m()';
      }
      // String interpolation with a bool inside.
      return "'v:\${${expr(maxDepth: maxDepth)}}'";
    } finally {
      depth--;
    }
  }

  /// Boolean expression (for ternaries, conditions).
  String boolExpr({int maxDepth = 2}) {
    if (depth >= maxDepth) {
      return condition();
    }
    depth++;
    try {
      final choice = rng.nextInt(4);
      if (choice == 0) return condition();
      if (choice == 1) {
        return '(${boolExpr(maxDepth: maxDepth)} && '
            '${boolExpr(maxDepth: maxDepth)})';
      }
      if (choice == 2) {
        return '(${boolExpr(maxDepth: maxDepth)} || '
            '${boolExpr(maxDepth: maxDepth)})';
      }
      return '(!${boolExpr(maxDepth: maxDepth)})';
    } finally {
      depth--;
    }
  }

  String _atom() {
    // Atoms are literal integers or local-variable references. NEVER
    // helper function names — those can only appear at call sites.
    if (vars.isEmpty || rng.nextBool()) return rng.nextInt(20).toString();
    return vars[rng.nextInt(vars.length)];
  }

  String _stringAtom() {
    const lits = ['hello', 'world', 'Ball', 'TEST', '  spaced  ', ''];
    return "'${lits[rng.nextInt(lits.length)]}'";
  }

  String condition() {
    final ops = ['<', '<=', '>', '>=', '==', '!='];
    final op = ops[rng.nextInt(ops.length)];
    return '(${expr(maxDepth: 2)} $op ${expr(maxDepth: 2)})';
  }

  int _stmtDepth = 0;

  String statement({bool insideLoop = false}) {
    // Hard cap on nesting — without this, if/else chains double in
    // size each level and produce ~100KB single-line programs that
    // trip the Dart parser's nesting limit.
    if (_stmtDepth >= 2) {
      return _leafStatement();
    }
    _stmtDepth++;
    try {
      // Pick among: leaf print, string print, if/else, while (outside
      // loop), try/catch.
      final choiceMax = insideLoop ? 4 : 5;
      final choice = rng.nextInt(choiceMax);
      if (choice == 0) return _leafStatement();
      if (choice == 1) {
        return 'print(${stringExpr()});';
      }
      if (choice == 2) {
        return 'if (${boolExpr()}) { ${statement()} } else { ${statement()} }';
      }
      if (choice == 3) {
        // Try/catch that catches a guaranteed FormatException. Always
        // prints a known value from the catch — uses a literal to
        // avoid emitting diverging output on runtime values.
        return "try { int.parse('not a number'); print('unreached'); } "
            "on FormatException catch (e) { print('caught-format'); }";
      }
      final ivar = '_i${_loopCounter++}';
      return 'var $ivar = 0; while ($ivar < 3) { '
          '${statement(insideLoop: true)} $ivar = $ivar + 1; }';
    } finally {
      _stmtDepth--;
    }
  }

  String _leafStatement() {
    final choice = rng.nextInt(3);
    if (choice == 0) return 'print((${expr()}).toString());';
    if (choice == 1) return 'print(${stringExpr()});';
    // Print a bool literal from a comparison.
    return 'print((${boolExpr()}).toString());';
  }

  String function(String name) {
    final paramVars = ['input'];
    final savedVars = vars.toList();
    vars..clear()..addAll(paramVars);
    final body = expr();
    vars..clear()..addAll(savedVars);
    return 'int $name(int input) => $body;';
  }
}

String _genProgram(int seed) {
  final rng = Random(seed);
  final buf = StringBuffer();
  final gen = _Gen(rng, [], []);

  // 0-2 helper functions.
  final fnCount = rng.nextInt(3);
  final fnNames = <String>[];
  for (var i = 0; i < fnCount; i++) {
    final n = 'h$i';
    fnNames.add(n);
    buf.writeln(gen.function(n));
  }
  gen.fns..clear()..addAll(fnNames);

  // main body with a few variable declarations and statements.
  buf.writeln('void main() {');
  final varCount = 2 + rng.nextInt(3);
  final localVars = <String>[];
  for (var i = 0; i < varCount; i++) {
    final name = 'v$i';
    localVars.add(name);
    buf.writeln('  var $name = ${rng.nextInt(30)};');
  }
  gen.vars..clear()..addAll(localVars);
  final stmtCount = 2 + rng.nextInt(3);
  for (var i = 0; i < stmtCount; i++) {
    buf.writeln('  ${gen.statement()}');
  }
  // Always print something at the end so we can compare outputs.
  buf.writeln('  print((${gen.expr()}).toString());');
  buf.writeln('}');
  return buf.toString();
}

// ── Pipelines ────────────────────────────────────────────────────

String _norm(String s) =>
    s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();

String _runDartNative(File f) {
  final r = Process.runSync(
    Platform.resolvedExecutable,
    ['run', f.absolute.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (r.exitCode != 0) {
    throw StateError('dart run failed:\n${r.stderr}');
  }
  return _norm(r.stdout as String);
}

Future<String> _runBallEngine(Program p) async {
  final lines = <String>[];
  await BallEngine(p, stdout: lines.add).run();
  return _norm(lines.join('\n'));
}

String _runRecompiledDart(Program p, Directory dir, String name) {
  final source = DartCompiler(p).compile();
  final f = File('${dir.path}/$name.regen.dart');
  f.writeAsStringSync(source);
  return _runDartNative(f);
}

// ── Test ─────────────────────────────────────────────────────────

void main() {
  group('cross-language fuzzer', () {
    late final Directory scratch;
    setUpAll(() {
      scratch = Directory.systemTemp.createTempSync('ball_cross_fuzz_');
    });
    tearDownAll(() {
      try {
        scratch.deleteSync(recursive: true);
      } catch (_) {}
    });

    // 25 deterministic seeds. Each one generates a program, runs it
    // through every pipeline, and diffs. Keep the count modest: each
    // seed invokes `dart run` twice (baseline + recompiled), which
    // dominates the runtime.
    for (var seed = 0; seed < 25; seed++) {
      test('seed $seed', () async {
        final source = _genProgram(seed);
        final fixture = File('${scratch.path}/fuzz$seed.dart');
        fixture.writeAsStringSync(source);

        // Baseline.
        final baseline = _runDartNative(fixture);

        // Encoder → Ball IR.
        final Program program;
        try {
          program = DartEncoder().encode(source);
        } catch (e) {
          fail('encoder threw on:\n$source\nerror: $e');
        }

        // BallEngine (Dart).
        final engineOut = await _runBallEngine(program);
        expect(
          engineOut,
          equals(baseline),
          reason: 'BallEngine diverged on:\n$source\n'
              '--- baseline ---\n$baseline\n'
              '--- engine ---\n$engineOut',
        );

        // DartCompiler → dart run.
        final recompiledOut = _runRecompiledDart(program, scratch, 'fuzz$seed');
        expect(
          recompiledOut,
          equals(baseline),
          reason: 'Recompiled Dart diverged on:\n$source',
        );
      });
    }
  });
}
