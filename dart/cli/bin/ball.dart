/// Ball CLI — inspect, validate, compile, encode, and run ball programs.
///
/// Usage:
///   ball info     `<input.ball.json>`   — inspect ball program structure
///   ball validate `<input.ball.json>`   — check ball program validity
///   ball compile  `<input.ball.json>`   — compile ball program to Dart source
///   ball encode   `<input.dart>`        — encode Dart source to ball program
///   ball run      `<input.ball.json>`   — execute ball program
///   ball round-trip `<input.dart>`      — encode → compile → show diff
///   ball version                        — print version
///
/// Examples:
///   dart run ball_cli:ball info examples/hello_world.ball.json
///   dart run ball_cli:ball compile examples/hello_world.ball.json --output out.dart
///   dart run ball_cli:ball compile examples/hello_world.ball.json --no-format
///   dart run ball_cli:ball encode my_app.dart --output my_app.ball.json
///   dart run ball_cli:ball run examples/hello_world.ball.json
///   dart run ball_cli:ball round-trip my_app.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/capability_analyzer.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:ball_resolver/ball_resolver.dart';

const _version = '0.1.0';

void main(List<String> args) {
  if (args.isEmpty) {
    _printUsage();
    exit(1);
  }

  final command = args[0];
  final rest = args.sublist(1);

  switch (command) {
    case 'info':
      _info(rest);
    case 'validate':
      _validate(rest);
    case 'compile':
      _compile(rest);
    case 'encode':
      _encode(rest);
    case 'run':
      _run(rest);
    case 'round-trip':
      _roundTrip(rest);
    case 'audit':
      _audit(rest);
    case 'build':
      _build(rest);
    case 'version':
    case '--version':
    case '-v':
      stdout.writeln('ball $_version');
    case 'help':
    case '--help':
    case '-h':
      _printUsage();
    default:
      stderr.writeln('Unknown command: $command');
      _printUsage();
      exit(1);
  }
}

void _printUsage() {
  stderr.writeln('Ball Language CLI v$_version');
  stderr.writeln();
  stderr.writeln('Usage: ball <command> [arguments]');
  stderr.writeln();
  stderr.writeln('Commands:');
  stderr.writeln(
    '  info     <input.ball.json>   Inspect ball program structure',
  );
  stderr.writeln('  validate <input.ball.json>   Check ball program validity');
  stderr.writeln(
    '  compile  <input.ball.json>   Compile ball program to Dart source',
  );
  stderr.writeln(
    '  encode   <input.dart>        Encode Dart source to ball program',
  );
  stderr.writeln('  run      <input.ball.json>   Execute ball program');
  stderr.writeln('  round-trip <input.dart>      Encode → compile → show diff');
  stderr.writeln('  audit    <input.ball.json>   Static capability analysis');
  stderr.writeln('  build    <input.ball.json>   Resolve imports → self-contained program');
  stderr.writeln('  version                      Print version');
  stderr.writeln('  help                         Show this help');
  stderr.writeln();
  stderr.writeln('Options:');
  stderr.writeln(
    '  --output <file>              Output file (default: stdout)',
  );
  stderr.writeln(
    '  --format <json|binary>       Output format for encode (default: json)',
  );
  stderr.writeln(
    '  --no-format                  Skip dart_style formatting (compile only)',
  );
}

// ── info ─────────────────────────────────────────────────

void _info(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: ball info <input.ball.json>');
    exit(1);
  }

  final program = _loadProgram(args[0]);

  stdout.writeln('Program: ${program.name} v${program.version}');
  stdout.writeln('Entry:   ${program.entryModule}.${program.entryFunction}');
  stdout.writeln('Modules: ${program.modules.length}');
  stdout.writeln();

  for (final module in program.modules) {
    final isBase = module.functions.every((f) => f.isBase);
    stdout.writeln('  ${module.name}${isBase ? " (base)" : ""}');
    if (module.types.isNotEmpty) {
      stdout.writeln('    types:     ${module.types.length}');
    }
    if (module.typeDefs.isNotEmpty) {
      stdout.writeln('    typeDefs:  ${module.typeDefs.length}');
    }
    if (module.typeAliases.isNotEmpty) {
      stdout.writeln('    aliases:   ${module.typeAliases.length}');
    }
    if (module.enums.isNotEmpty) {
      stdout.writeln('    enums:     ${module.enums.length}');
    }
    stdout.writeln('    functions: ${module.functions.length}');
    if (module.description.isNotEmpty) {
      stdout.writeln('    desc:      ${module.description}');
    }
  }
}

// ── validate ─────────────────────────────────────────────

void _validate(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: ball validate <input.ball.json>');
    exit(1);
  }

  final program = _loadProgram(args[0]);
  final errors = <String>[];

  // Check entry point
  if (program.entryModule.isEmpty) {
    errors.add('Missing entry_module');
  }
  if (program.entryFunction.isEmpty) {
    errors.add('Missing entry_function');
  }

  // Check that entry function exists
  if (program.entryModule.isNotEmpty && program.entryFunction.isNotEmpty) {
    final entryMod = program.modules
        .where((m) => m.name == program.entryModule)
        .firstOrNull;
    if (entryMod == null) {
      errors.add('Entry module "${program.entryModule}" not found in modules');
    } else {
      final entryFunc = entryMod.functions
          .where((f) => f.name == program.entryFunction)
          .firstOrNull;
      if (entryFunc == null) {
        errors.add(
          'Entry function "${program.entryFunction}" not found '
          'in module "${program.entryModule}"',
        );
      }
    }
  }

  // Check modules have names
  for (var i = 0; i < program.modules.length; i++) {
    final m = program.modules[i];
    if (m.name.isEmpty) {
      errors.add('Module at index $i has no name');
    }
  }

  // Check for duplicate module names
  final moduleNames = <String>{};
  for (final m in program.modules) {
    if (m.name.isNotEmpty && !moduleNames.add(m.name)) {
      errors.add('Duplicate module name: "${m.name}"');
    }
  }

  // Check functions reference known modules in calls
  // (lightweight — just checks non-base functions have bodies)
  for (final m in program.modules) {
    for (final f in m.functions) {
      if (!f.isBase && !f.hasBody() && !f.hasMetadata()) {
        errors.add(
          '${m.name}.${f.name}: non-base function with no body or metadata',
        );
      }
    }
  }

  if (errors.isEmpty) {
    stdout.writeln('Valid: "${program.name}" v${program.version}');
    stdout.writeln(
      '  ${program.modules.length} modules, '
      '${program.modules.fold<int>(0, (s, m) => s + m.functions.length)} functions',
    );
  } else {
    stderr.writeln('Invalid: ${errors.length} error(s) found');
    for (final e in errors) {
      stderr.writeln('  - $e');
    }
    exit(1);
  }
}

// ── helpers ──────────────────────────────────────────────

String _parseOption(List<String> args, String name) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--$name') return args[i + 1];
  }
  return '';
}

List<String> _positionalArgs(List<String> args) {
  final result = <String>[];
  var skip = false;
  for (final arg in args) {
    if (skip) {
      skip = false;
      continue;
    }
    if (arg.startsWith('--')) {
      skip = true;
      continue;
    }
    result.add(arg);
  }
  return result;
}

// ── compile ──────────────────────────────────────────────

void _compile(List<String> args) {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: ball compile <input.ball.json> [--output <file>] [--no-format]',
    );
    exit(1);
  }

  final noFormat = args.contains('--no-format');
  final program = _loadProgram(positional[0]);
  final compiler = DartCompiler(program, noFormat: noFormat);
  final dartSource = compiler.compile();

  final output = _parseOption(args, 'output');
  if (output.isNotEmpty) {
    File(output).writeAsStringSync(dartSource);
    stderr.writeln('Compiled to $output');
  } else {
    stdout.write(dartSource);
  }
}

// ── encode ───────────────────────────────────────────────

void _encode(List<String> args) {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: ball encode <input.dart> [--output <file>] [--format json|binary]',
    );
    exit(1);
  }

  final file = File(positional[0]);
  if (!file.existsSync()) {
    stderr.writeln('Error: File not found: ${positional[0]}');
    exit(1);
  }

  final source = file.readAsStringSync();
  final encoder = DartEncoder();
  final name = positional[0]
      .split(Platform.pathSeparator)
      .last
      .replaceAll('.dart', '');
  final program = encoder.encode(source, name: name);

  final format = _parseOption(args, 'format');
  final output = _parseOption(args, 'output');

  if (format == 'binary') {
    final bytes = program.writeToBuffer();
    if (output.isNotEmpty) {
      File(output).writeAsBytesSync(bytes);
      stderr.writeln('Encoded to $output (binary, ${bytes.length} bytes)');
    } else {
      stdout.add(bytes);
    }
  } else {
    final jsonStr = const JsonEncoder.withIndent(
      '  ',
    ).convert(program.toProto3Json());
    if (output.isNotEmpty) {
      File(output).writeAsStringSync(jsonStr);
      stderr.writeln('Encoded to $output (JSON)');
    } else {
      stdout.writeln(jsonStr);
    }
  }
}

// ── run ──────────────────────────────────────────────────

void _run(List<String> args) {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    stderr.writeln('Usage: ball run <input.ball.json>');
    exit(1);
  }

  final program = _loadProgram(positional[0]);
  final engine = BallEngine(program);
  engine.run();
}

// ── round-trip ────────────────────────────────────────────

void _roundTrip(List<String> args) {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    stderr.writeln('Usage: ball round-trip <input.dart> [--no-format]');
    exit(1);
  }

  final file = File(positional[0]);
  if (!file.existsSync()) {
    stderr.writeln('Error: File not found: ${positional[0]}');
    exit(1);
  }

  final originalSource = file.readAsStringSync();
  final name = positional[0]
      .split(Platform.pathSeparator)
      .last
      .replaceAll('.dart', '');

  // Step 1: Encode Dart → Ball
  final encoder = DartEncoder();
  final Program program;
  try {
    program = encoder.encode(originalSource, name: name);
  } catch (e) {
    stderr.writeln('Error encoding ${positional[0]}: $e');
    exit(1);
  }
  if (encoder.warnings.isNotEmpty) {
    for (final w in encoder.warnings) {
      stderr.writeln('Warning: $w');
    }
  }

  // Step 2: Compile Ball → Dart
  final noFormat = args.contains('--no-format');
  final compiler = DartCompiler(program, noFormat: noFormat);
  final String compiledSource;
  try {
    compiledSource = compiler.compile();
  } catch (e) {
    stderr.writeln('Error compiling ball program: $e');
    exit(1);
  }

  // Step 3: Report diff
  final outputFile = _parseOption(args, 'output');
  if (outputFile.isNotEmpty) {
    File(outputFile).writeAsStringSync(compiledSource);
    stderr.writeln('Round-tripped Dart written to $outputFile');
  } else {
    // Print a summary diff: count changed lines
    final origLines = originalSource.split('\n');
    final newLines = compiledSource.split('\n');
    stderr.writeln('--- original (${origLines.length} lines)');
    stderr.writeln('+++ round-tripped (${newLines.length} lines)');
    stderr.writeln();
    stdout.write(compiledSource);
  }
}

Program _loadProgram(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Error: File not found: $path');
    exit(1);
  }
  final String jsonString;
  try {
    jsonString = file.readAsStringSync();
  } catch (e) {
    stderr.writeln('Error reading file: $e');
    exit(1);
  }
  final Map<String, dynamic> jsonData;
  try {
    jsonData = json.decode(jsonString) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('Error parsing JSON: $e');
    exit(1);
  }
  try {
    return Program()..mergeFromProto3Json(jsonData);
  } catch (e) {
    stderr.writeln('Error deserializing ball program: $e');
    exit(1);
  }
}

// ── ball audit ──────────────────────────────────────────────────────────────

void _audit(List<String> args) {
  final deny = <String>{};
  String? outputPath;
  String? inputPath;
  bool reachableOnly = false;
  bool exitCode = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--deny' && i + 1 < args.length) {
      deny.addAll(args[++i].split(','));
    } else if (arg == '--output' && i + 1 < args.length) {
      outputPath = args[++i];
    } else if (arg == '--reachable-only') {
      reachableOnly = true;
    } else if (arg == '--exit-code') {
      exitCode = true;
    } else if (!arg.startsWith('-')) {
      inputPath = arg;
    }
  }

  if (inputPath == null) {
    stderr.writeln('Usage: ball audit <input.ball.json> [--deny fs,memory] [--exit-code] [--reachable-only] [--output report.json]');
    exit(1);
  }

  final program = _loadProgram(inputPath);
  final report = analyzeCapabilities(program, reachableOnly: reachableOnly);

  if (outputPath != null) {
    final jsonOut = jsonEncode(report.toProto3Json());
    File(outputPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(jsonDecode(jsonOut)),
    );
    stderr.writeln('Report written to $outputPath');
  } else {
    stdout.writeln(formatCapabilityReport(report));
  }

  if (deny.isNotEmpty) {
    final violations = checkPolicy(report, deny: deny);
    if (violations.isNotEmpty) {
      stderr.writeln('\nPolicy violations (denied: ${deny.join(", ")}):');
      for (final v in violations) {
        stderr.writeln('  - $v');
      }
      if (exitCode) exit(1);
    }
  }
}

// ── ball build ──────────────────────────────────────────────────────────────

void _build(List<String> args) {
  String? inputPath;
  String? outputPath;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--output' && i + 1 < args.length) {
      outputPath = args[++i];
    } else if (!arg.startsWith('-')) {
      inputPath = arg;
    }
  }

  if (inputPath == null) {
    stderr.writeln('Usage: ball build <input.ball.json> [--output resolved.ball.json]');
    exit(1);
  }

  final program = _loadProgram(inputPath);

  // Check if there are any unresolved imports.
  var hasImports = false;
  for (final m in program.modules) {
    for (final imp in m.moduleImports) {
      if (imp.whichSource() != ModuleImport_Source.notSet) {
        hasImports = true;
        break;
      }
    }
    if (hasImports) break;
  }

  if (!hasImports) {
    stderr.writeln('No unresolved imports found — program is already self-contained.');
    if (outputPath != null) {
      File(outputPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(
          jsonDecode(jsonEncode(program.toProto3Json())),
        ),
      );
    }
    return;
  }

  // Resolve using the module resolver.
  final resolver = ModuleResolver();
  resolver.resolveAll(program).then((resolved) {
    final jsonOut = const JsonEncoder.withIndent('  ').convert(
      jsonDecode(jsonEncode(resolved.toProto3Json())),
    );
    if (outputPath != null) {
      File(outputPath).writeAsStringSync(jsonOut);
      stderr.writeln('Resolved program written to $outputPath');
    } else {
      stdout.writeln(jsonOut);
    }
  }).catchError((Object e) {
    stderr.writeln('Error resolving imports: $e');
    exit(1);
  });
}
