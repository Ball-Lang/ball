/// Scale validation: encode top pub packages, compile all modules back
/// to Dart, report per-module success rate with error classification.
///
/// Extends the top-20 harness to 100 packages. Automatically skips
/// Flutter-dependent packages (detected via pubspec.yaml). Writes
/// results to CSV at `tests/scale/roundtrip_top100.csv`.
///
///   dart run tool/roundtrip_top100.dart [--filter <name>] [--limit <n>] [--csv <path>]
library;

import 'dart:io';

import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';

/// Pure-Dart packages from pub.dev popularity ranking. Flutter-only
/// packages (shared_preferences, flutter_svg, etc.) are excluded.
/// Packages that straddle (e.g. `equatable`, `bloc`, `dio`) are
/// included — the encoder handles pure-Dart code paths fine.
const _packages = [
  // ── Already validated (top-20) ──
  'path', 'collection', 'meta', 'async', 'crypto',
  'convert', 'logging', 'args', 'string_scanner', 'stack_trace',
  'source_span', 'typed_data', 'term_glyph', 'matcher',
  'boolean_selector', 'pool', 'yaml', 'glob', 'watcher', 'shelf',
  // ── New additions (21-100) ──
  'http', 'uuid', 'dio', 'equatable', 'json_serializable',
  'json_annotation', 'build_runner', 'build', 'analyzer', 'test',
  'test_api', 'test_core', 'bloc', 'mime', 'retry',
  'characters', 'xml', 'petitparser', 'archive', 'shelf_router',
  'shelf_static', 'http_parser', 'http_multi_server', 'stream_channel',
  'pub_semver', 'package_config', 'watcher', 'graphs', 'timing',
  'protobuf', 'fixnum', 'grpc', 'web_socket_channel', 'io',
  'cli_util', 'frontend_server_client', 'vm_service', 'sse',
  'usage', 'checked_yaml', 'source_gen', 'build_config',
  'build_resolvers', 'build_modules', 'build_daemon',
  'code_builder', 'dart_style', 'quiver', 'rxdart', 'dartz',
  'freezed_annotation', 'freezed', 'json_path', 'oauth2',
  'shelf_web_socket', 'process', 'ansicolor', 'tuple',
  'string_similarity', 'recase', 'intl', 'sprintf',
  'csv', 'markdown', 'mustache_template', 'html',
  'pub_updater', 'mason_logger', 'very_good_analysis',
  'git', 'platform', 'file', 'process_run',
  'clock', 'fake_async', 'mockito', 'mocktail',
  'ffi', 'win32', 'path_parsing', 'vector_math',
  'benchmark_harness', 'stack_trace', 'lints',
  'pedantic', 'effective_dart',
];

enum ErrorKind { none, encoderError, compilerError, formatError, timeout, flutter }

class PackageResult {
  final String name;
  final String version;
  final int modulesTotal;
  final int modulesCompiled;
  final ErrorKind errorKind;
  final String errorMessage;

  PackageResult({
    required this.name,
    this.version = '',
    this.modulesTotal = 0,
    this.modulesCompiled = 0,
    this.errorKind = ErrorKind.none,
    this.errorMessage = '',
  });

  String toCsv() =>
      '$name,$version,$modulesTotal,$modulesCompiled,${errorKind.name},"${errorMessage.replaceAll('"', '""')}"';
}

Future<void> main(List<String> args) async {
  final filterIdx = args.indexOf('--filter');
  final filterName = filterIdx >= 0 && filterIdx + 1 < args.length
      ? args[filterIdx + 1]
      : null;
  final limitIdx = args.indexOf('--limit');
  final limit = limitIdx >= 0 && limitIdx + 1 < args.length
      ? int.parse(args[limitIdx + 1])
      : _packages.length;
  final csvIdx = args.indexOf('--csv');

  // Deduplicate the list.
  final seen = <String>{};
  final packages = <String>[];
  for (final p in _packages) {
    if (seen.add(p) &&
        (filterName == null || p.contains(filterName))) {
      packages.add(p);
    }
    if (packages.length >= limit) break;
  }

  String repoRoot = _findRepoRoot();
  final csvDir = Directory('$repoRoot/tests/scale');
  if (!csvDir.existsSync()) csvDir.createSync(recursive: true);
  final csvPath = csvIdx >= 0 && csvIdx + 1 < args.length
      ? args[csvIdx + 1]
      : '${csvDir.path}/roundtrip_top100.csv';

  final client = PubClient();
  final results = <PackageResult>[];
  var totalModules = 0;
  var compiledModules = 0;
  var fullSuccess = 0;
  var skipped = 0;

  stdout.writeln('Ball Scale Validation: Top ${packages.length} pub packages');
  stdout.writeln('=' * 60);

  for (var i = 0; i < packages.length; i++) {
    final name = packages[i];
    stdout.write('  [${i + 1}/${packages.length}] $name... ');
    try {
      final vi = await client.resolveVersion(name, 'any');

      // Download.
      final pkgDir = await client.downloadPackage(
        name,
        vi.version,
        archiveUrl: vi.archiveUrl,
      );

      // Check for Flutter dependency → skip.
      final pubspec = File('${pkgDir.path}/pubspec.yaml');
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        if (content.contains('flutter:') &&
            content.contains('sdk: flutter')) {
          stdout.writeln('SKIP (Flutter) v${vi.version}');
          results.add(PackageResult(
            name: name,
            version: vi.version,
            errorKind: ErrorKind.flutter,
            errorMessage: 'Requires Flutter SDK',
          ));
          skipped++;
          try { await pkgDir.delete(recursive: true); } catch (_) {}
          continue;
        }
      }

      // Encode.
      final encoder = PackageEncoder(pkgDir);
      final program = encoder.encode();

      // Compile.
      final compiler = DartCompiler(program, noFormat: true);
      final modules = compiler.compileAllModules();

      final contentModules = program.modules.where((m) {
        final allBase =
            m.functions.every((f) => f.isBase) && m.functions.isNotEmpty;
        if (allBase) return false;
        if (m.functions.isEmpty &&
            m.typeDefs.isEmpty &&
            m.types.isEmpty) return false;
        if (m.name == '__assets__') return false;
        return true;
      }).length;

      totalModules += contentModules;
      compiledModules += modules.length;
      if (modules.length >= contentModules) fullSuccess++;

      final stubs = program.modules.length -
          contentModules -
          program.modules
              .where((m) =>
                  m.functions.every((f) => f.isBase) &&
                  m.functions.isNotEmpty)
              .length;
      stdout.writeln(
          '${modules.length}/$contentModules OK, $stubs stubs (v${vi.version})');
      results.add(PackageResult(
        name: name,
        version: vi.version,
        modulesTotal: contentModules,
        modulesCompiled: modules.length,
      ));

      try { await pkgDir.delete(recursive: true); } catch (_) {}
    } catch (e) {
      final msg = e.toString().split('\n').first;
      final kind = msg.contains('Encoder')
          ? ErrorKind.encoderError
          : msg.contains('format')
              ? ErrorKind.formatError
              : ErrorKind.compilerError;
      stdout.writeln('FAIL: $msg');
      results.add(PackageResult(
        name: name,
        errorKind: kind,
        errorMessage: msg,
      ));
    }
  }

  stdout.writeln();
  stdout.writeln('=' * 60);
  final tested = results.length - skipped;
  stdout.writeln('Packages: $fullSuccess/$tested fully compiled ($skipped skipped)');
  stdout.writeln('Modules: $compiledModules/$totalModules compiled');
  final pct = totalModules == 0
      ? 0.0
      : compiledModules * 100.0 / totalModules;
  stdout.writeln('Module compile rate: ${pct.toStringAsFixed(1)}%');

  // Write CSV.
  final csvFile = File(csvPath);
  final csvBuf = StringBuffer();
  csvBuf.writeln('package,version,modules_total,modules_compiled,error_kind,error_message');
  for (final r in results) {
    csvBuf.writeln(r.toCsv());
  }
  csvFile.writeAsStringSync(csvBuf.toString());
  stdout.writeln('CSV written → ${csvPath.replaceAll('\\', '/')}');

  client.close();
}

String _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path.replaceAll('\\', '/');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return Directory.current.path;
    dir = parent;
  }
}
