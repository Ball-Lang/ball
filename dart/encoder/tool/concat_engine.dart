/// Concatenates the split engine files into a single file for encoding.
///
/// The encoder doesn't handle `part`/`extension` yet, so this script
/// manually merges all engine parts back into one class body.
///
///   dart run dart/encoder/tool/concat_engine.dart
library;

import 'dart:io';

void main() {
  final repoRoot = _findRepoRoot();
  final libDir = '$repoRoot/dart/engine/lib';

  final mainFile = File('$libDir/engine.dart').readAsStringSync();
  final typesFile = File('$libDir/engine_types.dart').readAsStringSync();
  final invocationFile = File('$libDir/engine_invocation.dart').readAsStringSync();
  final evalFile = File('$libDir/engine_eval.dart').readAsStringSync();
  final controlFlowFile = File('$libDir/engine_control_flow.dart').readAsStringSync();
  final stdFile = File('$libDir/engine_std.dart').readAsStringSync();

  final buf = StringBuffer();

  // 1. Main file: library, imports, exports. Remove part directives.
  final mainLines = mainFile.split('\n');
  var insertedTypes = false;
  for (final line in mainLines) {
    if (line.startsWith("part '")) continue;
    buf.writeln(line);
    // Insert types after the last import/export, before class BallEngine
    if (!insertedTypes && line.startsWith('class BallEngine')) {
      // Oops, we already wrote the class line. Let me use a different approach.
    }
  }
  // This approach is fragile. Let me just rewrite properly.
  buf.clear();

  // Collect imports and class separately
  final imports = <String>[];
  final classLines = <String>[];
  var reachedClass = false;
  for (final line in mainLines) {
    if (line.startsWith("part '")) continue;
    if (line.startsWith('class BallEngine')) reachedClass = true;
    if (reachedClass) {
      classLines.add(line);
    } else {
      imports.add(line);
    }
  }

  // Write imports
  for (final line in imports) {
    buf.writeln(line);
  }

  // Insert types before the class
  buf.writeln();
  buf.writeln('// === from engine_types.dart ===');
  for (final line in typesFile.split('\n')) {
    if (line.startsWith("part of '")) continue;
    buf.writeln(line);
  }
  buf.writeln();

  // Write class
  for (final line in classLines) {
    buf.writeln(line);
  }

  // Remove the last closing brace of BallEngine class.
  var content = buf.toString().trimRight();
  if (content.endsWith('}')) {
    content = content.substring(0, content.length - 1);
  }
  buf.clear();
  buf.write(content);
  buf.writeln();

  // 2. Extract and merge extension methods into BallEngine class body.
  // Also collect top-level declarations from each file.
  final topLevel = StringBuffer();
  final seenHelpers = <String>{};

  for (final entry in [
    ('engine_invocation.dart', invocationFile),
    ('engine_eval.dart', evalFile),
    ('engine_control_flow.dart', controlFlowFile),
    ('engine_std.dart', stdFile),
  ]) {
    final (name, source) = entry;
    buf.writeln();
    buf.writeln('  // === from $name ===');

    final extensionBody = _extractExtensionBody(source);
    final outsideExtension = _extractOutsideExtension(source);

    // Deduplicate helper methods (_asMap, _asList, _cfAsMap, etc.)
    for (final line in extensionBody.split('\n')) {
      final trimmed = line.trimLeft();
      if (_isHelperDecl(trimmed)) {
        final helperName = RegExp(r'(\w+)\(').firstMatch(trimmed)?.group(1);
        if (helperName != null && seenHelpers.contains(helperName)) {
          // Skip this duplicate — consume until closing brace
          continue;
        }
        if (helperName != null) seenHelpers.add(helperName);
      }
      buf.writeln(line);
    }

    if (outsideExtension.trim().isNotEmpty) {
      topLevel.writeln();
      topLevel.writeln('// === top-level from $name ===');
      topLevel.writeln(outsideExtension);
    }
  }

  // 3. Close BallEngine class.
  buf.writeln('}');

  // 4. Add top-level declarations from extension files.
  buf.write(topLevel.toString());

  final outPath = '$libDir/engine_full.dart';
  File(outPath).writeAsStringSync(buf.toString());
  stderr.writeln('Wrote ${outPath.replaceAll('\\', '/')} (${buf.length} chars)');
}

/// Extract the body of `extension ... on BallEngine { ... }`.
String _extractExtensionBody(String source) {
  final lines = source.split('\n');
  final buf = StringBuffer();
  var inExtension = false;
  var braceDepth = 0;

  for (final line in lines) {
    if (!inExtension) {
      if (line.contains('extension ') && line.contains(' on BallEngine {')) {
        inExtension = true;
        braceDepth = 1;
        continue;
      }
      continue;
    }

    // Count braces
    for (var c = 0; c < line.length; c++) {
      if (line[c] == '{') braceDepth++;
      if (line[c] == '}') braceDepth--;
    }

    if (braceDepth <= 0) {
      inExtension = false;
      continue;
    }

    buf.writeln(line);
  }
  return buf.toString();
}

/// Extract content outside the extension block (top-level consts, functions).
String _extractOutsideExtension(String source) {
  final lines = source.split('\n');
  final buf = StringBuffer();
  var inExtension = false;
  var braceDepth = 0;

  for (final line in lines) {
    if (line.startsWith("part of '")) continue;

    if (!inExtension) {
      if (line.contains('extension ') && line.contains(' on BallEngine {')) {
        inExtension = true;
        braceDepth = 1;
        continue;
      }
      buf.writeln(line);
      continue;
    }

    for (var c = 0; c < line.length; c++) {
      if (line[c] == '{') braceDepth++;
      if (line[c] == '}') braceDepth--;
    }

    if (braceDepth <= 0) {
      inExtension = false;
    }
  }
  return buf.toString();
}

bool _isHelperDecl(String trimmed) {
  return trimmed.startsWith('Map<String, Object?>? _asMap(') ||
      trimmed.startsWith('Map<String, Object?>? _cfAsMap(') ||
      trimmed.startsWith('Map<String, Object?>? _stdAsMap(') ||
      trimmed.startsWith('List<Object?>? _asList(') ||
      trimmed.startsWith('List<Object?>? _stdAsList(');
}

String _findRepoRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/CLAUDE.md').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Cannot find repo root (no CLAUDE.md)');
    }
    dir = parent;
  }
  return dir.path;
}
