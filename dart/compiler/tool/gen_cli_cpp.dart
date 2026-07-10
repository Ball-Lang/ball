/// Regenerate the C++ self-hosted CLI-core header
/// `dart/self_host/lib/cli_rt.h` from the portable CLI verbs in
/// `dart/self_host/cli.ball.json`.
///
/// This is the C++ counterpart of `compile_engine_cpp.dart` (which compiles the
/// self-hosted *engine* to C++). It takes the `main` module of the generated
/// `cli.ball.json` — the `infoReport` / `validateReport` / `treeReport` /
/// `versionLine` verbs (issue #362 `cli_core`) — and library-compiles it through
/// the existing `ball_cpp_compile` binary into a single callable C++ header in
/// namespace `cli_core`. The C++ `ball` CLI (`cpp/cli/`) links that header so its
/// portable verbs execute byte-identically to the Dart CLI (proven by
/// `cpp/test/test_cli_parity.cpp`, the C++ mirror of
/// `dart/cli/test/cli_core_parity_test.dart`).
///
///   1. `cd dart && dart run compiler/tool/gen_cli_json.dart`   (writes cli.ball.json)
///   2. `cd dart && dart run compiler/tool/gen_cli_cpp.dart`    (writes cli_rt.h)
///
/// The `audit` verb is intentionally excluded: its capability/termination
/// analyzers are not part of `cli_core.dart`'s resolved library (they are import
/// stubs in `cli.ball.json`), so compiling `auditReport` would reference
/// undefined functions. It stays on issue #362 until `cli_core` self-hosts it.
///
/// Like `engine_rt.cpp` and `cli.ball.json`, the outputs are generated build
/// artifacts kept out of git (see `dart/self_host/.gitignore`) and regenerated
/// by CI. The intermediate `cli_module.ball.json` (the extracted, audit-stripped
/// `main` module as a Module ball-file) is also gitignored.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show BallProgramFile, decodeBallFileJson, encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';

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

/// Locate the built `ball_cpp_compile` binary across common build-tree layouts.
/// Picks the most-recently-modified match so a freshly-rebuilt compiler wins.
/// (Mirrors `compile_engine_cpp.dart`.)
String _findCppCompiler(String root) {
  final candidates = [
    for (final dir in ['ci-build', 'build3', 'build2', 'build'])
      for (final cfg in ['Release', 'Debug', '']) ...[
        '$root/cpp/$dir/compiler/${cfg.isEmpty ? '' : '$cfg/'}ball_cpp_compile.exe',
        '$root/cpp/$dir/compiler/${cfg.isEmpty ? '' : '$cfg/'}ball_cpp_compile',
      ],
  ];
  String? best;
  DateTime? bestMtime;
  for (final p in candidates) {
    final f = File(p);
    if (!f.existsSync()) continue;
    final mtime = f.lastModifiedSync();
    if (bestMtime == null || mtime.isAfter(bestMtime)) {
      bestMtime = mtime;
      best = p;
    }
  }
  if (best != null) return best;
  throw StateError(
    'ball_cpp_compile not found. Build cpp/build first:\n'
    '  cmake -S cpp -B cpp/build && cmake --build cpp/build --target ball_cpp_compile',
  );
}

Future<void> main(List<String> args) async {
  final root = _findRepoRoot();
  stdout.writeln('Compile cli_core → C++ header via existing cpp/compiler');
  stdout.writeln('=' * 60);

  final cliJsonPath = '$root/dart/self_host/cli.ball.json';
  final cliJsonFile = File(cliJsonPath);
  if (!cliJsonFile.existsSync()) {
    stderr.writeln(
      'Missing $cliJsonPath — run `cd dart && dart run '
      'compiler/tool/gen_cli_json.dart` first.',
    );
    exit(1);
  }

  final decoded = decodeBallFileJson(
    jsonDecode(cliJsonFile.readAsStringSync()),
  );
  if (decoded is! BallProgramFile) {
    stderr.writeln('cli.ball.json is not a Program');
    exit(1);
  }
  final program = decoded.program;

  // Extract the `main` module (the portable verbs) and strip `auditReport`,
  // whose analyzers are import stubs (see the doc comment above).
  Module? mainModule;
  for (final m in program.modules) {
    if (m.name == 'main') {
      mainModule = m;
      break;
    }
  }
  if (mainModule == null) {
    stderr.writeln('cli.ball.json has no `main` module');
    exit(1);
  }

  final libModule = Module()
    ..name = mainModule.name
    ..description = mainModule.description
    ..moduleImports.addAll(mainModule.moduleImports)
    ..typeDefs.addAll(mainModule.typeDefs)
    ..typeAliases.addAll(mainModule.typeAliases)
    ..enums.addAll(mainModule.enums);
  for (final f in mainModule.functions) {
    if (f.name == 'auditReport') continue;
    libModule.functions.add(f);
  }
  if (mainModule.hasMetadata()) libModule.metadata = mainModule.metadata;

  stdout.writeln(
    '  cli_core module: ${libModule.functions.length} fns '
    '(audit excluded)',
  );

  // Write the Module ball-file (self-describing @type envelope) as UTF-8 —
  // preserving the em-dash / arrow literals `tree` prints byte-for-byte.
  final moduleJson = const JsonEncoder.withIndent(
    '  ',
  ).convert(encodeBallFileJson(libModule));
  final modulePath = '$root/dart/self_host/cli_module.ball.json';
  File(modulePath).writeAsStringSync(moduleJson); // Dart writes UTF-8
  stdout.writeln('  Wrote ${moduleJson.length} bytes → $modulePath');

  // Library-compile it into cpp/cli's callable header.
  final cppCompiler = _findCppCompiler(root);
  final outHeader = '$root/dart/self_host/lib/cli_rt.h';
  File(outHeader).parent.createSync(recursive: true);
  stdout.writeln('\nRunning $cppCompiler --library ...');
  final result = await Process.run(cppCompiler, [
    modulePath,
    '--library',
    '--ns',
    'cli_core',
    '--out',
    outHeader,
  ], runInShell: true);
  if (result.exitCode != 0) {
    stdout.writeln('! cpp compiler reported errors:');
    stdout.writeln(result.stdout);
    stdout.writeln(result.stderr);
    exit(result.exitCode);
  }
  stdout.writeln(result.stdout);
  stdout.writeln(result.stderr);
  final lines = File(outHeader).readAsLinesSync().length;
  stdout.writeln('✓ Emitted ${outHeader.replaceAll('\\', '/')} ($lines lines)');
  stdout.writeln(
    '\nNote: this tool only verifies the cli_core → C++ emit step. '
    'Whether the header compiles + links into `ball` is a separate build '
    'step (see cpp/cli/CMakeLists.txt).',
  );
}
