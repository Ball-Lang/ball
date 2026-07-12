/// In-process unit tests for the Ball CLI [runBall] entry point.
///
/// These exercise every command and its error paths directly (no subprocess),
/// so the `ball_cli` package's command logic is instrumented for coverage. Real
/// temp files are used for fixtures; project-file commands (`init`, `add`,
/// `resolve`, `build`, `publish`) run with `Directory.current` swapped to a
/// throwaway temp dir and restored in `tearDown`.
///
/// Run: cd dart/cli && dart test test/runner_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show encodeBallFileBinary, encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_cli/src/runner.dart';
import 'package:ball_cli/version.g.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The `version:` from the ball_cli package's `pubspec.yaml`, located by
/// walking up from the current directory. Used to assert `ball version` and the
/// generated [ballCliVersion] never drift from the published package (#363).
String _pubspecVersion() {
  var dir = Directory.current;
  while (true) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync()) {
      final text = pubspec.readAsStringSync();
      if (text.contains('name: ball_cli')) {
        return (loadYaml(text) as YamlMap)['version'].toString();
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate the ball_cli pubspec.yaml');
    }
    dir = parent;
  }
}

void main() {
  late Directory tmp;
  late Directory originalCwd;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ball_cli_runner_');
    originalCwd = Directory.current;
  });

  tearDown(() {
    // Always restore CWD before deleting the temp dir.
    try {
      Directory.current = originalCwd;
    } catch (_) {}
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ── helpers ──────────────────────────────────────────────────────────────

  String p(String name) => '${tmp.path}/$name';

  /// Encodes a tiny Dart snippet to a valid Ball [Program].
  Program encodeProgram(String src, {String name = 'demo'}) =>
      DartEncoder().encode(src, name: name);

  /// Writes a minimal valid `.ball.json` (a `print(1)` program) and returns its
  /// path.
  String writeValidProgram({
    String name = 'demo',
    String src = 'void main(){print(1);}',
  }) {
    final prog = encodeProgram(src, name: name);
    final path = p('$name.ball.json');
    File(path).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(encodeBallFileJson(prog)),
    );
    return path;
  }

  /// Runs the CLI in-process, returning (code, out, err).
  Future<(int, String, String)> run(List<String> args) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runBall(args, out: out, err: err);
    return (code, out.toString(), err.toString());
  }

  // ── top-level dispatch ─────────────────────────────────────────────────────

  group('top-level', () {
    test('empty args prints usage to stderr and returns 1', () async {
      final (code, out, err) = await run([]);
      expect(code, 1);
      expect(out, isEmpty);
      expect(err, contains('Ball Language CLI'));
      expect(err, contains('Usage: ball <command>'));
    });

    test('unknown command returns 1 with usage', () async {
      final (code, out, err) = await run(['frobnicate']);
      expect(code, 1);
      expect(err, contains('Unknown command: frobnicate'));
      expect(err, contains('Usage: ball <command>'));
      expect(out, isEmpty);
    });

    for (final flag in const ['version', '--version', '-v']) {
      test('$flag prints version', () async {
        final (code, out, err) = await run([flag]);
        expect(code, 0);
        // Single-sourced from pubspec.yaml (issue #363) — must never drift.
        expect(out.trim(), 'ball ${_pubspecVersion()}');
        expect(err, isEmpty);
      });
    }

    test('reported version matches pubspec.yaml (issue #363)', () {
      expect(ballCliVersion, _pubspecVersion());
    });

    test('default sinks: runBall with no out/err writes to stdout', () async {
      // Exercises the `out ??= stdout` / `err ??= stderr` defaults. `version`
      // prints a single harmless line to the real stdout.
      final code = await runBall(['version']);
      expect(code, 0);
    });

    for (final flag in const ['help', '--help', '-h']) {
      test('$flag prints usage', () async {
        final (code, out, err) = await run([flag]);
        expect(code, 0);
        expect(err, contains('Ball Language CLI'));
        expect(out, isEmpty);
      });
    }
  });

  // ── info ───────────────────────────────────────────────────────────────────

  group('info', () {
    test('prints program structure', () async {
      final path = writeValidProgram(name: 'infoprog');
      final (code, out, err) = await run(['info', path]);
      expect(code, 0);
      expect(out, contains('Program: infoprog v1.0.0'));
      expect(out, contains('Entry:   main.main'));
      expect(out, contains('Modules: 2'));
      expect(out, contains('std (base)'));
      expect(out, contains('functions:'));
    });

    test('prints enums, aliases and description when present', () async {
      // Encoding a Dart enum populates module.enums; a hand-added TypeAlias and
      // description exercise the remaining `info` branches.
      final prog = encodeProgram(
        'enum Color { red, green }\nvoid main(){ var c = Color.red; print(c); }',
      );
      prog.modules.firstWhere((m) => m.name == 'main')
        ..typeAliases.add(TypeAlias()..name = 'Id')
        ..description = 'the main module';
      final path = p('rich.ball.json');
      File(path).writeAsStringSync(jsonEncode(encodeBallFileJson(prog)));
      final (code, out, _) = await run(['info', path]);
      expect(code, 0);
      expect(out, contains('enums:     1'));
      expect(out, contains('aliases:   1'));
      expect(out, contains('desc:      the main module'));
    });

    test('missing argument returns 1', () async {
      final (code, out, err) = await run(['info']);
      expect(code, 1);
      expect(err, contains('Usage: ball info'));
      expect(out, isEmpty);
    });

    test('missing file returns 1', () async {
      final (code, out, err) = await run(['info', p('nope.ball.json')]);
      expect(code, 1);
      expect(err, contains('File not found'));
    });

    test(
      'unreadable file returns 1 (Error reading file)',
      () async {
        // Exercises _loadProgram's readAsStringSync() catch, distinct from
        // the "missing file" (existsSync false) branch above: the file
        // exists but a permission failure makes the read itself throw.
        // POSIX-only (chmod semantics); Windows has no equivalent portable
        // way to make an owned, existing file unreadable, so this is skipped
        // there rather than faked -- it still runs for real on CI (Linux).
        final path = p('locked.ball.json');
        File(path).writeAsStringSync('{}');
        await Process.run('chmod', ['000', path]);
        try {
          final (code, _, err) = await run(['info', path]);
          expect(code, 1);
          expect(err, contains('Error reading file'));
        } finally {
          // Restore permissions so tearDown can delete the temp dir.
          await Process.run('chmod', ['700', path]);
        }
      },
      skip: Platform.isWindows
          ? 'chmod-based unreadable-file simulation is POSIX-only'
          : false,
    );

    test('invalid JSON returns 1', () async {
      final path = p('bad.ball.json');
      File(path).writeAsStringSync('{ not valid json ');
      final (code, _, err) = await run(['info', path]);
      expect(code, 1);
      expect(err, contains('Error parsing JSON'));
    });

    test('non-Program ball file returns 1 (deserialize error)', () async {
      // A Module ball file is rejected by decodeProgramJson.
      final path = p('mod.ball.json');
      final module = Module()..name = 'lib';
      File(path).writeAsStringSync(jsonEncode(encodeBallFileJson(module)));
      final (code, _, err) = await run(['info', path]);
      expect(code, 1);
      expect(err, contains('Error deserializing ball program'));
    });
  });

  // ── validate ────────────────────────────────────────────────────────────────

  group('validate', () {
    test('valid program', () async {
      final path = writeValidProgram();
      final (code, out, err) = await run(['validate', path]);
      expect(code, 0);
      expect(out, contains('Valid:'));
      expect(out, contains('modules,'));
    });

    test('missing argument returns 1', () async {
      final (code, _, err) = await run(['validate']);
      expect(code, 1);
      expect(err, contains('Usage: ball validate'));
    });

    /// Writes a hand-built Program ball file with the given mutator applied.
    String writeProgram(void Function(Program) mutate) {
      final prog = encodeProgram('void main(){print(1);}');
      mutate(prog);
      final path = p('mutated.ball.json');
      File(path).writeAsStringSync(jsonEncode(encodeBallFileJson(prog)));
      return path;
    }

    test('missing entry module/function', () async {
      final path = writeProgram((prog) {
        prog.clearEntryModule();
        prog.clearEntryFunction();
      });
      final (code, _, err) = await run(['validate', path]);
      expect(code, 1);
      expect(err, contains('Missing entry_module'));
      expect(err, contains('Missing entry_function'));
    });

    test('entry module not found', () async {
      final path = writeProgram((prog) => prog.entryModule = 'ghost');
      final (code, _, err) = await run(['validate', path]);
      expect(code, 1);
      expect(err, contains('Entry module "ghost" not found'));
    });

    test('entry function not found', () async {
      final path = writeProgram((prog) => prog.entryFunction = 'ghostFn');
      final (code, _, err) = await run(['validate', path]);
      expect(code, 1);
      expect(err, contains('Entry function "ghostFn" not found'));
    });

    test('module with no name', () async {
      final path = writeProgram((prog) => prog.modules.add(Module()));
      final (code, _, err) = await run(['validate', path]);
      expect(code, 1);
      expect(err, contains('has no name'));
    });

    test('duplicate module name', () async {
      final path = writeProgram(
        (prog) => prog.modules.add(Module()..name = 'main'),
      );
      final (code, _, err) = await run(['validate', path]);
      expect(code, 1);
      expect(err, contains('Duplicate module name: "main"'));
    });

    test('non-base function with no body or metadata', () async {
      final path = writeProgram((prog) {
        prog.modules
            .firstWhere((m) => m.name == 'main')
            .functions
            .add(FunctionDefinition()..name = 'orphan');
      });
      final (code, _, err) = await run(['validate', path]);
      expect(code, 1);
      expect(err, contains('main.orphan: non-base function with no body'));
    });
  });

  // ── compile ──────────────────────────────────────────────────────────────────

  group('compile', () {
    test('to stdout', () async {
      final path = writeValidProgram();
      final (code, out, err) = await run(['compile', path]);
      expect(code, 0);
      expect(out, contains('void main()'));
      expect(out, contains('print(1)'));
    });

    test('to --output file', () async {
      final path = writeValidProgram();
      final outFile = p('out.dart');
      final (code, out, err) = await run([
        'compile',
        path,
        '--output',
        outFile,
      ]);
      expect(code, 0);
      expect(err, contains('Compiled to $outFile'));
      expect(out, isEmpty);
      expect(File(outFile).readAsStringSync(), contains('void main()'));
    });

    test('--no-format', () async {
      final path = writeValidProgram();
      final (code, out, _) = await run(['compile', path, '--no-format']);
      expect(code, 0);
      expect(out, contains('void main()'));
    });

    test('missing argument returns 1', () async {
      final (code, _, err) = await run(['compile']);
      expect(code, 1);
      expect(err, contains('Usage: ball compile'));
    });
  });

  // ── encode ───────────────────────────────────────────────────────────────────

  group('encode', () {
    String writeDart(String name, String src) {
      final path = p(name);
      File(path).writeAsStringSync(src);
      return path;
    }

    test('to stdout (json default)', () async {
      final src = writeDart('app.dart', 'void main(){print(1);}');
      final (code, out, err) = await run(['encode', src]);
      expect(code, 0);
      expect(out, contains('"@type"'));
      expect(out, contains('ball.v1.Program'));
    });

    test('to --output (json)', () async {
      final src = writeDart('app.dart', 'void main(){print(1);}');
      final outFile = p('app.ball.json');
      final (code, out, err) = await run(['encode', src, '--output', outFile]);
      expect(code, 0);
      expect(err, contains('Encoded to $outFile (JSON)'));
      expect(File(outFile).readAsStringSync(), contains('ball.v1.Program'));
    });

    test('binary to --output', () async {
      final src = writeDart('app.dart', 'void main(){print(1);}');
      final outFile = p('app.ball.bin');
      final (code, out, err) = await run([
        'encode',
        src,
        '--format',
        'binary',
        '--output',
        outFile,
      ]);
      expect(code, 0);
      expect(err, contains('(binary,'));
      expect(File(outFile).lengthSync(), greaterThan(0));
    });

    test('binary to text sink emits a note (no raw bytes)', () async {
      final src = writeDart('app.dart', 'void main(){print(1);}');
      final (code, out, _) = await run(['encode', src, '--format', 'binary']);
      expect(code, 0);
      expect(out, contains('<binary:'));
    });

    // NOTE: the `identical(out, stdout)` branch in `_encode` (raw
    // `stdout.add(bytes)`) is deliberately NOT unit-tested — writing binary to
    // the real test-process stdout corrupts the suite's stdout stream (it broke
    // the coverage runner, which captured it as UTF-8). That one line is
    // exercised only via the real CLI; the text-sink note path above covers the
    // testable behavior.

    test('missing argument returns 1', () async {
      final (code, _, err) = await run(['encode']);
      expect(code, 1);
      expect(err, contains('Usage: ball encode'));
    });

    test('missing file returns 1', () async {
      final (code, _, err) = await run(['encode', p('nope.dart')]);
      expect(code, 1);
      expect(err, contains('File not found'));
    });
  });

  // ── run ────────────────────────────────────────────────────────────────────

  group('run', () {
    test('executes program (exit 0)', () async {
      final path = writeValidProgram();
      // Engine prints directly to the real stdout; we only assert it runs
      // without error and returns 0.
      final (code, _, err) = await run(['run', path]);
      expect(code, 0);
      expect(err, isEmpty);
    });

    test('missing argument returns 1', () async {
      final (code, _, err) = await run(['run']);
      expect(code, 1);
      expect(err, contains('Usage: ball run'));
    });
  });

  // ── round-trip ──────────────────────────────────────────────────────────────

  group('round-trip', () {
    String writeDart(String name, String src) {
      final path = p(name);
      File(path).writeAsStringSync(src);
      return path;
    }

    test('to stdout with diff summary', () async {
      final src = writeDart('rt.dart', 'void main(){print(1);}');
      final (code, out, err) = await run(['round-trip', src]);
      expect(code, 0);
      expect(err, contains('--- original'));
      expect(err, contains('+++ round-tripped'));
      expect(out, contains('void main()'));
    });

    test('to --output file', () async {
      final src = writeDart('rt.dart', 'void main(){print(1);}');
      final outFile = p('rt_out.dart');
      final (code, out, err) = await run([
        'round-trip',
        src,
        '--output',
        outFile,
      ]);
      expect(code, 0);
      expect(err, contains('Round-tripped Dart written to $outFile'));
      expect(File(outFile).readAsStringSync(), contains('void main()'));
    });

    test('prints encoder warnings', () async {
      // An unnamed extension makes the encoder emit a warning, exercising the
      // warnings-print branch.
      final src = writeDart(
        'ext.dart',
        'extension on int { int get inc => this + 1; }\nvoid main(){ print(1.inc); }',
      );
      final (code, out, err) = await run(['round-trip', src]);
      expect(code, 0);
      expect(err, contains('Warning: Extension declaration has no name'));
    });

    test('missing argument returns 1', () async {
      final (code, _, err) = await run(['round-trip']);
      expect(code, 1);
      expect(err, contains('Usage: ball round-trip'));
    });

    test('missing file returns 1', () async {
      final (code, _, err) = await run(['round-trip', p('nope.dart')]);
      expect(code, 1);
      expect(err, contains('File not found'));
    });

    test('compile error returns 1', () async {
      // Dart with no `main` encodes fine (non-strict encoder) but the compiler
      // rejects it (no entry function) — exercising the compile-error catch.
      final src = writeDart('nomain.dart', 'class Foo { void bar() {} }');
      final (code, _, err) = await run(['round-trip', src]);
      expect(code, 1);
      expect(err, contains('Error compiling ball program'));
    });
  });

  // ── audit ────────────────────────────────────────────────────────────────────

  group('audit', () {
    test('program report to stdout', () async {
      final path = writeValidProgram();
      final (code, out, err) = await run(['audit', path]);
      expect(code, 0);
      expect(out, contains('Ball Capability Audit'));
      expect(out, contains('Capabilities:'));
    });

    test('--deny io --exit-code returns 1 with violations', () async {
      final path = writeValidProgram();
      final (code, out, err) = await run([
        'audit',
        path,
        '--deny',
        'io',
        '--exit-code',
      ]);
      expect(code, 1);
      expect(err, contains('Policy violations'));
      expect(err, contains('io: main.main calls std.print'));
    });

    test('--deny without --exit-code still returns 0 but reports', () async {
      final path = writeValidProgram();
      final (code, out, err) = await run(['audit', path, '--deny', 'io']);
      expect(code, 0);
      expect(err, contains('Policy violations'));
    });

    test('--output writes JSON report', () async {
      final path = writeValidProgram();
      final report = p('report.json');
      final (code, out, err) = await run(['audit', path, '--output', report]);
      expect(code, 0);
      expect(err, contains('Report written to $report'));
      final decoded = jsonDecode(File(report).readAsStringSync());
      expect(decoded, isA<Map>());
    });

    test('--no-check-termination skips termination block', () async {
      final path = writeValidProgram();
      final (code, out, _) = await run([
        'audit',
        path,
        '--no-check-termination',
      ]);
      expect(code, 0);
      expect(out, contains('Ball Capability Audit'));
    });

    test('--check-termination flag is accepted', () async {
      final path = writeValidProgram();
      final (code, out, _) = await run(['audit', path, '--check-termination']);
      expect(code, 0);
      expect(out, contains('Ball Capability Audit'));
    });

    test('audits a Module ball file (no synthetic Program)', () async {
      final path = p('lib.ball.json');
      final module = Module()
        ..name = 'mylib'
        ..functions.add(
          FunctionDefinition()
            ..name = 'noop'
            ..isBase = true,
        );
      File(path).writeAsStringSync(jsonEncode(encodeBallFileJson(module)));
      final (code, out, err) = await run(['audit', path]);
      expect(code, 0);
      expect(out, contains('Ball Capability Audit'));
    });

    test('Module audit follows inline module imports', () async {
      // A facade Module that embeds an implementation module inline via
      // module_imports[].inline.proto_bytes — exercising _inlineImports.
      final inner = Module()
        ..name = 'impl'
        ..functions.add(
          FunctionDefinition()
            ..name = 'helper'
            ..isBase = true,
        );
      final facade = Module()
        ..name = 'facade'
        ..moduleImports.add(
          ModuleImport()
            ..name = 'impl'
            ..inline = (InlineSource()..protoBytes = inner.writeToBuffer()),
        );
      final path = p('facade.ball.json');
      File(path).writeAsStringSync(jsonEncode(encodeBallFileJson(facade)));
      final (code, out, _) = await run(['audit', path]);
      expect(code, 0);
      expect(out, contains('Ball Capability Audit'));
    });

    test('Module audit warns when --reachable-only is given', () async {
      final path = p('lib.ball.json');
      final module = Module()
        ..name = 'mylib'
        ..functions.add(
          FunctionDefinition()
            ..name = 'noop'
            ..isBase = true,
        );
      File(path).writeAsStringSync(jsonEncode(encodeBallFileJson(module)));
      final (code, out, err) = await run(['audit', path, '--reachable-only']);
      expect(code, 0);
      expect(err, contains('--reachable-only has no effect'));
    });

    test('--reachable-only on a Program', () async {
      final path = writeValidProgram();
      final (code, out, _) = await run(['audit', path, '--reachable-only']);
      expect(code, 0);
      expect(out, contains('Ball Capability Audit'));
    });

    test('reports termination warnings for an infinite loop', () async {
      final path = writeValidProgram(
        name: 'loopy',
        src: 'void main(){ while(true){ print(1); } }',
      );
      final (code, out, _) = await run(['audit', path]);
      expect(code, 0);
      expect(out, contains('Termination Analysis'));
      expect(out, contains('while(true) loop'));
    });

    // --reachable-only scopes only the capability report to the entry closure;
    // termination still runs on the WHOLE program, so the Termination Analysis
    // section must still appear (issue #412 — the TS CLI dropped it here).
    test('reports termination warnings under --reachable-only', () async {
      final path = writeValidProgram(
        name: 'loopy',
        src: 'void main(){ while(true){ print(1); } }',
      );
      final (code, out, _) = await run(['audit', path, '--reachable-only']);
      expect(code, 0);
      expect(out, contains('Termination Analysis'));
      expect(out, contains('while(true) loop'));
    });

    test('missing input returns 1', () async {
      final (code, _, err) = await run(['audit', '--deny', 'io']);
      expect(code, 1);
      expect(err, contains('Usage: ball audit'));
    });

    test('missing ball file returns 1', () async {
      final (code, _, err) = await run(['audit', p('ghost.ball.json')]);
      expect(code, 1);
      expect(err, contains('File not found'));
    });

    test('binary (.bin) ball file path', () async {
      final prog = encodeProgram('void main(){print(1);}');
      final path = p('prog.ball.bin');
      File(path).writeAsBytesSync(encodeBallFileBinary(prog));
      final (code, out, _) = await run(['audit', path]);
      expect(code, 0);
      expect(out, contains('Ball Capability Audit'));
    });

    test('corrupt ball file returns 1', () async {
      final path = p('corrupt.ball.json');
      File(path).writeAsStringSync('{"@type":"bogus"}');
      final (code, _, err) = await run(['audit', path]);
      expect(code, 1);
      expect(err, contains('Error deserializing ball file'));
    });
  });

  // ── build ──────────────────────────────────────────────────────────────────

  group('build', () {
    test('self-contained program (no imports) to --output', () async {
      final path = writeValidProgram();
      final outFile = p('resolved.ball.json');
      final (code, out, err) = await run(['build', path, '--output', outFile]);
      expect(code, 0);
      expect(err, contains('already self-contained'));
      expect(File(outFile).existsSync(), isTrue);
    });

    test('self-contained program (no imports) to stderr only', () async {
      final path = writeValidProgram();
      final (code, out, err) = await run(['build', path]);
      expect(code, 0);
      expect(err, contains('already self-contained'));
    });

    test('missing input returns 1', () async {
      final (code, _, err) = await run(['build']);
      expect(code, 1);
      expect(err, contains('Usage: ball build'));
    });

    test('missing file returns 1', () async {
      final (code, _, err) = await run(['build', p('nope.ball.json')]);
      expect(code, 1);
      expect(err, contains('File not found'));
    });

    test('program with a local file import resolves (no network)', () async {
      // A program carrying an unresolved file import drives the resolver path
      // (the file adapter resolves locally, no pub.dev), writing the resolved
      // program to --output.
      final prog = encodeProgram('void main(){print(1);}');
      prog.modules
          .firstWhere((m) => m.name == 'main')
          .moduleImports
          .add(
            ModuleImport()
              ..name = 'dep'
              ..file = (FileSource()..path = './dep.ball.bin'),
          );
      final input = p('withimport.ball.json');
      File(input).writeAsStringSync(jsonEncode(encodeBallFileJson(prog)));
      // Provide the imported module so the file adapter can load it.
      final dep = Module()
        ..name = 'dep'
        ..functions.add(
          FunctionDefinition()
            ..name = 'noop'
            ..isBase = true,
        );
      File(p('dep.ball.bin')).writeAsBytesSync(encodeBallFileBinary(dep));
      final outFile = p('built.ball.json');
      // Resolve relative to the directory holding the input file.
      final saved = Directory.current;
      Directory.current = tmp;
      try {
        final (code, out, err) = await run([
          'build',
          'withimport.ball.json',
          '--output',
          'built.ball.json',
        ]);
        expect(code, 0);
        expect(err, contains('Resolved program written to'));
        expect(File(p('built.ball.json')).existsSync(), isTrue);
      } finally {
        Directory.current = saved;
      }
      // Reference outFile so the analyzer doesn't flag it unused.
      expect(outFile, isNotEmpty);
    });

    test('program with import + ball.lock.json uses the lock cache', () async {
      final prog = encodeProgram('void main(){print(1);}');
      prog.modules
          .firstWhere((m) => m.name == 'main')
          .moduleImports
          .add(
            ModuleImport()
              ..name = 'dep'
              ..file = (FileSource()..path = './dep.ball.bin'),
          );
      final dep = Module()
        ..name = 'dep'
        ..functions.add(
          FunctionDefinition()
            ..name = 'noop'
            ..isBase = true,
        );
      final saved = Directory.current;
      Directory.current = tmp;
      try {
        File(
          'withimport.ball.json',
        ).writeAsStringSync(jsonEncode(encodeBallFileJson(prog)));
        File('dep.ball.bin').writeAsBytesSync(encodeBallFileBinary(dep));
        File('ball.lock.json').writeAsStringSync(
          jsonEncode({
            'lock_version': '1',
            'packages': [
              {'name': 'dep'},
            ],
          }),
        );
        final (code, out, err) = await run([
          'build',
          'withimport.ball.json',
          '--output',
          'built.ball.json',
        ]);
        expect(code, 0);
        expect(err, contains('Using ball.lock.json (1 packages cached)'));
      } finally {
        Directory.current = saved;
      }
    });

    test(
      'program with a local file import resolves to stdout (no --output)',
      () async {
        // Same resolvable-file-import setup as above, but omitting --output
        // exercises the `out.writeln(jsonOut)` success branch instead of the
        // File(outputPath).writeAsStringSync branch.
        final prog = encodeProgram('void main(){print(1);}');
        prog.modules
            .firstWhere((m) => m.name == 'main')
            .moduleImports
            .add(
              ModuleImport()
                ..name = 'dep'
                ..file = (FileSource()..path = './dep.ball.bin'),
            );
        final dep = Module()
          ..name = 'dep'
          ..functions.add(
            FunctionDefinition()
              ..name = 'noop'
              ..isBase = true,
          );
        final saved = Directory.current;
        Directory.current = tmp;
        try {
          File(
            'withimport.ball.json',
          ).writeAsStringSync(jsonEncode(encodeBallFileJson(prog)));
          File('dep.ball.bin').writeAsBytesSync(encodeBallFileBinary(dep));
          final (code, out, err) = await run(['build', 'withimport.ball.json']);
          expect(code, 0);
          expect(err, isNot(contains('Resolved program written to')));
          expect(out, contains('ball.v1.Program'));
        } finally {
          Directory.current = saved;
        }
      },
    );

    test('unresolvable file import leaves it unresolved (resolveAll swallows '
        'per-import failures) instead of failing the command', () async {
      // ModuleResolver.resolveAll (dart/resolver/lib/resolver.dart) catches
      // and swallows every per-import resolution failure ("leave the
      // import unresolved... engines/compilers will report the missing
      // module") -- it never rethrows. So `ball build` still exits 0 with
      // the unresolved import left in place; there is no user-triggerable
      // path to _build's own `catch (e)` (see the ignore annotation there).
      final prog = encodeProgram('void main(){print(1);}');
      prog.modules
          .firstWhere((m) => m.name == 'main')
          .moduleImports
          .add(
            ModuleImport()
              ..name = 'dep'
              ..file = (FileSource()..path = './missing_dep.ball.bin'),
          );
      final saved = Directory.current;
      Directory.current = tmp;
      try {
        File(
          'withbadimport.ball.json',
        ).writeAsStringSync(jsonEncode(encodeBallFileJson(prog)));
        final (code, out, _) = await run(['build', 'withbadimport.ball.json']);
        expect(code, 0);
        expect(out, contains('missing_dep.ball.bin'));
      } finally {
        Directory.current = saved;
      }
    });
  });

  // ── tree ─────────────────────────────────────────────────────────────────────

  group('tree', () {
    test('prints module tree', () async {
      final path = writeValidProgram(name: 'treeprog');
      final (code, out, err) = await run(['tree', path]);
      expect(code, 0);
      expect(out, contains('treeprog v1.0.0'));
      expect(out, contains('std (base)'));
      expect(out, contains('→ std (ref only)'));
    });

    test('renders import source descriptions', () async {
      // Hand-build a program whose modules carry every import-source variant so
      // the tree formatter's branches are all exercised.
      final prog = encodeProgram('void main(){print(1);}');
      final m = prog.modules.firstWhere((m) => m.name == 'main');
      m.moduleImports
        ..add(
          ModuleImport()
            ..name = 'h'
            ..http = (HttpSource()..url = 'https://x/m.ball.bin'),
        )
        ..add(
          ModuleImport()
            ..name = 'f'
            ..file = (FileSource()..path = 'local.ball.bin'),
        )
        ..add(
          ModuleImport()
            ..name = 'g'
            ..git = (GitSource()
              ..url = 'https://git/r.git'
              ..ref = 'v1'),
        )
        ..add(
          ModuleImport()
            ..name = 'r'
            ..registry = (RegistrySource()
              ..package = 'pkg'
              ..version = '^1.0.0'
              ..registry = Registry.REGISTRY_PUB),
        )
        ..add(
          ModuleImport()
            ..name = 'i'
            ..inline = (InlineSource()
              ..protoBytes = (Module()..name = 'x').writeToBuffer()),
        );
      final path = p('imports.ball.json');
      File(path).writeAsStringSync(jsonEncode(encodeBallFileJson(prog)));
      final (code, out, _) = await run(['tree', path]);
      expect(code, 0);
      expect(out, contains('http: https://x/m.ball.bin'));
      expect(out, contains('file: local.ball.bin'));
      expect(out, contains('git: https://git/r.git@v1'));
      expect(out, contains('pkg@^1.0.0'));
      expect(out, contains('inline'));
    });

    test('missing input returns 1', () async {
      final (code, _, err) = await run(['tree']);
      expect(code, 1);
      expect(err, contains('Usage: ball tree'));
    });
  });

  // ── project-file commands (init / add / resolve / publish) ───────────────────
  //
  // These read/write files relative to Directory.current, so we point the CWD at
  // a fresh temp dir for each test and restore it in tearDown.

  group('project commands', () {
    late Directory projDir;

    setUp(() {
      projDir = Directory.systemTemp.createTempSync('ball_cli_proj_');
      Directory.current = projDir;
    });

    tearDown(() {
      Directory.current = originalCwd;
      try {
        projDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('init creates ball.yaml', () async {
      final (code, out, err) = await run(['init']);
      expect(code, 0);
      expect(out, contains('Created ball.yaml'));
      final yaml = File('${projDir.path}/ball.yaml');
      expect(yaml.existsSync(), isTrue);
      final content = yaml.readAsStringSync();
      expect(content, contains('entry_module: main'));
      expect(content, contains('dependencies: {}'));
    });

    test('init fails if ball.yaml exists', () async {
      await run(['init']);
      final (code, _, err) = await run(['init']);
      expect(code, 1);
      expect(err, contains('already exists'));
    });

    test('add appends a pub dependency', () async {
      await run(['init']);
      final (code, out, err) = await run(['add', 'pub:path@^1.0.0']);
      expect(code, 0);
      expect(out, contains('Added path to ball.yaml'));
      final content = File('${projDir.path}/ball.yaml').readAsStringSync();
      expect(content, contains('registry: pub'));
      expect(content, contains('package: path'));
    });

    test('add npm/git/http specs parse', () async {
      await run(['init']);
      final (c1, _, _) = await run(['add', 'npm:@scope/utils@^2.0.0']);
      final (c2, _, _) = await run([
        'add',
        'git:https://github.com/foo/bar.git@v1.0.0',
      ]);
      // http specs still need an @<version> suffix per _parseImportSpec.
      final (c3, _, _) = await run(['add', 'http:https://x/m.ball.bin@v1']);
      expect([c1, c2, c3], everyElement(0));
      final content = File('${projDir.path}/ball.yaml').readAsStringSync();
      expect(content, contains('registry: npm'));
      expect(content, contains('git:'));
      expect(content, contains('url: "https://x/m.ball.bin"'));
    });

    test('add without args returns 1', () async {
      final (code, _, err) = await run(['add']);
      expect(code, 1);
      expect(err, contains('Usage: ball add'));
    });

    test('add with no ball.yaml returns 1', () async {
      final (code, _, err) = await run(['add', 'pub:path@^1.0.0']);
      expect(code, 1);
      expect(err, contains('No ball.yaml found'));
    });

    test('add invalid spec (no colon) returns 1', () async {
      await run(['init']);
      final (code, _, err) = await run(['add', 'garbage']);
      expect(code, 1);
      expect(err, contains('Invalid import spec'));
    });

    test('add unknown registry returns 1', () async {
      await run(['init']);
      final (code, _, err) = await run(['add', 'unknownreg:pkg@^1.0.0']);
      expect(code, 1);
      expect(err, contains('Invalid import spec'));
    });

    test('resolve with no ball.yaml returns 1', () async {
      final (code, _, err) = await run(['resolve']);
      expect(code, 1);
      expect(err, contains('No ball.yaml found'));
    });

    test('resolve with no dependencies returns 0', () async {
      await run(['init']);
      final (code, _, err) = await run(['resolve']);
      expect(code, 0);
      expect(err, contains('No dependencies declared'));
    });

    test(
      'resolve with only non-map dep specs finds nothing resolvable',
      () async {
        // `dependencies:` is non-empty (so it skips the "No dependencies
        // declared" branch above) but every entry is a bare scalar rather
        // than a map, so the entry-building loop's `spec is! YamlMap` guard
        // skips all of them, leaving `imports` empty -- the distinct "No
        // resolvable dependencies found" branch.
        File('${projDir.path}/ball.yaml').writeAsStringSync('''
name: t
version: 0.1.0
dependencies:
  foo: just-a-scalar
  bar: another-scalar
''');
        final (code, _, err) = await run(['resolve']);
        expect(code, 0);
        expect(err, contains('No resolvable dependencies found.'));
      },
    );

    test(
      'resolve fails fast over local/unsupported deps and writes lockfile',
      () async {
        // No network: npm/nuget/cargo/pypi/maven have no registered adapter (fail
        // fast), git/http/file point at bogus targets, and an empty spec is
        // skipped. Exercises _parseRegistry's cases, every ModuleImport-source
        // branch, the resolve loop, the FAIL catch, and the lockfile write.
        File('${projDir.path}/ball.yaml').writeAsStringSync('''
name: t
version: 0.1.0
dependencies:
  npmdep:
    registry: npm
    package: foo
    version: "^1.0.0"
  nugetdep:
    registry: nuget
    package: bar
    version: "1.0.0"
  cargodep:
    registry: cargo
    package: baz
    version: "1.0.0"
  pypidep:
    registry: pypi
    package: qux
    version: "1.0.0"
  mavendep:
    registry: maven
    package: quux
    version: "1.0.0"
  filedep:
    path: ./missing.ball.bin
  skipped: just-a-scalar
''');
        final (code, out, err) = await run(['resolve']);
        expect(code, 0);
        expect(err, contains('npmdep... FAIL'));
        expect(
          err,
          contains('No adapter registered for registry REGISTRY_NPM'),
        );
        expect(err, contains('filedep... FAIL'));
        expect(err, contains('Wrote ball.lock.json'));
        final lock =
            jsonDecode(
                  File('${projDir.path}/ball.lock.json').readAsStringSync(),
                )
                as Map<String, dynamic>;
        // The bare-scalar "skipped" entry is not a YamlMap → dropped; 6 remain.
        expect((lock['packages'] as List).length, 6);
      },
    );

    test('resolve succeeds for a valid local file dependency', () async {
      // A real local module file resolves OK (covers the success branch +
      // integrity computation), with no network.
      final dep = Module()
        ..name = 'dep'
        ..functions.add(
          FunctionDefinition()
            ..name = 'noop'
            ..isBase = true,
        );
      File(
        '${projDir.path}/dep.ball.bin',
      ).writeAsBytesSync(encodeBallFileBinary(dep));
      File('${projDir.path}/ball.yaml').writeAsStringSync('''
name: t
version: 0.1.0
dependencies:
  dep:
    path: ./dep.ball.bin
''');
      final (code, _, err) = await run(['resolve']);
      expect(code, 0);
      expect(err, contains('dep... OK (1 functions)'));
      final lock =
          jsonDecode(File('${projDir.path}/ball.lock.json').readAsStringSync())
              as Map<String, dynamic>;
      final pkg = (lock['packages'] as List).first as Map<String, dynamic>;
      expect(pkg['integrity'], startsWith('sha256:'));
    });

    test('resolve with malformed yaml returns 1', () async {
      File('${projDir.path}/ball.yaml').writeAsStringSync('  - just a list\n');
      final (code, _, err) = await run(['resolve']);
      expect(code, 1);
      // Either "empty or malformed" or "No resolvable" depending on parse; both
      // are non-zero only for the malformed-map branch. A bare list is not a
      // YamlMap, so loadYaml returns a YamlList → cast to YamlMap? is null.
      expect(err, contains('empty or malformed'));
    });

    test(
      'publish with no ball.yaml and no pubspec returns 0 with error msg',
      () async {
        final (code, _, err) = await run(['publish']);
        expect(code, 0);
        expect(err, contains('No ball.yaml or pubspec.yaml found'));
      },
    );

    test('publish converts a .ball.json to artifacts', () async {
      await run(['init']);
      // ball.yaml now exists but no lib/ dir → falls through to the input-file
      // branch.
      final prog = encodeProgram('void main(){print(1);}');
      final input = '${projDir.path}/hello.ball.json';
      File(input).writeAsStringSync(jsonEncode(encodeBallFileJson(prog)));
      final (code, out, err) = await run(['publish', 'hello.ball.json']);
      expect(code, 0);
      expect(err, contains('Converting'));
      expect(File('${projDir.path}/lib/module.ball.bin').existsSync(), isTrue);
      expect(File('${projDir.path}/lib/module.ball.json').existsSync(), isTrue);
    });

    test(
      'publish with ball.yaml but no lib/ and no input returns 0 with usage',
      () async {
        await run(['init']);
        final (code, _, err) = await run(['publish']);
        expect(code, 0);
        expect(err, contains('No Dart source in lib/'));
      },
    );

    test(
      'publish encodes a Dart package from pubspec.yaml (no ball.yaml)',
      () async {
        // No ball.yaml but a pubspec.yaml + lib/ → encodes the package.
        File('${projDir.path}/pubspec.yaml').writeAsStringSync(
          'name: mypkg\nversion: 0.1.0\nenvironment:\n  sdk: ^3.0.0\n',
        );
        Directory('${projDir.path}/lib').createSync();
        File(
          '${projDir.path}/lib/m.dart',
        ).writeAsStringSync('int add(int a){return a+1;}\n');
        final (code, _, err) = await run(['publish']);
        expect(code, 0);
        expect(err, contains('Encoding Dart package from pubspec.yaml'));
        expect(
          File('${projDir.path}/lib/module.ball.bin').existsSync(),
          isTrue,
        );
      },
    );

    test('publish encodes the package when ball.yaml + lib/ exist', () async {
      await run(['init']);
      Directory('${projDir.path}/lib').createSync();
      File(
        '${projDir.path}/lib/m.dart',
      ).writeAsStringSync('int add(int a){return a+1;}\n');
      final (code, _, err) = await run(['publish']);
      expect(code, 0);
      expect(err, contains('Encoding Dart package'));
      expect(File('${projDir.path}/lib/module.ball.bin').existsSync(), isTrue);
      expect(File('${projDir.path}/lib/module.ball.json').existsSync(), isTrue);
    });
  });
}
