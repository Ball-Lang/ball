/// Registry adapter for npm (JavaScript/TypeScript packages).
///
/// Convention: Ball modules inside npm packages live at `package/module.ball.bin`
/// or `package/module.ball.json`. Override with `module_path`.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import 'registry_adapter.dart';

class NpmAdapter extends RegistryAdapter {
  final http.Client _http;

  NpmAdapter({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  @override
  Registry get registryType => Registry.REGISTRY_NPM;

  @override
  String get defaultUrl => 'https://registry.npmjs.org';

  @override
  Future<String> resolveVersion(
    String package,
    String constraint, {
    String? registryUrl,
    Map<String, String>? headers,
  }) async {
    final base = registryUrl ?? defaultUrl;
    final uri = Uri.parse('$base/$package');
    final reqHeaders = {'Accept': 'application/json', ...?headers};
    final response = await _http.get(uri, headers: reqHeaders);
    if (response.statusCode != 200) {
      throw StateError(
        'npm: failed to fetch "$package": ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final versions = data['versions'] as Map<String, dynamic>? ?? {};
    final vc = VersionConstraint.parse(constraint.isEmpty ? 'any' : constraint);

    Version? best;
    String? bestStr;
    for (final vStr in versions.keys) {
      try {
        final ver = Version.parse(vStr);
        if (vc.allows(ver) && (best == null || ver > best)) {
          best = ver;
          bestStr = vStr;
        }
      } catch (_) {
        // Skip invalid semver versions.
      }
    }
    if (bestStr == null) {
      throw StateError(
        'npm: no version of "$package" matches "$constraint"',
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
    // Get the tarball URL from the version metadata.
    final metaUri = Uri.parse('$base/$package/$version');
    final metaResp = await _http.get(metaUri, headers: headers);
    if (metaResp.statusCode != 200) {
      throw StateError(
        'npm: failed to fetch metadata for $package@$version: '
        '${metaResp.statusCode}',
      );
    }
    final meta = jsonDecode(metaResp.body) as Map<String, dynamic>;
    final dist = meta['dist'] as Map<String, dynamic>? ?? {};
    final tarballUrl = dist['tarball'] as String? ??
        '$base/$package/-/$package-$version.tgz';

    final response = await _http.get(Uri.parse(tarballUrl), headers: headers);
    if (response.statusCode != 200) {
      throw StateError(
        'npm: failed to download $package@$version: ${response.statusCode}',
      );
    }

    final decompressed = GZipDecoder().decodeBytes(response.bodyBytes);
    final tarArchive = TarDecoder().decodeBytes(decompressed);

    final targets = modulePath != null
        ? [modulePath, 'package/$modulePath']
        : ['package/module.ball.bin', 'package/module.ball.json'];

    for (final target in targets) {
      for (final file in tarArchive) {
        if (!file.isFile) continue;
        if (file.name == target) {
          final enc = target.endsWith('.bin') || target.endsWith('.ball')
              ? ModuleEncoding.MODULE_ENCODING_PROTO
              : ModuleEncoding.MODULE_ENCODING_JSON;
          return ResolvedRegistryModule(
            bytes: file.content as List<int>,
            encoding: enc,
            resolvedVersion: version,
            sourceUrl: tarballUrl,
          );
        }
      }
    }
    throw StateError(
      'npm: Ball module not found in $package@$version. '
      'Looked for: ${targets.join(", ")}',
    );
  }

  void close() => _http.close();
}
