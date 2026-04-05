/// Generates website/lib/generated/examples.dart from:
///   - website/content/*.ball.yaml  (YAML display versions of Ball programs)
///   - examples/*/dart/*_compiled.dart  (real compiler output)
///   - examples/*/cpp/*_compiled.cpp    (real compiler output)
///
/// Run from repo root:
///   dart run website/tool/generate_examples.dart
///
/// Or from website/:
///   dart run tool/generate_examples.dart
library;

import 'dart:io';

/// Strips #include, // comments, and leading blank lines from C++ output.
String _cleanCompiledCpp(String raw) {
  final lines = raw.split('\n');
  final buf = <String>[];
  var pastIncludes = false;
  for (final line in lines) {
    if (!pastIncludes) {
      if (line.startsWith('#include') ||
          line.startsWith('//') ||
          line.trim().isEmpty) {
        continue;
      }
      pastIncludes = true;
    }
    buf.add(line);
  }
  while (buf.isNotEmpty && buf.last.trim().isEmpty) buf.removeLast();
  return buf.join('\n');
}

/// Strips leading comment lines (// ...) from compiled Dart output.
String _cleanCompiledDart(String raw) {
  final lines = raw.split('\n');
  final buf = <String>[];
  var pastComments = false;
  for (final line in lines) {
    if (!pastComments) {
      if (line.startsWith('//') || line.trim().isEmpty) continue;
      pastComments = true;
    }
    buf.add(line);
  }
  while (buf.isNotEmpty && buf.last.trim().isEmpty) buf.removeLast();
  return buf.join('\n');
}

void main() {
  var repoRoot = Directory.current;
  if (File('${repoRoot.path}/website/pubspec.yaml').existsSync()) {
    // Running from repo root
  } else if (File('${repoRoot.path}/pubspec.yaml').existsSync() &&
      repoRoot.path.endsWith('website')) {
    repoRoot = repoRoot.parent;
  } else {
    stderr.writeln('Error: Run from repo root or website/ directory.');
    exit(1);
  }

  final contentDir = '${repoRoot.path}/website/content';
  final examplesDir = '${repoRoot.path}/examples';
  final outputFile = File('${repoRoot.path}/website/lib/generated/examples.dart');

  // ── YAML display files ──────────────────────────────────────
  final helloWorldYaml =
      File('$contentDir/hello_world.ball.yaml').readAsStringSync().trimRight();
  final fibonacciYaml =
      File('$contentDir/fibonacci.ball.yaml').readAsStringSync().trimRight();
  final fibonacciFunctionYaml =
      File('$contentDir/fibonacci_function.ball.yaml').readAsStringSync().trimRight();

  // ── Compiled outputs (real compiler output) ─────────────────
  final helloWorldDart =
      File('$examplesDir/hello_world/dart/hello_world_compiled.dart').readAsStringSync();
  final helloWorldCpp =
      File('$examplesDir/hello_world/cpp/hello_world_compiled.cpp').readAsStringSync();
  final fibonacciDart =
      File('$examplesDir/fibonacci/dart/fibonacci_compiled.dart').readAsStringSync();
  final fibonacciCpp =
      File('$examplesDir/fibonacci/cpp/fibonacci_compiled.cpp').readAsStringSync();

  // ── Process ─────────────────────────────────────────────────
  final hwDartClean = _cleanCompiledDart(helloWorldDart);
  final hwCppClean = _cleanCompiledCpp(helloWorldCpp);
  final fibDartClean = _cleanCompiledDart(fibonacciDart);
  final fibCppClean = _cleanCompiledCpp(fibonacciCpp);

  String escape(String s) => s.replaceAll("'''", "' ' '");

  final buf = StringBuffer();
  buf.writeln('// GENERATED — do not edit. Run: dart run tool/generate_examples.dart');
  buf.writeln('// Source: website/content/ (YAML) + examples/ (compiled output)');
  buf.writeln('');

  void writeConst(String name, String doc, String value) {
    buf.writeln('/// $doc');
    buf.writeln("const $name = r'''");
    buf.writeln(escape(value));
    buf.writeln("''';");
    buf.writeln('');
  }

  // Hello World
  writeConst('helloWorldYaml', 'website/content/hello_world.ball.yaml', helloWorldYaml);
  writeConst('helloWorldDart', 'Compiled Dart (header stripped)', hwDartClean);
  writeConst('helloWorldCpp', 'Compiled C++ (includes stripped)', hwCppClean);

  // Fibonacci
  writeConst('fibonacciYaml', 'website/content/fibonacci.ball.yaml', fibonacciYaml);
  writeConst('fibonacciFunctionYaml',
      'website/content/fibonacci_function.ball.yaml (just the function)', fibonacciFunctionYaml);
  writeConst('fibonacciDart', 'Compiled Dart (header stripped)', fibDartClean);
  writeConst('fibonacciCpp', 'Compiled C++ (includes stripped)', fibCppClean);

  // Write
  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(buf.toString());
  print('Generated ${outputFile.path}');
  print('  helloWorldYaml: ${helloWorldYaml.length} chars');
  print('  helloWorldDart: ${hwDartClean.length} chars');
  print('  helloWorldCpp: ${hwCppClean.length} chars');
  print('  fibonacciYaml: ${fibonacciYaml.length} chars');
  print('  fibonacciFunctionYaml: ${fibonacciFunctionYaml.length} chars');
  print('  fibonacciDart: ${fibDartClean.length} chars');
  print('  fibonacciCpp: ${fibCppClean.length} chars');
}
