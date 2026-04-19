/// Thin Dart wrapper over the `@ball-lang/compiler` npm package.
///
/// The canonical TS compiler now lives in `ts/compiler/` (TypeScript,
/// using ts-morph in-process). This wrapper lets Dart callers invoke
/// it without changing their existing API surface — it shells out to
/// `node ts/compiler/bin/ball-ts-compile.mjs`.
///
/// Requires Node.js 22+ on PATH and `npm install` already run under
/// `ts/compiler/`.
///
/// The legacy Dart-side implementation (~2100 LOC) was removed in
/// Phase 2.9e. If you need to extend TS emission, edit
/// `ts/compiler/src/compiler.ts` and rebuild with `npm run build`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';

/// Compiles a Ball [Program] to TypeScript source by delegating to
/// the TS-native `@ball-lang/compiler` package.
class TsCompiler {
  final Program program;
  TsCompiler(this.program);

  /// Compile the program, returning the emitted TS source **without**
  /// the runtime preamble. Synchronous — blocks on the Node subprocess.
  /// Consumers that need the preamble prefix with [tsRuntimePreamble].
  String compile() {
    return _runTsCompile(program, includePreamble: false);
  }

  /// Async variant. Functionally identical to [compile] but uses
  /// [Process.run] instead of [Process.runSync]. Prefer this when
  /// compiling large programs (Node startup is ~300ms each).
  Future<String> compileStructural() async {
    return _runTsCompile(program, includePreamble: false);
  }
}

/// The TypeScript runtime preamble — helper functions every emitted
/// program needs. Lazily loaded from the TS side on first access.
String get tsRuntimePreamble {
  _cachedPreamble ??= _runTsCompile(
    Program()
      ..name = '__preamble__'
      ..version = '0.0.0'
      ..entryModule = '__preamble__'
      ..entryFunction = '__noop__'
      ..modules.add(
        Module()
          ..name = '__preamble__'
          ..functions.add(
            FunctionDefinition()
              ..name = '__noop__'
              ..isBase = false,
          ),
      ),
    includePreamble: true,
    preambleOnly: true,
  );
  return _cachedPreamble!;
}

String? _cachedPreamble;

String _runTsCompile(
  Program program, {
  required bool includePreamble,
  bool preambleOnly = false,
}) {
  final toolDir = _findToolDir();
  _ensureNodeModules(toolDir);

  // Write program JSON to a temp file (Process.runSync can't pipe stdin
  // portably on Windows).
  final tmpIn = File(
    '${Directory.systemTemp.path}/ball_ts_in_${DateTime.now().microsecondsSinceEpoch}.ball.json',
  );
  final tmpOut = File(
    '${Directory.systemTemp.path}/ball_ts_out_${DateTime.now().microsecondsSinceEpoch}.ts',
  );
  tmpIn.writeAsStringSync(jsonEncode(program.toProto3Json()));
  try {
    final args = [
      '${toolDir}/bin/ball-ts-compile.mjs',
      tmpIn.path,
      '--out',
      tmpOut.path,
      if (!includePreamble) '--no-preamble',
    ];
    final result = Process.runSync(
      Platform.isWindows ? 'node.exe' : 'node',
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'ball-ts-compile exited ${result.exitCode}\n'
        'stderr:\n${result.stderr}',
      );
    }
    final fullTs = tmpOut.readAsStringSync();
    if (preambleOnly) {
      // Extract just the preamble block: find the closing `})();` of
      // the `installBallPolyfills` IIFE, which is always the last
      // preamble line before any compiled user code.
      final installIdx = fullTs.indexOf('installBallPolyfills');
      if (installIdx < 0) return fullTs;
      final closingIdx = fullTs.indexOf('})();', installIdx);
      if (closingIdx < 0) return fullTs;
      final preambleEnd = fullTs.indexOf('\n', closingIdx);
      return fullTs.substring(0, preambleEnd < 0 ? fullTs.length : preambleEnd);
    }
    return fullTs;
  } finally {
    try { tmpIn.deleteSync(); } catch (_) {}
    try { tmpOut.deleteSync(); } catch (_) {}
  }
}

String _findToolDir() {
  var dir = Directory.current;
  while (true) {
    final candidate = Directory('${dir.path}/ts/compiler');
    if (candidate.existsSync() &&
        File('${candidate.path}/bin/ball-ts-compile.mjs').existsSync()) {
      return candidate.path.replaceAll('\\', '/');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'Could not locate ts/compiler/ (checked up from ${Directory.current.path}). '
        'The @ball-lang/compiler package must be present.',
      );
    }
    dir = parent;
  }
}

void _ensureNodeModules(String toolDir) {
  if (!Directory('$toolDir/node_modules').existsSync()) {
    throw StateError(
      'node_modules missing under $toolDir. Run:\n'
      '  cd $toolDir && npm install',
    );
  }
  // Also ensure `dist/` exists — the CLI imports from dist/index.js.
  if (!Directory('$toolDir/dist').existsSync()) {
    throw StateError(
      'dist/ missing under $toolDir. Run:\n'
      '  cd $toolDir && npm run build',
    );
  }
}
