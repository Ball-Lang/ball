/// Generates website/lib/generated/examples.dart from:
///   - examples/*/*.ball.json  (real Ball programs → auto-converted to YAML)
///   - examples/*/dart/*_compiled.dart  (real compiler output)
///   - examples/*/cpp/*_compiled.cpp    (real compiler output)
///
/// The JSON→YAML conversion strips the `std` module (boilerplate) and shows
/// only the `main` module content for readability.
///
/// Run from repo root:
///   dart run website/tool/generate_examples.dart
///
/// Or from website/:
///   dart run tool/generate_examples.dart
library;

import 'dart:convert';
import 'dart:io';

// ── JSON → YAML converter ─────────────────────────────────────

/// Converts a JSON value to YAML with the given indentation depth.
String _toYaml(Object? value, {int indent = 0, bool inlineKey = false}) {
  final prefix = '  ' * indent;
  if (value == null) return 'null';
  if (value is bool) return value.toString();
  if (value is num) return value.toString();
  if (value is String) {
    // Use quotes if the string contains special chars, is empty, or looks like
    // a number/bool/null
    if (value.isEmpty ||
        value.contains(':') ||
        value.contains('#') ||
        value.contains('\n') ||
        value.contains('"') ||
        value.contains("'") ||
        value == 'true' ||
        value == 'false' ||
        value == 'null' ||
        num.tryParse(value) != null) {
      return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n')}"';
    }
    return value;
  }
  if (value is List) {
    if (value.isEmpty) return '[]';
    final buf = StringBuffer();
    for (final item in value) {
      if (item is Map<String, dynamic> || item is List) {
        buf.writeln('$prefix-');
        buf.write(_toYaml(item, indent: indent + 1));
      } else {
        buf.writeln('$prefix- ${_toYaml(item, indent: indent + 1)}');
      }
    }
    return buf.toString().trimRight();
  }
  if (value is Map<String, dynamic>) {
    if (value.isEmpty) return '{}';
    // Compact single-field maps with simple values on one line: { key: value }
    if (value.length == 1) {
      final k = value.keys.first;
      final v = value.values.first;
      if (v is String || v is num || v is bool) {
        final compact = '{ $k: ${_toYaml(v)} }';
        if (compact.length < 60) {
          return inlineKey ? compact : '$prefix$compact';
        }
      }
    }
    final buf = StringBuffer();
    for (final entry in value.entries) {
      final k = entry.key;
      final v = entry.value;
      if (v is Map<String, dynamic> || v is List) {
        buf.writeln('$prefix$k:');
        buf.write(_toYaml(v, indent: indent + 1));
        if (!buf.toString().endsWith('\n')) buf.writeln();
      } else {
        buf.writeln('$prefix$k: ${_toYaml(v)}');
      }
    }
    return buf.toString().trimRight();
  }
  return value.toString();
}

/// Loads a Ball JSON program, strips the `std` module (boilerplate), and
/// converts to YAML for display.
String _ballJsonToYaml(String jsonContent) {
  final data = jsonDecode(jsonContent) as Map<String, dynamic>;
  // Strip std module — keep only non-std modules
  if (data.containsKey('modules')) {
    final modules = data['modules'] as List<dynamic>;
    data['modules'] =
        modules.where((m) => (m as Map<String, dynamic>)['name'] != 'std').toList();
  }
  // Remove version field if present (noise)
  data.remove('version');
  // Remove empty entryModule/entryFunction defaults
  return _toYaml(data).trimRight();
}

/// Extracts a specific function definition from a Ball JSON module as YAML.
String _extractFunctionYaml(String jsonContent, String functionName) {
  final data = jsonDecode(jsonContent) as Map<String, dynamic>;
  final modules = data['modules'] as List<dynamic>;
  for (final mod in modules) {
    final m = mod as Map<String, dynamic>;
    if (m['name'] == 'std') continue;
    final functions = m['functions'] as List<dynamic>? ?? [];
    for (final fn in functions) {
      final f = fn as Map<String, dynamic>;
      if (f['name'] == functionName) {
        return _toYaml(f).trimRight();
      }
    }
  }
  throw ArgumentError('Function $functionName not found');
}

// ── Output cleaners ───────────────────────────────────────────

/// Strips #include, using namespace, // comments, and leading blank lines.
String _cleanCompiledCpp(String raw) {
  final lines = raw.split('\n');
  final buf = <String>[];
  var pastIncludes = false;
  for (final line in lines) {
    if (!pastIncludes) {
      if (line.startsWith('#include') ||
          line.startsWith('using namespace') ||
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

// ── Main ──────────────────────────────────────────────────────

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

  final examplesDir = '${repoRoot.path}/examples';
  final outputFile = File('${repoRoot.path}/website/lib/generated/examples.dart');

  // ── Read real Ball JSON programs ────────────────────────────
  final helloWorldJson =
      File('$examplesDir/hello_world/hello_world.ball.json').readAsStringSync();
  final fibonacciJson =
      File('$examplesDir/fibonacci/fibonacci.ball.json').readAsStringSync();

  // ── Convert to YAML (auto-stripping std module) ─────────────
  final helloWorldYaml = _ballJsonToYaml(helloWorldJson);
  final fibonacciYaml = _ballJsonToYaml(fibonacciJson);
  final fibonacciFunctionYaml = _extractFunctionYaml(fibonacciJson, 'fibonacci');

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
  buf.writeln('// Source: examples/*.ball.json (auto-converted to YAML) + compiled output');
  buf.writeln('');

  void writeConst(String name, String doc, String value) {
    buf.writeln('/// $doc');
    buf.writeln("const $name = r'''");
    buf.writeln(escape(value));
    buf.writeln("''';");
    buf.writeln('');
  }

  // Hello World
  writeConst('helloWorldYaml', 'Auto-generated YAML from hello_world.ball.json (std stripped)', helloWorldYaml);
  writeConst('helloWorldDart', 'Compiled Dart (header stripped)', hwDartClean);
  writeConst('helloWorldCpp', 'Compiled C++ (includes stripped)', hwCppClean);

  // Fibonacci
  writeConst('fibonacciYaml', 'Auto-generated YAML from fibonacci.ball.json (std stripped)', fibonacciYaml);
  writeConst('fibonacciFunctionYaml',
      'Auto-extracted fibonacci function as YAML', fibonacciFunctionYaml);
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
