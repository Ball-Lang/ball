/// In-process implementation of the Ball CLI.
///
/// All command logic lives here so it can be exercised directly (in-process)
/// by unit tests via [runBall]. The `bin/ball.dart` entry point is a thin shim
/// that forwards `args` and turns the returned exit code into a real
/// `exit(code)`.
///
/// Behavior is identical to the historic `bin/ball.dart`: same output text and
/// same exit codes. `exit(n)` calls were replaced with `throw _CliExit(n)`,
/// which [runBall] catches and returns as the process exit code. All `stdout`
/// writes go to the injected `out` sink and `stderr` writes to `err`, defaulting
/// to the real `stdout`/`stderr`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show
        BallFile,
        BallModuleFile,
        BallProgramFile,
        decodeBallFileBinary,
        decodeBallFileJson,
        decodeProgramJson,
        encodeBallFileBinary,
        encodeBallFileJson;
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

/// Internal control-flow exception standing in for `exit(code)`. Thrown from a
/// command, caught by [runBall], and returned as the process exit code.
class _CliExit implements Exception {
  final int code;
  const _CliExit(this.code);
}

/// Runs the Ball CLI in-process and returns the exit code (0 on success).
///
/// [out] receives everything the CLI would write to `stdout`; [err] receives
/// everything it would write to `stderr`. Both default to the real process
/// streams, so the production shim behaves exactly like the original entry
/// point.
Future<int> runBall(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  try {
    await _dispatch(args, stdoutSink, stderrSink);
    return 0;
  } on _CliExit catch (e) {
    return e.code;
  }
}

Future<void> _dispatch(
  List<String> args,
  StringSink out,
  StringSink err,
) async {
  if (args.isEmpty) {
    _printUsage(err);
    throw const _CliExit(1);
  }

  final command = args[0];
  final rest = args.sublist(1);

  switch (command) {
    case 'info':
      _info(rest, out, err);
    case 'validate':
      _validate(rest, out, err);
    case 'compile':
      _compile(rest, out, err);
    case 'encode':
      _encode(rest, out, err);
    case 'run':
      await _run(rest, out, err);
    case 'round-trip':
      _roundTrip(rest, out, err);
    case 'audit':
      _audit(rest, out, err);
    case 'build':
      await _build(rest, out, err);
    case 'init':
      _init(rest, out, err);
    case 'add':
      _add(rest, out, err);
    case 'resolve':
      await _resolve(rest, out, err);
    case 'tree':
      _tree(rest, out, err);
    case 'publish':
      _publish(rest, out, err);
    case 'version':
    case '--version':
    case '-v':
      out.writeln('ball $_version');
    case 'help':
    case '--help':
    case '-h':
      _printUsage(err);
    default:
      err.writeln('Unknown command: $command');
      _printUsage(err);
      throw const _CliExit(1);
  }
}

void _printUsage(StringSink err) {
  err.writeln('Ball Language CLI v$_version');
  err.writeln();
  err.writeln('Usage: ball <command> [arguments]');
  err.writeln();
  err.writeln('Commands:');
  err.writeln('  info     <input.ball.json>   Inspect ball program structure');
  err.writeln('  validate <input.ball.json>   Check ball program validity');
  err.writeln(
    '  compile  <input.ball.json>   Compile ball program to Dart source',
  );
  err.writeln(
    '  encode   <input.dart>        Encode Dart source to ball program',
  );
  err.writeln('  run      <input.ball.json>   Execute ball program');
  err.writeln('  round-trip <input.dart>      Encode → compile → show diff');
  err.writeln('  audit    <input.ball.json>   Static capability analysis');
  err.writeln(
    '  build    <input.ball.json>   Resolve imports → self-contained program',
  );
  err.writeln(
    '  init                         Create ball.yaml in current directory',
  );
  err.writeln('  add      <spec>              Add dependency (pub:pkg@^1.0.0)');
  err.writeln('  resolve                      Resolve deps → ball.lock.json');
  err.writeln('  publish                      Bake module.ball.bin into lib/');
  err.writeln('  tree                         Print dependency tree');
  err.writeln('  version                      Print version');
  err.writeln('  help                         Show this help');
  err.writeln();
  err.writeln('Options:');
  err.writeln('  --output <file>              Output file (default: stdout)');
  err.writeln(
    '  --format <json|binary>       Output format for encode (default: json)',
  );
  err.writeln(
    '  --no-format                  Skip dart_style formatting (compile only)',
  );
}

// ── info ─────────────────────────────────────────────────

void _info(List<String> args, StringSink out, StringSink err) {
  if (args.isEmpty) {
    err.writeln('Usage: ball info <input.ball.json>');
    throw const _CliExit(1);
  }

  final program = _loadProgram(args[0], err);

  out.writeln('Program: ${program.name} v${program.version}');
  out.writeln('Entry:   ${program.entryModule}.${program.entryFunction}');
  out.writeln('Modules: ${program.modules.length}');
  out.writeln('');

  for (final module in program.modules) {
    final isBase = module.functions.every((f) => f.isBase);
    out.writeln('  ${module.name}${isBase ? " (base)" : ""}');
    if (module.typeDefs.isNotEmpty) {
      out.writeln('    typeDefs:  ${module.typeDefs.length}');
    }
    if (module.typeAliases.isNotEmpty) {
      out.writeln('    aliases:   ${module.typeAliases.length}');
    }
    if (module.enums.isNotEmpty) {
      out.writeln('    enums:     ${module.enums.length}');
    }
    out.writeln('    functions: ${module.functions.length}');
    if (module.description.isNotEmpty) {
      out.writeln('    desc:      ${module.description}');
    }
  }
}

// ── validate ─────────────────────────────────────────────

void _validate(List<String> args, StringSink out, StringSink err) {
  if (args.isEmpty) {
    err.writeln('Usage: ball validate <input.ball.json>');
    throw const _CliExit(1);
  }

  final program = _loadProgram(args[0], err);
  final errors = <String>[];

  if (program.entryModule.isEmpty) {
    errors.add('Missing entry_module');
  }
  if (program.entryFunction.isEmpty) {
    errors.add('Missing entry_function');
  }

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

  for (var i = 0; i < program.modules.length; i++) {
    final m = program.modules[i];
    if (m.name.isEmpty) {
      errors.add('Module at index $i has no name');
    }
  }

  final moduleNames = <String>{};
  for (final m in program.modules) {
    if (m.name.isNotEmpty && !moduleNames.add(m.name)) {
      errors.add('Duplicate module name: "${m.name}"');
    }
  }

  // Check non-base functions have a body or metadata.
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
    out.writeln('Valid: "${program.name}" v${program.version}');
    out.writeln(
      '  ${program.modules.length} modules, '
      '${program.modules.fold<int>(0, (s, m) => s + m.functions.length)} functions',
    );
  } else {
    err.writeln('Invalid: ${errors.length} error(s) found');
    for (final e in errors) {
      err.writeln('  - $e');
    }
    throw const _CliExit(1);
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

void _compile(List<String> args, StringSink out, StringSink err) {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    err.writeln(
      'Usage: ball compile <input.ball.json> [--output <file>] [--no-format]',
    );
    throw const _CliExit(1);
  }

  final noFormat = args.contains('--no-format');
  final program = _loadProgram(positional[0], err);
  final compiler = DartCompiler(program, noFormat: noFormat);
  final dartSource = compiler.compile();

  final output = _parseOption(args, 'output');
  if (output.isNotEmpty) {
    File(output).writeAsStringSync(dartSource);
    err.writeln('Compiled to $output');
  } else {
    out.write(dartSource);
  }
}

// ── encode ───────────────────────────────────────────────

void _encode(List<String> args, StringSink out, StringSink err) {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    err.writeln(
      'Usage: ball encode <input.dart> [--output <file>] [--format json|binary]',
    );
    throw const _CliExit(1);
  }

  final file = File(positional[0]);
  if (!file.existsSync()) {
    err.writeln('Error: File not found: ${positional[0]}');
    throw const _CliExit(1);
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
    final bytes = encodeBallFileBinary(program);
    if (output.isNotEmpty) {
      File(output).writeAsBytesSync(bytes);
      err.writeln('Encoded to $output (binary, ${bytes.length} bytes)');
    } else {
      // Binary-to-stdout only makes sense for the real process stdout (the test
      // path always supplies --output and is covered above). Guard so an
      // injected text sink isn't fed raw bytes.
      if (identical(out, stdout)) {
        stdout.add(bytes);
      } else {
        out.writeln('<binary: ${bytes.length} bytes>');
      }
    }
  } else {
    final jsonStr = const JsonEncoder.withIndent(
      '  ',
    ).convert(encodeBallFileJson(program));
    if (output.isNotEmpty) {
      File(output).writeAsStringSync(jsonStr);
      err.writeln('Encoded to $output (JSON)');
    } else {
      out.writeln(jsonStr);
    }
  }
}

// ── run ──────────────────────────────────────────────────

Future<void> _run(List<String> args, StringSink out, StringSink err) async {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    err.writeln('Usage: ball run <input.ball.json>');
    throw const _CliExit(1);
  }

  final program = _loadProgram(positional[0], err);
  final engine = BallEngine(program);
  await engine.run();
}

// ── round-trip ────────────────────────────────────────────

void _roundTrip(List<String> args, StringSink out, StringSink err) {
  final positional = _positionalArgs(args);
  if (positional.isEmpty) {
    err.writeln('Usage: ball round-trip <input.dart> [--no-format]');
    throw const _CliExit(1);
  }

  final file = File(positional[0]);
  if (!file.existsSync()) {
    err.writeln('Error: File not found: ${positional[0]}');
    throw const _CliExit(1);
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
    err.writeln('Error encoding ${positional[0]}: $e');
    throw const _CliExit(1);
  }
  if (encoder.warnings.isNotEmpty) {
    for (final w in encoder.warnings) {
      err.writeln('Warning: $w');
    }
  }

  // Step 2: Compile Ball → Dart
  final noFormat = args.contains('--no-format');
  final compiler = DartCompiler(program, noFormat: noFormat);
  final String compiledSource;
  try {
    compiledSource = compiler.compile();
  } catch (e) {
    err.writeln('Error compiling ball program: $e');
    throw const _CliExit(1);
  }

  // Step 3: Report diff
  final outputFile = _parseOption(args, 'output');
  if (outputFile.isNotEmpty) {
    File(outputFile).writeAsStringSync(compiledSource);
    err.writeln('Round-tripped Dart written to $outputFile');
  } else {
    // Print a summary diff: count changed lines
    final origLines = originalSource.split('\n');
    final newLines = compiledSource.split('\n');
    err.writeln('--- original (${origLines.length} lines)');
    err.writeln('+++ round-tripped (${newLines.length} lines)');
    err.writeln('');
    out.write(compiledSource);
  }
}

Program _loadProgram(String path, StringSink err) {
  final file = File(path);
  if (!file.existsSync()) {
    err.writeln('Error: File not found: $path');
    throw const _CliExit(1);
  }
  final String jsonString;
  try {
    jsonString = file.readAsStringSync();
  } catch (e) {
    err.writeln('Error reading file: $e');
    throw const _CliExit(1);
  }
  final Object? jsonData;
  try {
    jsonData = json.decode(jsonString);
  } catch (e) {
    err.writeln('Error parsing JSON: $e');
    throw const _CliExit(1);
  }
  try {
    return decodeProgramJson(jsonData);
  } catch (e) {
    err.writeln('Error deserializing ball program: $e');
    throw const _CliExit(1);
  }
}

/// Loads a ball file (a `Program` or a `Module`) for auditing, from either JSON
/// or binary (`.ball.bin`) encoding. The caller dispatches on the result — a
/// `Module` (a library such as `ball_protobuf`) is audited as the Module it is,
/// never wrapped in a synthetic `Program`.
BallFile _loadBallFile(String path, StringSink err) {
  final file = File(path);
  if (!file.existsSync()) {
    err.writeln('Error: File not found: $path');
    throw const _CliExit(1);
  }
  try {
    return path.endsWith('.bin')
        ? decodeBallFileBinary(file.readAsBytesSync())
        : decodeBallFileJson(json.decode(file.readAsStringSync()));
  } catch (e) {
    err.writeln('Error deserializing ball file: $e');
    throw const _CliExit(1);
  }
}

/// The implementation modules a facade [module] embeds inline via its
/// `module_imports` (e.g. `ball_protobuf`'s 13 modules) — analyzed alongside the
/// facade itself so the audit covers the whole library.
List<Module> _inlineImports(Module module) {
  final imports = <Module>[];
  for (final imp in module.moduleImports) {
    if (imp.hasInline() && imp.inline.hasProtoBytes()) {
      imports.add(Module.fromBuffer(imp.inline.protoBytes));
    }
  }
  return imports;
}

// ── ball audit ──────────────────────────────────────────────────────────────

void _audit(List<String> args, StringSink out, StringSink err) {
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
    err.writeln(
      'Usage: ball audit <input.ball.json> [--deny fs,memory] [--exit-code] [--reachable-only] [--no-check-termination] [--output report.json]',
    );
    throw const _CliExit(1);
  }

  // Audit a Program directly, or a library Module (e.g. ball_protobuf) as the
  // Module it is — together with its inline module_imports. No synthetic
  // Program is fabricated for a Module.
  final BallCapabilityReport report;
  final TerminationReport Function() runTermination;
  switch (_loadBallFile(inputPath, err)) {
    case BallProgramFile(:final program):
      report = analyzeCapabilities(program, reachableOnly: reachableOnly);
      runTermination = () => analyzeTermination(program);
    case BallModuleFile(:final module):
      final imports = _inlineImports(module);
      if (reachableOnly) {
        err.writeln(
          'Note: --reachable-only has no effect on a library Module '
          '(no entry point); analyzing all functions.',
        );
      }
      report = analyzeModuleCapabilities(module, imports: imports);
      runTermination = () => analyzeModuleTermination(module, imports: imports);
  }

  if (outputPath != null) {
    final jsonOut = jsonEncode(report.toProto3Json());
    File(outputPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(jsonDecode(jsonOut)),
    );
    err.writeln('Report written to $outputPath');
  } else {
    out.writeln(formatCapabilityReport(report));
  }

  if (checkTermination) {
    final termReport = runTermination();
    if (termReport.warnings.isNotEmpty) {
      out.writeln('');
      out.writeln(formatTerminationReport(termReport));
    }
    if (exitCode && termReport.hasErrors) {
      throw const _CliExit(1);
    }
  }

  if (deny.isNotEmpty) {
    final violations = checkPolicy(report, deny: deny);
    if (violations.isNotEmpty) {
      err.writeln('\nPolicy violations (denied: ${deny.join(", ")}):');
      for (final v in violations) {
        err.writeln('  - $v');
      }
      if (exitCode) throw const _CliExit(1);
    }
  }
}

// ── ball build ──────────────────────────────────────────────────────────────

/// The `ball build` on-the-fly encoder callback: downloads [source] from
/// pub.dev and encodes its first non-base, non-stub module. Requires live
/// network access -- kept as its own top-level function (instead of an
/// inline closure) purely so the ignored network block around its call
/// site in [_build] stays a clean one-liner. Unchanged from its prior
/// inline form (a pure relocation, not new logic).
OnTheFlyEncoder _onTheFlyEncodeForBuild(PubClient pubClient, StringSink err) {
  return (source, version) async {
    err.write('  encoding ${source.package}@$version... ');
    final vi = await pubClient.resolveVersion(source.package, source.version);
    final pkgDir = await pubClient.downloadPackage(
      source.package,
      vi.version,
      archiveUrl: vi.archiveUrl,
    );
    try {
      final encoder = PackageEncoder(pkgDir);
      final prog = encoder.encode();
      for (final m in prog.modules) {
        if (m.functions.every((f) => f.isBase) && m.functions.isNotEmpty) {
          continue;
        }
        if (m.functions.isEmpty && m.typeDefs.isEmpty) continue;
        err.writeln('OK');
        return m;
      }
      throw StateError('No encodable module in ${source.package}@$version');
    } finally {
      // Best-effort temp-dir cleanup: a failure here must not mask the real
      // encode error/result above, and a leftover temp dir is harmless.
      try {
        await pkgDir.delete(recursive: true);
      } catch (_) {}
    }
  };
}

Future<void> _build(List<String> args, StringSink out, StringSink err) async {
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
    err.writeln(
      'Usage: ball build <input.ball.json> [--output resolved.ball.json]',
    );
    throw const _CliExit(1);
  }

  final program = _loadProgram(inputPath, err);

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
    err.writeln(
      'No unresolved imports found — program is already self-contained.',
    );
    if (outputPath != null) {
      File(outputPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(encodeBallFileJson(program)),
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
      final lockData =
          jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
      final packages = lockData['packages'] as List? ?? [];
      err.writeln('Using ball.lock.json (${packages.length} packages cached)');
      preCache = ContentAddressableCache();
    } catch (_) {}
  }

  // Resolve using the module resolver with pub.dev adapter + on-the-fly encoding.
  final pubClient = PubClient();
  final bridge = RegistryBridge()..register(PubAdapter());
  // Requires live network access to pub.dev (a real registry resolve +
  // package download) — excluded from coverage per issue #261/repo policy,
  // matching the existing `--exclude-tags network` convention: exercising
  // this for real would make an unattended coverage run hit the network.
  // coverage:ignore-start
  bridge.onTheFlyEncoder = _onTheFlyEncodeForBuild(pubClient, err);
  // coverage:ignore-end
  final resolver = ModuleResolver(
    registryResolver: bridge.resolve,
    cache: preCache ?? ContentAddressableCache(),
  );
  try {
    final resolved = await resolver.resolveAll(program);
    final jsonOut = const JsonEncoder.withIndent(
      '  ',
    ).convert(encodeBallFileJson(resolved));
    if (outputPath != null) {
      File(outputPath).writeAsStringSync(jsonOut);
      err.writeln('Resolved program written to $outputPath');
    } else {
      out.writeln(jsonOut);
    }
  } catch (e) {
    err.writeln('Error resolving imports: $e');
    throw const _CliExit(1);
  }
}

// ── ball init ───────────────────────────────────────────────────────────────

void _init(List<String> args, StringSink out, StringSink err) {
  final file = File('ball.yaml');
  if (file.existsSync()) {
    err.writeln('ball.yaml already exists in current directory.');
    throw const _CliExit(1);
  }

  final name =
      Directory.current.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .lastOrNull ??
      'my_app';

  file.writeAsStringSync('''
name: $name
version: 0.1.0
entry_module: main
entry_function: main

dependencies: {}
''');
  out.writeln('Created ball.yaml');
}

// ── ball add ────────────────────────────────────────────────────────────────

void _add(List<String> args, StringSink out, StringSink err) {
  if (args.isEmpty) {
    err.writeln('Usage: ball add <registry>:<package>@<version>');
    err.writeln('Examples:');
    err.writeln('  ball add pub:http@^1.0.0');
    err.writeln('  ball add npm:@ball/utils@^2.0.0');
    err.writeln('  ball add git:https://github.com/foo/bar.git@v1.0.0');
    throw const _CliExit(1);
  }

  final file = File('ball.yaml');
  if (!file.existsSync()) {
    err.writeln('No ball.yaml found. Run `ball init` first.');
    throw const _CliExit(1);
  }

  for (final spec in args) {
    final parsed = _parseImportSpec(spec);
    if (parsed == null) {
      err.writeln('Invalid import spec: $spec');
      err.writeln('Expected format: <registry>:<package>@<version>');
      throw const _CliExit(1);
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
      content =
          '${content.substring(0, lineEnd)}\n  ${parsed.name}:\n${parsed.yaml}${content.substring(lineEnd)}';
    }
    file.writeAsStringSync(content);
    out.writeln('Added ${parsed.name} to ball.yaml');
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
      return _ParsedSpec(
        package,
        '    registry: pub\n    package: $package\n    version: "$version"\n',
      );
    case 'npm':
      return _ParsedSpec(
        package.replaceAll('/', '_').replaceAll('@', ''),
        '    registry: npm\n    package: "$package"\n    version: "$version"\n',
      );
    case 'git':
      return _ParsedSpec(
        package.split('/').last.replaceAll('.git', ''),
        '    git:\n      url: $package\n      ref: "$version"\n',
      );
    case 'http':
      return _ParsedSpec(
        package.split('/').last.replaceAll('.ball.bin', ''),
        '    url: "$package"\n',
      );
    default:
      return null;
  }
}

// ── ball resolve ────────────────────────────────────────────────────────────

/// The `ball resolve` on-the-fly encoder callback: downloads [source] from
/// pub.dev and encodes its first non-base, non-stub module. Requires live
/// network access -- kept as its own top-level function (instead of an
/// inline closure) purely so the ignored network block around its call
/// site in [_resolve] stays a clean one-liner. Unchanged from its prior
/// inline form (a pure relocation, not new logic).
OnTheFlyEncoder _onTheFlyEncodeForResolve(PubClient pubClient, StringSink err) {
  return (source, version) async {
    err.write('(encoding on-the-fly) ');
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
        if (m.functions.every((f) => f.isBase) && m.functions.isNotEmpty) {
          continue;
        }
        if (m.functions.isEmpty && m.typeDefs.isEmpty) continue;
        return m;
      }
      throw StateError(
        'No encodable module found in ${source.package}@$version',
      );
    } finally {
      // Best-effort temp-dir cleanup: a failure here must not mask the real
      // encode error/result above, and a leftover temp dir is harmless.
      try {
        await pkgDir.delete(recursive: true);
      } catch (_) {}
    }
  };
}

Future<void> _resolve(List<String> args, StringSink out, StringSink err) async {
  final file = File('ball.yaml');
  if (!file.existsSync()) {
    err.writeln('No ball.yaml found. Run `ball init` first.');
    throw const _CliExit(1);
  }

  err.writeln('Resolving dependencies from ball.yaml...');

  final content = file.readAsStringSync();
  // A valid ball.yaml is a YAML mapping. Anything else (empty/null, a bare list
  // or scalar) is malformed — guard with `is` instead of an `as` cast so a
  // non-map document is reported, not crashed on (CastError).
  final parsed = loadYaml(content);
  if (parsed is! YamlMap) {
    err.writeln('ball.yaml is empty or malformed.');
    throw const _CliExit(1);
  }
  final doc = parsed;

  final deps = doc['dependencies'];
  if (deps == null || deps is! YamlMap || deps.isEmpty) {
    err.writeln('No dependencies declared in ball.yaml.');
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
    err.writeln('No resolvable dependencies found.');
    return;
  }

  // Set up a resolver with the pub.dev registry adapter.
  // When a package doesn't contain a pre-built Ball module, fall back
  // to on-the-fly encoding via the Dart encoder.
  final pubClient = PubClient();
  final bridge = RegistryBridge()..register(PubAdapter());
  // Requires live network access to pub.dev (a real registry resolve +
  // package download) -- excluded from coverage per issue #261/repo policy,
  // matching the existing `--exclude-tags network` convention.
  // coverage:ignore-start
  bridge.onTheFlyEncoder = _onTheFlyEncodeForResolve(pubClient, err);
  // coverage:ignore-end
  final resolver = ModuleResolver(registryResolver: bridge.resolve);
  final lockEntries = <Map<String, Object?>>[];

  for (final import_ in imports) {
    err.write('  ${import_.name}... ');
    try {
      final module = await resolver.resolve(import_);
      err.writeln('OK (${module.functions.length} functions)');
      lockEntries.add({
        'name': import_.name,
        'resolved_version': '',
        'integrity': computeIntegrity(module),
      });
    } catch (e) {
      err.writeln('FAIL: ${e.toString().split('\n').first}');
      lockEntries.add({
        'name': import_.name,
        'error': e.toString().split('\n').first,
      });
    }
  }

  // Write ball.lock.json.
  final lockFile = File('ball.lock.json');
  final lockJson = const JsonEncoder.withIndent(
    '  ',
  ).convert({'lock_version': '1', 'packages': lockEntries});
  lockFile.writeAsStringSync(lockJson);
  err.writeln('\nWrote ball.lock.json (${lockEntries.length} packages)');
}

void _publish(List<String> args, StringSink out, StringSink err) {
  // Encode the current project's Dart source to Ball IR, then write
  // lib/module.ball.bin (binary protobuf) and lib/module.ball.json
  // so downstream Ball projects can import this package directly.
  final yamlFile = File('ball.yaml');
  if (!yamlFile.existsSync()) {
    // If no ball.yaml, look for pubspec.yaml (Dart package) and encode it.
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) {
      err.writeln('Error: No ball.yaml or pubspec.yaml found.');
      err.writeln(
        'Run "ball init" first, or run from a Dart package directory.',
      );
      return;
    }
    err.writeln(
      'No ball.yaml found. Encoding Dart package from pubspec.yaml...',
    );
    final encoder = PackageEncoder(Directory.current);
    final program = encoder.encode();
    _writeArtifacts(program, err);
    return;
  }

  // Read ball.yaml for project info.
  final yaml = loadYaml(yamlFile.readAsStringSync()) as YamlMap;
  final name = yaml['name'] as String? ?? 'unnamed';

  // Check if there's a Dart source to encode.
  final libDir = Directory('lib');
  if (libDir.existsSync()) {
    err.writeln('Encoding Dart package "$name"...');
    final encoder = PackageEncoder(Directory.current);
    final program = encoder.encode();
    _writeArtifacts(program, err);
    return;
  }

  // If there's already a .ball.json program, just convert to binary.
  final inputFile = args.isNotEmpty ? File(args[0]) : null;
  if (inputFile != null && inputFile.existsSync()) {
    err.writeln('Converting ${inputFile.path} to binary artifacts...');
    final program = _loadProgram(inputFile.path, err);
    _writeArtifacts(program, err);
    return;
  }

  err.writeln('Error: No Dart source in lib/ and no .ball.json specified.');
  err.writeln('Usage: ball publish [input.ball.json]');
}

void _writeArtifacts(Program program, StringSink err) {
  final libDir = Directory('lib');
  if (!libDir.existsSync()) libDir.createSync(recursive: true);

  // Binary protobuf (self-describing Any envelope).
  final binFile = File('lib/module.ball.bin');
  binFile.writeAsBytesSync(encodeBallFileBinary(program));
  err.writeln('  Wrote lib/module.ball.bin (${binFile.lengthSync()} bytes)');

  // JSON (for human inspection / debugging).
  final jsonFile = File('lib/module.ball.json');
  final jsonStr = const JsonEncoder.withIndent(
    '  ',
  ).convert(encodeBallFileJson(program));
  jsonFile.writeAsStringSync(jsonStr);
  err.writeln('  Wrote lib/module.ball.json (${jsonFile.lengthSync()} bytes)');

  err.writeln('\nBall artifacts ready for publishing.');
  err.writeln('Downstream packages can import via:');
  err.writeln('  ball add pub:${program.name}@^${program.version}');
}

Registry _parseRegistry(String name) {
  switch (name.toLowerCase()) {
    case 'pub':
      return Registry.REGISTRY_PUB;
    case 'npm':
      return Registry.REGISTRY_NPM;
    case 'nuget':
      return Registry.REGISTRY_NUGET;
    case 'cargo':
      return Registry.REGISTRY_CARGO;
    case 'pypi':
      return Registry.REGISTRY_PYPI;
    case 'maven':
      return Registry.REGISTRY_MAVEN;
    default:
      return Registry.REGISTRY_UNSPECIFIED;
  }
}

// ── ball tree ───────────────────────────────────────────────────────────────

void _tree(List<String> args, StringSink out, StringSink err) {
  String? inputPath;
  for (final arg in args) {
    if (!arg.startsWith('-')) {
      inputPath = arg;
      break;
    }
  }

  if (inputPath == null) {
    err.writeln('Usage: ball tree <input.ball.json>');
    throw const _CliExit(1);
  }

  final program = _loadProgram(inputPath, err);
  out.writeln('${program.name} v${program.version}');

  for (final m in program.modules) {
    final isBase = m.functions.every((f) => f.isBase) && m.functions.isNotEmpty;
    final tag = isBase ? ' (base)' : '';
    final fnCount = m.functions.length;
    out.writeln('  ${m.name}$tag — $fnCount functions');
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
      out.writeln('    → ${imp.name} ($source)');
    }
  }
}
