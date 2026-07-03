/// Compile ball_protobuf to C++ by expanding the Module facade into a
/// Program and running it through the C++ compiler.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart' show encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:fixnum/fixnum.dart';

void main() {
  final repoRoot = _findRepoRoot();
  final facadeJson =
      jsonDecode(
            File('$repoRoot/dart/shared/ball_protobuf.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  // Remove @type wrapper for proto3 deserialization
  facadeJson.remove('@type');
  final facade = Module()..mergeFromProto3Json(facadeJson);

  // Extract inline modules from moduleImports
  final modules = <Module>[];
  for (final imp in facade.moduleImports) {
    if (imp.inline.hasJson()) {
      final modJson = jsonDecode(imp.inline.json);
      final m = Module()..mergeFromProto3Json(modJson);
      modules.add(m);
    }
  }

  stdout.writeln('Extracted ${modules.length} inline modules from facade');
  stdout.writeln(
    'Total functions: ${modules.fold<int>(0, (n, m) => n + m.functions.length)}',
  );

  // Compile to C++ using the Ball C++ compiler in library mode.
  // The --library flag tells the compiler to accept a Module (not a Program),
  // expand its InlineSource sub-modules, and emit a header-only library in a
  // named namespace (no main() function).
  final compilerExe = _findCppCompiler(repoRoot);
  if (compilerExe == null) {
    stderr.writeln('C++ compiler not found. Build it first:');
    stderr.writeln('  cd cpp && cmake -B build && cmake --build build');
    exit(1);
  }

  final facadePath = '$repoRoot/dart/shared/ball_protobuf.json';
  final outCpp = '$repoRoot/cpp/shared/ball_protobuf_rt.h';
  stdout.writeln('Compiling to C++ library via $compilerExe --library...');
  final result = Process.runSync(compilerExe, [
    facadePath,
    '--library',
    '--ns',
    'ball_protobuf',
    '--out',
    outCpp,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln('C++ library compilation failed (exit ${result.exitCode}):');
    stderr.writeln(result.stderr);
    // Fallback: wrap in a Program and compile the old way
    stderr.writeln('Falling back to Program-wrapping approach...');

    final mainModule = Module()
      ..name = 'main'
      ..functions.add(
        FunctionDefinition()
          ..name = 'main'
          ..body = (Expression()..literal = (Literal()..intValue = Int64(0))),
      );

    final program = Program()
      ..name = 'ball_protobuf'
      ..version = '1.0.0'
      ..entryModule = 'main'
      ..entryFunction = 'main'
      ..modules.add(mainModule)
      ..modules.addAll(modules);

    final outPath = '$repoRoot/dart/shared/ball_protobuf_program.json';
    final outJson = encodeBallFileJson(program);
    File(
      outPath,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(outJson));
    stdout.writeln('Wrote $outPath (${File(outPath).lengthSync()} bytes)');

    final outCppFallback = '$repoRoot/cpp/shared/ball_protobuf_rt.cpp';
    final result2 = Process.runSync(compilerExe, [
      outPath,
      '--out',
      outCppFallback,
    ]);
    if (result2.exitCode != 0) {
      stderr.writeln('Fallback also failed:');
      stderr.writeln(result2.stderr);
      exit(2);
    }
    stdout.writeln('Wrote $outCppFallback (fallback mode)');
  } else {
    stdout.writeln('Wrote $outCpp (namespace: ball_protobuf)');
    if ((result.stderr as String).isNotEmpty) {
      stderr.write(result.stderr);
    }
  }
}

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

String? _findCppCompiler(String repoRoot) {
  final candidates = [
    '$repoRoot/cpp/build/compiler/Debug/ball_cpp_compile.exe',
    '$repoRoot/cpp/build/compiler/Release/ball_cpp_compile.exe',
    '$repoRoot/cpp/build/compiler/ball_cpp_compile',
    '$repoRoot/cpp/build-wsl/compiler/ball_cpp_compile',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}
