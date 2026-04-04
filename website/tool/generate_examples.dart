/// Generates website/lib/generated/examples.dart from real example files.
///
/// Sourced from examples/ directory — compiled outputs change when the
/// compiler changes, so this keeps the website in sync automatically.
///
/// Run from repo root:
///   dart run website/tool/generate_examples.dart
///
/// Or from website/:
///   dart run tool/generate_examples.dart
library;

import 'dart:convert';
import 'dart:io';

/// Strips the Ball std module boilerplate from a .ball.json,
/// keeping only the main module and program-level fields.
String _simplifyBallJson(String raw) {
  final parsed = jsonDecode(raw) as Map<String, dynamic>;
  final modules = (parsed['modules'] as List).cast<Map<String, dynamic>>();
  final mainModule =
      modules.firstWhere((m) => m['name'] == 'main', orElse: () => modules.last);
  final simplified = <String, dynamic>{
    'name': parsed['name'],
    'entryModule': parsed['entryModule'],
    'entryFunction': parsed['entryFunction'],
    'modules': [mainModule],
  };
  return const JsonEncoder.withIndent('  ').convert(simplified);
}

/// Strips the header comments and includes from compiled C++ output,
/// keeping only the function definitions for a cleaner display.
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
  // Remove trailing empty lines
  while (buf.isNotEmpty && buf.last.trim().isEmpty) {
    buf.removeLast();
  }
  return buf.join('\n');
}
void main() {
  // Resolve repo root: works from repo root or from website/
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

  final examplesDir = '${repoRoot.path}/examples';
  final outputFile = File('${repoRoot.path}/website/lib/generated/examples.dart');

  // Read source files
  final helloWorldJson =
      File('$examplesDir/hello_world/hello_world.ball.json').readAsStringSync();
  final helloWorldDart =
      File('$examplesDir/hello_world/dart/hello_world_compiled.dart').readAsStringSync();
  final helloWorldCpp =
      File('$examplesDir/hello_world/cpp/hello_world_compiled.cpp').readAsStringSync();
  final fibonacciJson =
      File('$examplesDir/fibonacci/fibonacci.ball.json').readAsStringSync();
  final fibonacciDart =
      File('$examplesDir/fibonacci/dart/fibonacci_compiled.dart').readAsStringSync();
  final fibonacciCpp =
      File('$examplesDir/fibonacci/cpp/fibonacci_compiled.cpp').readAsStringSync();
  final comprehensiveDart =
      File('$examplesDir/comprehensive/dart/comprehensive_compiled.dart').readAsStringSync();

  // Process
  final helloWorldSimplified = _simplifyBallJson(helloWorldJson);
  final fibonacciSimplified = _simplifyBallJson(fibonacciJson);
  final fibCppClean = _cleanCompiledCpp(fibonacciCpp);
  final hwCppClean = _cleanCompiledCpp(helloWorldCpp);
  // Take first ~60 lines of comprehensive Dart (enough to show classes, enums, etc.)
  final compDartLines = comprehensiveDart.split('\n');
  final compDartExcerpt =
      compDartLines.take(60).join('\n').trimRight() + '\n\n// ... (${compDartLines.length} lines total)';

  String escape(String s) => s.replaceAll("'''", "' ' '");

  final buf = StringBuffer();
  buf.writeln('// GENERATED — do not edit. Run: dart run tool/generate_examples.dart');
  buf.writeln('// Source: examples/ directory');
  buf.writeln('');

  void writeConst(String name, String doc, String value) {
    buf.writeln('/// $doc');
    buf.writeln("const $name = r'''");
    buf.writeln(escape(value));
    buf.writeln("''';");
    buf.writeln('');
  }

  // Hello World
  writeConst('helloWorldBallJson',
      'hello_world.ball.json (simplified: std stripped)', helloWorldSimplified);
  writeConst('helloWorldCompiledDart',
      'examples/hello_world/dart/hello_world_compiled.dart', helloWorldDart.trimRight());
  writeConst('helloWorldCompiledCpp',
      'examples/hello_world/cpp/hello_world_compiled.cpp (includes stripped)', hwCppClean);

  // Fibonacci
  writeConst('fibonacciBallJson',
      'fibonacci.ball.json (simplified: std stripped)', fibonacciSimplified);
  writeConst('fibonacciCompiledDart',
      'examples/fibonacci/dart/fibonacci_compiled.dart', fibonacciDart.trimRight());
  writeConst('fibonacciCompiledCpp',
      'examples/fibonacci/cpp/fibonacci_compiled.cpp (includes stripped)', fibCppClean);

  // Comprehensive (excerpt only — full file is 300+ lines)
  writeConst('comprehensiveCompiledDartExcerpt',
      'First ~60 lines of examples/comprehensive/dart/comprehensive_compiled.dart', compDartExcerpt);

  // Write
  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(buf.toString());
  print('Generated ${outputFile.path}');
  print('  helloWorldBallJson: ${helloWorldSimplified.length} chars');
  print('  helloWorldCompiledDart: ${helloWorldDart.trimRight().length} chars');
  print('  helloWorldCompiledCpp: ${hwCppClean.length} chars');
  print('  fibonacciBallJson: ${fibonacciSimplified.length} chars');
  print('  fibonacciCompiledDart: ${fibonacciDart.trimRight().length} chars');
  print('  fibonacciCompiledCpp: ${fibCppClean.length} chars');
  print('  comprehensiveCompiledDartExcerpt: ${compDartExcerpt.length} chars');
}
