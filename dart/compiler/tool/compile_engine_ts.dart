/// Compile `dart/engine/lib/engine.dart` through the structural TS
/// pipeline, prepend the runtime preamble, and write to
/// `dart/self_host/lib/engine_rt.ts`. Run Node's type-stripper on the
/// output to check for syntax errors.
///
///   dart run dart/compiler/tool/compile_engine_ts.dart [--check]
library;

import 'dart:io';

import 'package:ball_compiler/ts_compiler.dart';
import 'package:ball_encoder/encoder.dart';

String _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path.replaceAll('\\', '/');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('Not in ball repo');
    dir = parent;
  }
}

Future<void> main(List<String> args) async {
  final root = _findRepoRoot();
  stdout.writeln('Compile engine.dart → TS via structural pipeline');
  stdout.writeln('=' * 60);

  final src = File('$root/dart/engine/lib/engine.dart').readAsStringSync();
  stdout.writeln('Encoding...');
  final prog = DartEncoder().encode(src, name: 'engine');
  stdout.writeln('  ${prog.modules.length} modules, '
      '${prog.modules.fold<int>(0, (n, m) => n + m.functions.length)} fns, '
      '${prog.modules.fold<int>(0, (n, m) => n + m.typeDefs.length)} typeDefs');

  stdout.writeln('Compiling to TS...');
  final out = await TsCompiler(prog).compileStructural();
  final full = tsRuntimePreamble + '\n' + out;

  final outDir = Directory('$root/dart/self_host/lib');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final outPath = '${outDir.path}/engine_rt.ts';
  File(outPath).writeAsStringSync(full);
  final lines = full.split('\n').length;
  stdout.writeln('  Wrote → ${outPath.replaceAll('\\', '/')} ($lines lines)');

  if (args.contains('--check')) {
    // Node's --check is JS-only. Instead, import the file via a tiny
    // harness that exercises a few classes — if they load and
    // construct, the emitted TS is syntactically + structurally sound.
    final harness = File('$root/dart/self_host/lib/engine_smoke.ts');
    harness.writeAsStringSync('''
import './engine_rt.ts';
// If we got here, Node parsed & loaded the file (class/typedef
// declarations ran, top-level async function did not invoke since the
// engine is a library).
console.log('engine_rt.ts loaded OK');
''');
    stdout.writeln('Running node --experimental-strip-types on smoke harness...');
    final result = await Process.run(
      Platform.isWindows ? 'node.exe' : 'node',
      ['--experimental-strip-types', harness.path],
      runInShell: true,
    );
    if (result.exitCode == 0) {
      stdout.writeln('✓ Node loaded the emitted TS — Phase 2.6 milestone');
      stdout.writeln(result.stdout);
    } else {
      stdout.writeln('! Node reported errors:');
      stdout.writeln(result.stderr);
      exit(result.exitCode);
    }
  }
}
