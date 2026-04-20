/// Quick TS compiler runner for iterative debugging. Reads a ball.json
/// and prints the emitted TypeScript by shelling out to the canonical
/// @ball-lang/compiler (ts/compiler/bin/ball-ts-compile.mjs).
library;

import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: compile_ts <path/to/file.ball.json>');
    exit(1);
  }

  var dir = Directory.current;
  String? cli;
  while (true) {
    final candidate = File('${dir.path}/ts/compiler/bin/ball-ts-compile.mjs');
    if (candidate.existsSync()) {
      cli = candidate.absolute.path;
      break;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln('Could not find ts/compiler/bin/ball-ts-compile.mjs');
      exit(2);
    }
    dir = parent;
  }

  final result = Process.runSync(
    Platform.isWindows ? 'node.exe' : 'node',
    [cli!, args.first],
  );
  stdout.write(result.stdout);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    exit(result.exitCode);
  }
}
