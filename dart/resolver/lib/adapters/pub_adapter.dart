/// Registry adapter for pub.dev (Dart/Flutter packages).
///
/// Convention: Ball modules inside pub packages live at `lib/module.ball.bin`
/// (binary) or `lib/module.ball.json` (JSON). Override with `module_path`.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import 'registry_adapter.dart';

class PubAdapter extends RegistryAdapter {
  final http.Client _http;

  PubAdapter({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  @override
  Registry get registryType => Registry.REGISTRY_PUB;

  @override
  String get defaultUrl => 'https://pub.dev';

  @override
  Future<String> resolveVersion(
    String package,
    String constraint, {
    String? registryUrl,
    Map<String, String>? headers,
  }) async {
    final base = registryUrl ?? defaultUrl;
    final uri = Uri.parse('$base/api/packages/$package');
    final response = await _http.get(uri, headers: headers);
    if (response.statusCode != 200) {
      throw StateError(
        'pub: failed to fetch "$package": ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final versions = data['versions'] as List<dynamic>? ?? [];
    final vc = VersionConstraint.parse(constraint.isEmpty ? 'any' : constraint);

    Version? best;
    String? bestStr;
    for (final v in versions) {
      final vStr = (v as Map<String, dynamic>)['version'] as String;
      final ver = Version.parse(vStr);
      if (vc.allows(ver) && (best == null || ver > best)) {
        best = ver;
        bestStr = vStr;
      }
    }
    if (bestStr == null) {
      throw StateError(
        'pub: no version of "$package" matches "$constraint"',
      );
    }
    return bestStr;
  }

  @override
  Future<ResolvedRegistryModule> fetchModule(
    String package,
    String version, {
    String? modulePath,
    ModuleEncoding encoding = ModuleEncoding.MODULE_ENCODING_UNSPECIFIED,
    String? registryUrl,
    Map<String, String>? headers,
  }) async {
    final base = registryUrl ?? defaultUrl;
    final archiveUrl = '$base/api/packages/$package/versions/$version/archive';
    final response = await _http.get(Uri.parse(archiveUrl), headers: headers);
    if (response.statusCode != 200) {
      throw StateError(
        'pub: failed to download $package@$version: ${response.statusCode}',
      );
    }

    final decompressed = GZipDecoder().decodeBytes(response.bodyBytes);
    final tarArchive = TarDecoder().decodeBytes(decompressed);

    final targets = modulePath != null
        ? [modulePath]
        : ['lib/module.ball.bin', 'lib/module.ball.json'];

    for (final target in targets) {
      for (final file in tarArchive) {
        if (!file.isFile) continue;
        // pub archives have a top-level directory; strip it.
        final name = file.name.contains('/')
            ? file.name.substring(file.name.indexOf('/') + 1)
            : file.name;
        if (name == target) {
          final enc = target.endsWith('.bin') || target.endsWith('.ball')
              ? ModuleEncoding.MODULE_ENCODING_PROTO
              : ModuleEncoding.MODULE_ENCODING_JSON;
          return ResolvedRegistryModule(
            bytes: file.content as List<int>,
            encoding: enc,
            resolvedVersion: version,
            sourceUrl: archiveUrl,
          );
        }
      }
    }
    throw StateError(
      'pub: Ball module not found in $package@$version. '
      'Looked for: ${targets.join(", ")}',
    );
  }

  void close() => _http.close();
}
