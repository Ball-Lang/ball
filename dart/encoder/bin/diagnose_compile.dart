/// Diagnose why modules fail to compile back to Dart.
import 'dart:io';
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/package_encoder.dart';
import 'package:ball_encoder/pub_client.dart';

Future<void> main(List<String> args) async {
  final name = args.isNotEmpty ? args.first : 'logging';
  final client = PubClient();
  final vi = await client.resolveVersion(name, 'any');
  final pkgDir = await client.downloadPackage(name, vi.version, archiveUrl: vi.archiveUrl);
  final encoder = PackageEncoder(pkgDir);
  final program = encoder.encode();
  final compiler = DartCompiler(program, noFormat: true);

  for (final module in program.modules) {
    final allBase = module.functions.every((f) => f.isBase) && module.functions.isNotEmpty;
    if (allBase) continue;

    final isEmpty = module.functions.isEmpty && module.typeDefs.isEmpty && module.types.isEmpty;
    if (isEmpty) {
      stdout.writeln('  EMPTY STUB: ${module.name}');
      continue;
    }

    try {
      compiler.compileModuleRaw(module.name);
      stdout.writeln('  OK: ${module.name} (${module.functions.length} fns, ${module.typeDefs.length} types)');
    } catch (e) {
      stdout.writeln('  FAIL: ${module.name} (${module.functions.length} fns) — ${e.toString().split('\n').first}');
    }
  }

  try { await pkgDir.delete(recursive: true); } catch (_) {}
  client.close();
}
