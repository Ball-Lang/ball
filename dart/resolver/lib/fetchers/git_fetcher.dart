/// Fetcher for GitSource — clones a git repo at a specific ref and reads
/// a module file from it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';

Future<Module> fetchGit(GitSource source) async {
  final tempDir = await Directory.systemTemp.createTemp('ball_git_');
  try {
    final cloneResult = await Process.run(
      'git',
      ['clone', '--depth', '1', '--branch', source.ref, source.url, '.'],
      workingDirectory: tempDir.path,
    );
    if (cloneResult.exitCode != 0) {
      // Fallback: clone without --branch (for commit SHAs).
      final fullClone = await Process.run(
        'git',
        ['clone', source.url, '.'],
        workingDirectory: tempDir.path,
      );
      if (fullClone.exitCode != 0) {
        throw StateError(
          'Failed to clone ${source.url}: ${fullClone.stderr}',
        );
      }
      final checkout = await Process.run(
        'git',
        ['checkout', source.ref],
        workingDirectory: tempDir.path,
      );
      if (checkout.exitCode != 0) {
        throw StateError(
          'Failed to checkout ref ${source.ref}: ${checkout.stderr}',
        );
      }
    }

    final filePath = '${tempDir.path}/${source.path}';
    final file = File(filePath);
    if (!file.existsSync()) {
      throw StateError(
        'Module file not found in git repo: ${source.path}',
      );
    }

    final encoding = source.encoding;
    if (encoding == ModuleEncoding.MODULE_ENCODING_PROTO ||
        filePath.endsWith('.ball.bin') ||
        filePath.endsWith('.ball')) {
      return Module.fromBuffer(await file.readAsBytes());
    }
    return Module()
      ..mergeFromProto3Json(
        jsonDecode(await file.readAsString()),
        ignoreUnknownFields: true,
      );
  } finally {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}
