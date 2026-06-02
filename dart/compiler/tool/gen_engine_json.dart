/// Regenerate `dart/self_host/engine.ball.json` from the current Dart engine
/// source. This is the JSON counterpart of the `.ball.pb` that
/// `compile_engine_cpp.dart` writes.
///
///   cd dart && dart run compiler/tool/gen_engine_json.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart' show encodeBallFileJson;
import 'package:ball_encoder/encoder.dart';
import 'package:ball_encoder/parts_resolver.dart';

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

void main() {
  final root = _findRepoRoot();
  final mainPath = '$root/dart/engine/lib/engine.dart';
  stdout.writeln('Resolving parts + extensions...');
  final src = resolveDartLibrary(mainPath);
  stdout.writeln('  merged source: ${src.length} bytes');
  stdout.writeln('Encoding...');
  final prog = DartEncoder().encode(src, name: 'engine');
  stdout.writeln(
    '  ${prog.modules.length} modules, '
    '${prog.modules.fold<int>(0, (n, m) => n + m.functions.length)} fns, '
    '${prog.modules.fold<int>(0, (n, m) => n + m.typeDefs.length)} typeDefs',
  );

  final jsonMap = encodeBallFileJson(prog);
  final jsonStr = const JsonEncoder.withIndent('  ').convert(jsonMap);
  final outPath = '$root/dart/self_host/engine.ball.json';
  File(outPath).writeAsStringSync(jsonStr);
  stdout.writeln('Wrote ${jsonStr.length} bytes → $outPath');
}
