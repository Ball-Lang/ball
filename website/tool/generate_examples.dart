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
  final fibonacciJson =
      File('$examplesDir/fibonacci/fibonacci.ball.json').readAsStringSync();
  final fibonacciDart =
      File('$examplesDir/fibonacci/dart/fibonacci_compiled.dart').readAsStringSync();
  final fibonacciCpp =
      File('$examplesDir/fibonacci/cpp/fibonacci_compiled.cpp').readAsStringSync();

  // Process
  final helloWorldSimplified = _simplifyBallJson(helloWorldJson);
  final fibonacciSimplified = _simplifyBallJson(fibonacciJson);
  final fibCppClean = _cleanCompiledCpp(fibonacciCpp);

  // Escape for Dart raw string literals (triple-quoted)
  // Only need to escape the closing triple-quote sequence
  String escape(String s) => s.replaceAll("'''", "' ' '");

  // Generate output
  final buf = StringBuffer();
  buf.writeln('// GENERATED — do not edit. Run: dart run tool/generate_examples.dart');
  buf.writeln('// Source: examples/ directory');
  buf.writeln('');

  buf.writeln("/// hello_world.ball.json (simplified: main module only, std stripped)");
  buf.writeln("const helloWorldBallJson = r'''");
  buf.writeln(escape(helloWorldSimplified));
  buf.writeln("''';");
  buf.writeln('');

  buf.writeln("/// fibonacci.ball.json (simplified: main module only, std stripped)");
  buf.writeln("const fibonacciBallJson = r'''");
  buf.writeln(escape(fibonacciSimplified));
  buf.writeln("''';");
  buf.writeln('');

  buf.writeln("/// Dart compiled output from examples/fibonacci/dart/fibonacci_compiled.dart");
  buf.writeln("const fibonacciCompiledDart = r'''");
  buf.writeln(escape(fibonacciDart.trimRight()));
  buf.writeln("''';");
  buf.writeln('');

  buf.writeln("/// C++ compiled output (includes stripped) from");
  buf.writeln("/// examples/fibonacci/cpp/fibonacci_compiled.cpp");
  buf.writeln("const fibonacciCompiledCpp = r'''");
  buf.writeln(escape(fibCppClean));
  buf.writeln("''';");
  buf.writeln('');

  // Write
  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(buf.toString());
  print('Generated ${outputFile.path}');
  print('  helloWorldBallJson: ${helloWorldSimplified.length} chars');
  print('  fibonacciBallJson: ${fibonacciSimplified.length} chars');
  print('  fibonacciCompiledDart: ${fibonacciDart.trimRight().length} chars');
  print('  fibonacciCompiledCpp: ${fibCppClean.length} chars');
}
