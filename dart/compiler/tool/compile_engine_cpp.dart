/// Emit `dart/engine/lib/engine.dart` as C++ via the existing cpp
/// compiler (cpp/build/compiler/Debug/ball_cpp_compile.exe).
///
/// Writes:
///   - dart/self_host/engine.ball.pb (binary-encoded program, since
///     JSON exceeds protobuf's 100-nesting default)
///   - dart/self_host/lib/engine_rt.cpp (the emitted C++)
///
/// There is exactly ONE output shape, and it takes no flags. Issue #601
/// removed the multi-TU `--split`/`--shards` emit that used to be the DEFAULT
/// (and with it `--monolithic`, the flag that selected this path): that emit
/// had never compiled, yet `cpp/test/CMakeLists.txt` preferred its output
/// whenever it was present — so running this tool the documented way handed a
/// developer an engine that could not build, and every CI invocation opted out
/// of it.
///
/// Whether the emitted C++ actually compiles under MSVC/GCC/Clang is
/// a separate concern — this tool only runs the Ball → C++ emit.
///
///   dart run dart/compiler/tool/compile_engine_cpp.dart
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart' show encodeBallFileBinary;
import 'package:ball_encoder/encoder.dart';
import 'package:ball_encoder/parts_resolver.dart';

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

String _findCppCompiler(String root) {
  // Try every common build-tree layout (MSVC release, debug, POSIX).
  // We pick the most-recently-modified exe so freshly-rebuilt compilers
  // win over stale copies in older build trees.
  final candidates = [
    for (final dir in ['ci-build', 'build3', 'build2', 'build'])
      for (final cfg in ['Release', 'Debug', '']) ...[
        '$root/cpp/$dir/compiler/${cfg.isEmpty ? '' : '$cfg/'}ball_cpp_compile.exe',
        '$root/cpp/$dir/compiler/${cfg.isEmpty ? '' : '$cfg/'}ball_cpp_compile',
      ],
  ];
  String? best;
  DateTime? bestMtime;
  for (final p in candidates) {
    final f = File(p);
    if (!f.existsSync()) continue;
    final mtime = f.lastModifiedSync();
    if (bestMtime == null || mtime.isAfter(bestMtime)) {
      bestMtime = mtime;
      best = p;
    }
  }
  if (best != null) return best;
  throw StateError(
    'ball_cpp_compile not found. Build cpp/build first:\n'
    '  cmake -S cpp -B cpp/build && cmake --build cpp/build --target ball_cpp_compile',
  );
}

Future<void> main(List<String> args) async {
  // Fail loud on any argument. The removed `--monolithic` / `--split` /
  // `--shards` flags CHOSE between two emit shapes; silently ignoring one
  // would leave a caller believing it still selected something.
  if (args.isNotEmpty) {
    stderr.writeln(
      'compile_engine_cpp.dart takes no arguments (got: ${args.join(' ')}).\n'
      'The --monolithic / --split / --shards flags were removed together with '
      'the multi-TU emit in issue #601; there is one output shape, '
      'dart/self_host/lib/engine_rt.cpp.',
    );
    exit(64); // EX_USAGE
  }
  final root = _findRepoRoot();
  stdout.writeln('Compile engine.dart → C++ via existing cpp/compiler');
  stdout.writeln('=' * 60);

  final mainPath = '$root/dart/engine/lib/engine.dart';
  stdout.writeln('Resolving parts + extensions...');
  final src = resolveDartLibrary(mainPath);
  stdout.writeln('  merged source: ${src.length} bytes');
  stdout.writeln('Encoding...');
  final prog = DartEncoder().encode(src, name: 'engine');
  stdout.writeln(
    '  ${prog.modules.length} modules, '
    '${prog.modules.fold<int>(0, (n, m) => n + m.functions.length)} fns, '
    '${prog.modules.fold<int>(0, (n, m) => n + m.typeDefs.length)} typeDefs',
  );

  // Write as binary protobuf (JSON exceeds protobuf's 100-nesting
  // default for engine.dart's deeply nested expression trees).
  final outDir = Directory('$root/dart/self_host');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final pbPath = '${outDir.path}/engine.ball.pb';
  // Self-describing google.protobuf.Any envelope (like every other ball file),
  // so the C++ compiler reads it through the same Any loader.
  final pbBytes = encodeBallFileBinary(prog);
  File(pbPath).writeAsBytesSync(pbBytes);
  stdout.writeln(
    '  Wrote ${pbBytes.length} bytes → ${pbPath.replaceAll('\\', '/')}',
  );

  // Run the cpp compiler.
  final cppCompiler = _findCppCompiler(root);
  final outCpp = '$root/dart/self_host/lib/engine_rt.cpp';
  // Ensure the output directory exists — lib/ holds only generated
  // (gitignored) artifacts, so it is absent in a fresh checkout and the
  // C++ compiler would fail with "Could not open output file".
  File(outCpp).parent.createSync(recursive: true);
  stdout.writeln('\nRunning $cppCompiler ...');
  final result = await Process.run(cppCompiler, [
    pbPath,
    outCpp,
  ], runInShell: true);
  if (result.exitCode != 0) {
    stdout.writeln('! cpp compiler reported errors:');
    stdout.writeln(result.stderr);
    exit(result.exitCode);
  }
  stdout.writeln(result.stdout);
  final lines = File(outCpp).readAsLinesSync().length;
  stdout.writeln('✓ Emitted ${outCpp.replaceAll('\\', '/')} ($lines lines)');
  stdout.writeln(
    '\nNote: this tool only verifies the Ball → C++ emit step. '
    'Whether the emitted C++ compiles under MSVC/GCC/Clang requires '
    'a separate build step (see cpp/CMakeLists.txt).',
  );
}
