/// Emit `dart/engine/lib/engine.dart` as C++ via the existing cpp
/// compiler (cpp/build/compiler/Debug/ball_cpp_compile.exe).
///
/// Mirrors compile_engine_ts.dart. Writes two files:
///   - dart/self_host/engine.ball.pb (binary-encoded program, since
///     JSON exceeds protobuf's 100-nesting default)
///   - dart/self_host/lib/engine_rt.cpp (emitted C++)
///
/// Whether the emitted C++ actually compiles under MSVC/GCC/Clang is
/// a separate concern — this tool only runs the Ball → C++ emit.
///
///   dart run dart/compiler/tool/compile_engine_cpp.dart
library;

import 'dart:io';

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

String _findCppCompiler(String root) {
  // Debug build under MSVC.
  for (final p in [
    '$root/cpp/build/compiler/Debug/ball_cpp_compile.exe',
    '$root/cpp/build/compiler/Release/ball_cpp_compile.exe',
    '$root/cpp/build/compiler/ball_cpp_compile',
    '$root/cpp/build/compiler/ball_cpp_compile.exe',
  ]) {
    if (File(p).existsSync()) return p;
  }
  throw StateError(
    'ball_cpp_compile not found. Build cpp/build first:\n'
    '  cmake -S cpp -B cpp/build && cmake --build cpp/build --target ball_cpp_compile',
  );
}

Future<void> main(List<String> args) async {
  final root = _findRepoRoot();
  stdout.writeln('Compile engine.dart → C++ via existing cpp/compiler');
  stdout.writeln('=' * 60);

  final src = File('$root/dart/engine/lib/engine.dart').readAsStringSync();
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
  final outCpp = '$root/dart/self_host/lib/engine_rt.cpp';
  stdout.writeln('\nRunning $cppCompiler ...');
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
  stdout.writeln(
      '\nNote: this tool only verifies the Ball → C++ emit step. '
      'Whether the emitted C++ compiles under MSVC/GCC/Clang requires '
      'a separate build step (see cpp/CMakeLists.txt).');
}
