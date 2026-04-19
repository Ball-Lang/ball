/// Runs the Node-side `ts_emit.mjs` script, producing a TypeScript source
/// string from a [TsEmitPlan].
///
/// The script lives at `dart/compiler/tool/ts_emit.mjs`. Its dependencies
/// (notably `ts-morph`) are installed in `dart/compiler/tool/node_modules`
/// via a one-time `npm install`. If `node_modules` is missing, [runTsEmit]
/// will print guidance and throw.
library;

import 'dart:convert';
import 'dart:io';

import 'ts_emit_plan.dart';

/// Locate `dart/compiler/tool/` relative to the running Dart process.
/// Walks up from the current directory until it finds a repo marker.
String _findToolDir() {
  var dir = Directory.current;
  while (true) {
    final candidate = Directory('${dir.path}/dart/compiler/tool');
    if (candidate.existsSync() &&
        File('${candidate.path}/ts_emit.mjs').existsSync()) {
      return candidate.path.replaceAll('\\', '/');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'Could not locate dart/compiler/tool/ts_emit.mjs. Run from within '
        'the ball repository.',
      );
    }
    dir = parent;
  }
}

String _resolveToolDir({String? overridePath}) {
  if (overridePath != null) {
    if (!File('$overridePath/ts_emit.mjs').existsSync()) {
      throw StateError('ts_emit.mjs not found in $overridePath');
    }
    return overridePath;
  }
  return _findToolDir();
}

void _ensureNodeModules(String toolDir) {
  final nm = Directory('$toolDir/node_modules');
  if (!nm.existsSync()) {
    throw StateError(
      'node_modules missing under $toolDir. Run:\n'
      '  cd $toolDir && npm install',
    );
  }
}

/// Runs the emitter synchronously. Blocks the isolate for ~100-400ms
/// per invocation (Node startup + ts-morph work). Use [runTsEmitAsync]
/// from test harnesses that run many emits.
///
/// Passes the plan via a temp file (Process.runSync can't pipe stdin
/// directly). The temp file is deleted after the run.
String runTsEmit(TsEmitPlan plan, {String? toolDir}) {
  final dir = _resolveToolDir(overridePath: toolDir);
  _ensureNodeModules(dir);

  final tmp = File(
    '${Directory.systemTemp.path}/ts_emit_plan_${DateTime.now().microsecondsSinceEpoch}.json',
  );
  tmp.writeAsStringSync(plan.toJsonString());
  try {
    final result = Process.runSync(
      Platform.isWindows ? 'node.exe' : 'node',
      ['${dir}/ts_emit.mjs', '--plan-file', tmp.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      runInShell: true,
      workingDirectory: dir,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'ts_emit exited ${result.exitCode}\nstderr:\n${result.stderr}',
      );
    }
    return result.stdout as String;
  } finally {
    try {
      tmp.deleteSync();
    } catch (_) {/* ignore */}
  }
}

/// Runs the emitter asynchronously via stdin pipe. Preferred for
/// large plans or when called many times.
Future<String> runTsEmitAsync(TsEmitPlan plan, {String? toolDir}) async {
  final dir = _resolveToolDir(overridePath: toolDir);
  _ensureNodeModules(dir);

  final proc = await Process.start(
    Platform.isWindows ? 'node.exe' : 'node',
    ['${dir}/ts_emit.mjs'],
    runInShell: true,
    workingDirectory: dir,
  );
  proc.stdin.write(plan.toJsonString());
  await proc.stdin.close();

  final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
  final stderrFuture = proc.stderr.transform(utf8.decoder).join();
  final out = await stdoutFuture;
  final err = await stderrFuture;
  final exitCode = await proc.exitCode;
  if (exitCode != 0) {
    throw StateError('ts_emit exited $exitCode\nstderr:\n$err');
  }
  return out;
}
