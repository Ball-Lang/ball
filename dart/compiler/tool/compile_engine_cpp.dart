/// Emit `dart/engine/lib/engine.dart` as C++ via the existing cpp
/// compiler (cpp/build/compiler/Debug/ball_cpp_compile.exe).
///
/// Mirrors compile_engine_ts.dart. Writes:
///   - dart/self_host/engine.ball.pb (binary-encoded program, since
///     JSON exceeds protobuf's 100-nesting default)
///   - dart/self_host/lib/engine_rt/ (multi-TU emitted C++, default)
///     or dart/self_host/lib/engine_rt.cpp when --monolithic is passed
///
/// Whether the emitted C++ actually compiles under MSVC/GCC/Clang is
/// a separate concern — this tool only runs the Ball → C++ emit.
///
///   dart run dart/compiler/tool/compile_engine_cpp.dart
library;

import 'dart:io';

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
    for (final dir in ['build3', 'build2', 'build'])
      for (final cfg in ['Release', 'Debug', ''])
        '$root/cpp/$dir/compiler/${cfg.isEmpty ? '' : '$cfg/'}ball_cpp_compile.exe',
    for (final dir in ['build3', 'build2', 'build'])
      '$root/cpp/$dir/compiler/ball_cpp_compile',
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
  final monolithic = args.contains('--monolithic');
  var shardCount = 8;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--shards' && i + 1 < args.length) {
      shardCount = int.parse(args[i + 1]);
    }
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
  stdout.writeln('  ${prog.modules.length} modules, '
      '${prog.modules.fold<int>(0, (n, m) => n + m.functions.length)} fns, '
      '${prog.modules.fold<int>(0, (n, m) => n + m.typeDefs.length)} typeDefs');

  // Write as binary protobuf (JSON exceeds protobuf's 100-nesting
  // default for engine.dart's deeply nested expression trees).
  final outDir = Directory('$root/dart/self_host');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final pbPath = '${outDir.path}/engine.ball.pb';
  File(pbPath).writeAsBytesSync(prog.writeToBuffer());
  stdout.writeln(
      '  Wrote ${prog.writeToBuffer().length} bytes → ${pbPath.replaceAll('\\', '/')}');

  // Run the cpp compiler.
  final cppCompiler = _findCppCompiler(root);
  if (monolithic) {
    final outCpp = '$root/dart/self_host/lib/engine_rt.cpp';
    stdout.writeln('\nRunning $cppCompiler (monolithic) ...');
    final result = await Process.run(
      cppCompiler,
      [pbPath, outCpp],
      runInShell: true,
    );
    if (result.exitCode != 0) {
      stdout.writeln('! cpp compiler reported errors:');
      stdout.writeln(result.stderr);
      exit(result.exitCode);
    }
    stdout.writeln(result.stdout);
    final lines = File(outCpp).readAsLinesSync().length;
    stdout.writeln(
        '✓ Emitted ${outCpp.replaceAll('\\', '/')} ($lines lines)');
  } else {
    final outDir = '$root/dart/self_host/lib/engine_rt';
    Directory(outDir).createSync(recursive: true);
    stdout.writeln(
        '\nRunning $cppCompiler --split $outDir --shards $shardCount ...');
    final result = await Process.run(
      cppCompiler,
      [pbPath, '--split', outDir, '--shards', '$shardCount'],
      runInShell: true,
    );
    if (result.exitCode != 0) {
      stdout.writeln('! cpp compiler reported errors:');
      stdout.writeln(result.stderr);
      exit(result.exitCode);
    }
    stdout.writeln(result.stdout);
    final shards = Directory(outDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.cpp'))
        .length;
    stdout.writeln(
        '✓ Emitted $outDir ($shards shard .cpp files + engine_rt_common.hpp)');
  }
  stdout.writeln(
      '\nNote: this tool only verifies the Ball → C++ emit step. '
      'Whether the emitted C++ compiles under MSVC/GCC/Clang requires '
      'a separate build step (see cpp/CMakeLists.txt).');
}
