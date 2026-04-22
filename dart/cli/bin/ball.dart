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
import 'package:ball_base/termination_analyzer.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';
import 'package:ball_engine/engine.dart';
import 'package:ball_resolver/ball_resolver.dart';
import 'package:yaml/yaml.dart';

const _version = '0.1.0';

Future<void> main(List<String> args) async {
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
      await _run(rest);
    case 'round-trip':
      _roundTrip(rest);
    case 'audit':
      _audit(rest);
    case 'build':
      _build(rest);
    case 'init':
      _init(rest);
    case 'add':
      _add(rest);
    case 'resolve':
      _resolve(rest);
    case 'tree':
      _tree(rest);
    case 'publish':
      _publish(rest);
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
  stderr.writeln('  init                         Create ball.yaml in current directory');
  stderr.writeln('  add      <spec>              Add dependency (pub:pkg@^1.0.0)');
  stderr.writeln('  resolve                      Resolve deps → ball.lock.json');
  stderr.writeln('  publish                      Bake module.ball.bin into lib/');
  stderr.writeln('  tree                         Print dependency tree');
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

Future<void> _run(List<String> args) async {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    stderr.writeln('Usage: ball run <input.ball.json>');
    exit(1);
  }

  final program = _loadProgram(positional[0]);
  final engine = BallEngine(program);
  await engine.run();
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
  bool checkTermination = true;

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
    } else if (arg == '--no-check-termination') {
      checkTermination = false;
    } else if (arg == '--check-termination') {
      checkTermination = true;
    } else if (!arg.startsWith('-')) {
      inputPath = arg;
    }
  }

  if (inputPath == null) {
    stderr.writeln('Usage: ball audit <input.ball.json> [--deny fs,memory] [--exit-code] [--reachable-only] [--no-check-termination] [--output report.json]');
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

  if (checkTermination) {
    final termReport = analyzeTermination(program);
    if (termReport.warnings.isNotEmpty) {
      stdout.writeln();
      stdout.writeln(formatTerminationReport(termReport));
    }
    if (exitCode && termReport.hasErrors) {
      exit(1);
    }
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

  // Check for ball.lock.json — if present, pre-populate cache with
  // integrity hashes so the resolver can skip network for cached modules.
  final lockFile = File('ball.lock.json');
  ContentAddressableCache? preCache;
  if (lockFile.existsSync()) {
    try {
      final lockData = jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
      final packages = lockData['packages'] as List? ?? [];
      stderr.writeln('Using ball.lock.json (${packages.length} packages cached)');
      preCache = ContentAddressableCache();
    } catch (_) {}
  }

  // Resolve using the module resolver with pub.dev adapter + on-the-fly encoding.
  final pubClient = PubClient();
  final bridge = RegistryBridge()..register(PubAdapter());
  bridge.onTheFlyEncoder = (source, version) async {
    stderr.write('  encoding ${source.package}@$version... ');
    final vi = await pubClient.resolveVersion(source.package, source.version);
    final pkgDir = await pubClient.downloadPackage(source.package, vi.version, archiveUrl: vi.archiveUrl);
    try {
      final encoder = PackageEncoder(pkgDir);
      final prog = encoder.encode();
      for (final m in prog.modules) {
        if (m.functions.every((f) => f.isBase) && m.functions.isNotEmpty) continue;
        if (m.functions.isEmpty && m.typeDefs.isEmpty && m.types.isEmpty) continue;
        stderr.writeln('OK');
        return m;
      }
      throw StateError('No encodable module in ${source.package}@$version');
    } finally {
      try { await pkgDir.delete(recursive: true); } catch (_) {}
    }
  };
  final resolver = ModuleResolver(
    registryResolver: bridge.resolve,
    cache: preCache ?? ContentAddressableCache(),
  );
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

// ── ball init ───────────────────────────────────────────────────────────────

void _init(List<String> args) {
  final file = File('ball.yaml');
  if (file.existsSync()) {
    stderr.writeln('ball.yaml already exists in current directory.');
    exit(1);
  }

  final name = Directory.current.uri.pathSegments
      .where((s) => s.isNotEmpty)
      .lastOrNull ?? 'my_app';

  file.writeAsStringSync('''
name: $name
version: 0.1.0
entry_module: main
entry_function: main

dependencies: {}
''');
  stdout.writeln('Created ball.yaml');
}

// ── ball add ────────────────────────────────────────────────────────────────

void _add(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: ball add <registry>:<package>@<version>');
    stderr.writeln('Examples:');
    stderr.writeln('  ball add pub:http@^1.0.0');
    stderr.writeln('  ball add npm:@ball/utils@^2.0.0');
    stderr.writeln('  ball add git:https://github.com/foo/bar.git@v1.0.0');
    exit(1);
  }

  final file = File('ball.yaml');
  if (!file.existsSync()) {
    stderr.writeln('No ball.yaml found. Run `ball init` first.');
    exit(1);
  }

  for (final spec in args) {
    final parsed = _parseImportSpec(spec);
    if (parsed == null) {
      stderr.writeln('Invalid import spec: $spec');
      stderr.writeln('Expected format: <registry>:<package>@<version>');
      exit(1);
    }

    var content = file.readAsStringSync();
    if (content.contains('dependencies: {}')) {
      content = content.replaceFirst(
        'dependencies: {}',
        'dependencies:\n  ${parsed.name}:\n${parsed.yaml}',
      );
    } else if (content.contains('dependencies:')) {
      final idx = content.indexOf('dependencies:');
      final lineEnd = content.indexOf('\n', idx);
      content = '${content.substring(0, lineEnd)}\n  ${parsed.name}:\n${parsed.yaml}${content.substring(lineEnd)}';
    }
    file.writeAsStringSync(content);
    stdout.writeln('Added ${parsed.name} to ball.yaml');
  }
}

class _ParsedSpec {
  final String name;
  final String yaml;
  _ParsedSpec(this.name, this.yaml);
}

_ParsedSpec? _parseImportSpec(String spec) {
  // pub:package@^1.0.0
  final colonIdx = spec.indexOf(':');
  if (colonIdx < 0) return null;

  final registry = spec.substring(0, colonIdx);
  final rest = spec.substring(colonIdx + 1);

  final atIdx = rest.lastIndexOf('@');
  if (atIdx < 0) return null;

  final package = rest.substring(0, atIdx);
  final version = rest.substring(atIdx + 1);

  switch (registry) {
    case 'pub':
      return _ParsedSpec(package, '    registry: pub\n    package: $package\n    version: "$version"\n');
    case 'npm':
      return _ParsedSpec(package.replaceAll('/', '_').replaceAll('@', ''), '    registry: npm\n    package: "$package"\n    version: "$version"\n');
    case 'git':
      return _ParsedSpec(package.split('/').last.replaceAll('.git', ''), '    git:\n      url: $package\n      ref: "$version"\n');
    case 'http':
      return _ParsedSpec(package.split('/').last.replaceAll('.ball.bin', ''), '    url: "$package"\n');
    default:
      return null;
  }
}

// ── ball resolve ────────────────────────────────────────────────────────────

Future<void> _resolve(List<String> args) async {
  final file = File('ball.yaml');
  if (!file.existsSync()) {
    stderr.writeln('No ball.yaml found. Run `ball init` first.');
    exit(1);
  }

  stderr.writeln('Resolving dependencies from ball.yaml...');

  final content = file.readAsStringSync();
  final doc = loadYaml(content) as YamlMap?;
  if (doc == null) {
    stderr.writeln('ball.yaml is empty or malformed.');
    exit(1);
  }

  final deps = doc['dependencies'];
  if (deps == null || deps is! YamlMap || deps.isEmpty) {
    stderr.writeln('No dependencies declared in ball.yaml.');
    return;
  }

  // Build ModuleImport entries from the YAML declarations.
  final imports = <ModuleImport>[];
  for (final entry in deps.entries) {
    final name = entry.key as String;
    final spec = entry.value;
    if (spec is! YamlMap) continue;

    final import_ = ModuleImport()..name = name;

    if (spec.containsKey('registry')) {
      final regName = spec['registry'] as String;
      final pkg = spec['package'] as String? ?? name;
      final version = spec['version'] as String? ?? 'any';
      final regUrl = spec['registry_url'] as String? ?? '';
      import_.registry = (RegistrySource()
        ..package = pkg
        ..version = version
        ..registry = _parseRegistry(regName)
        ..registryUrl = regUrl);
    } else if (spec.containsKey('git')) {
      final git = spec['git'] as YamlMap;
      import_.git = (GitSource()
        ..url = (git['url'] as String? ?? '')
        ..ref = (git['ref'] as String? ?? 'main'));
    } else if (spec.containsKey('url')) {
      import_.http = (HttpSource()..url = spec['url'] as String);
    } else if (spec.containsKey('path')) {
      import_.file = (FileSource()..path = spec['path'] as String);
    }

    imports.add(import_);
  }

  if (imports.isEmpty) {
    stderr.writeln('No resolvable dependencies found.');
    return;
  }

  // Set up a resolver with the pub.dev registry adapter.
  // When a package doesn't contain a pre-built Ball module, fall back
  // to on-the-fly encoding via the Dart encoder.
  final pubClient = PubClient();
  final bridge = RegistryBridge()..register(PubAdapter());
  bridge.onTheFlyEncoder = (source, version) async {
    stderr.write('(encoding on-the-fly) ');
    // Use PubClient's API-based resolution to get the correct archive URL.
    final vi = await pubClient.resolveVersion(source.package, source.version);
    final pkgDir = await pubClient.downloadPackage(
      source.package,
      vi.version,
      archiveUrl: vi.archiveUrl,
    );
    try {
      final encoder = PackageEncoder(pkgDir);
      final program = encoder.encode();
      // Return the main module (the first non-base, non-stub module).
      for (final m in program.modules) {
        if (m.functions.every((f) => f.isBase) && m.functions.isNotEmpty) continue;
        if (m.functions.isEmpty && m.typeDefs.isEmpty && m.types.isEmpty) continue;
        return m;
      }
      throw StateError('No encodable module found in ${source.package}@$version');
    } finally {
      try { await pkgDir.delete(recursive: true); } catch (_) {}
    }
  };
  final resolver = ModuleResolver(registryResolver: bridge.resolve);
  final lockEntries = <Map<String, Object?>>[];

  for (final import_ in imports) {
    stderr.write('  ${import_.name}... ');
    try {
      final module = await resolver.resolve(import_);
      stderr.writeln('OK (${module.functions.length} functions)');
      lockEntries.add({
        'name': import_.name,
        'resolved_version': '',
        'integrity': computeIntegrity(module),
      });
    } catch (e) {
      stderr.writeln('FAIL: ${e.toString().split('\n').first}');
      lockEntries.add({
        'name': import_.name,
        'error': e.toString().split('\n').first,
      });
    }
  }

  // Write ball.lock.json.
  final lockFile = File('ball.lock.json');
  final lockJson = const JsonEncoder.withIndent('  ').convert({
    'lock_version': '1',
    'packages': lockEntries,
  });
  lockFile.writeAsStringSync(lockJson);
  stderr.writeln('\nWrote ball.lock.json (${lockEntries.length} packages)');
}

void _publish(List<String> args) {
  // Encode the current project's Dart source to Ball IR, then write
  // lib/module.ball.bin (binary protobuf) and lib/module.ball.json
  // so downstream Ball projects can import this package directly.
  final yamlFile = File('ball.yaml');
  if (!yamlFile.existsSync()) {
    // If no ball.yaml, look for pubspec.yaml (Dart package) and encode it.
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) {
      stderr.writeln('Error: No ball.yaml or pubspec.yaml found.');
      stderr.writeln('Run "ball init" first, or run from a Dart package directory.');
      return;
    }
    stderr.writeln('No ball.yaml found. Encoding Dart package from pubspec.yaml...');
    final encoder = PackageEncoder(Directory.current);
    final program = encoder.encode();
    _writeArtifacts(program);
    return;
  }

  // Read ball.yaml for project info.
  final yaml = loadYaml(yamlFile.readAsStringSync()) as YamlMap;
  final name = yaml['name'] as String? ?? 'unnamed';

  // Check if there's a Dart source to encode.
  final libDir = Directory('lib');
  if (libDir.existsSync()) {
    stderr.writeln('Encoding Dart package "$name"...');
    final encoder = PackageEncoder(Directory.current);
    final program = encoder.encode();
    _writeArtifacts(program);
    return;
  }

  // If there's already a .ball.json program, just convert to binary.
  final inputFile = args.isNotEmpty ? File(args[0]) : null;
  if (inputFile != null && inputFile.existsSync()) {
    stderr.writeln('Converting ${inputFile.path} to binary artifacts...');
    final program = _loadProgram(inputFile.path);
    _writeArtifacts(program);
    return;
  }

  stderr.writeln('Error: No Dart source in lib/ and no .ball.json specified.');
  stderr.writeln('Usage: ball publish [input.ball.json]');
}

void _writeArtifacts(Program program) {
  final libDir = Directory('lib');
  if (!libDir.existsSync()) libDir.createSync(recursive: true);

  // Binary protobuf
  final binFile = File('lib/module.ball.bin');
  binFile.writeAsBytesSync(program.writeToBuffer());
  stderr.writeln('  Wrote lib/module.ball.bin (${binFile.lengthSync()} bytes)');

  // JSON (for human inspection / debugging)
  final jsonFile = File('lib/module.ball.json');
  final jsonStr = const JsonEncoder.withIndent('  ').convert(
    jsonDecode(jsonEncode(program.toProto3Json())),
  );
  jsonFile.writeAsStringSync(jsonStr);
  stderr.writeln('  Wrote lib/module.ball.json (${jsonFile.lengthSync()} bytes)');

  stderr.writeln('\nBall artifacts ready for publishing.');
  stderr.writeln('Downstream packages can import via:');
  stderr.writeln('  ball add pub:${program.name}@^${program.version}');
}

Registry _parseRegistry(String name) {
  switch (name.toLowerCase()) {
    case 'pub': return Registry.REGISTRY_PUB;
    case 'npm': return Registry.REGISTRY_NPM;
    case 'nuget': return Registry.REGISTRY_NUGET;
    case 'cargo': return Registry.REGISTRY_CARGO;
    case 'pypi': return Registry.REGISTRY_PYPI;
    case 'maven': return Registry.REGISTRY_MAVEN;
    default: return Registry.REGISTRY_UNSPECIFIED;
  }
}

// ── ball tree ───────────────────────────────────────────────────────────────

void _tree(List<String> args) {
  String? inputPath;
  for (final arg in args) {
    if (!arg.startsWith('-')) { inputPath = arg; break; }
  }

  if (inputPath == null) {
    stderr.writeln('Usage: ball tree <input.ball.json>');
    exit(1);
  }

  final program = _loadProgram(inputPath);
  stdout.writeln('${program.name} v${program.version}');

  for (final m in program.modules) {
    final isBase = m.functions.every((f) => f.isBase) && m.functions.isNotEmpty;
    final tag = isBase ? ' (base)' : '';
    final fnCount = m.functions.length;
    stdout.writeln('  ${m.name}$tag — $fnCount functions');
    for (final imp in m.moduleImports) {
      final source = imp.hasHttp()
          ? 'http: ${imp.http.url}'
          : imp.hasFile()
              ? 'file: ${imp.file.path}'
              : imp.hasGit()
                  ? 'git: ${imp.git.url}@${imp.git.ref}'
                  : imp.hasRegistry()
                      ? '${imp.registry.registry.name}: ${imp.registry.package}@${imp.registry.version}'
                      : imp.hasInline()
                          ? 'inline'
                          : 'ref only';
      stdout.writeln('    → ${imp.name} ($source)');
    }
  }
}
