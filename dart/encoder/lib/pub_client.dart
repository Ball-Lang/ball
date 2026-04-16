/// Minimal pub.dev API client for downloading package sources.
///
/// Implements the pub repository spec v2 endpoints needed to resolve
/// version constraints and download package archives.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

/// Information about a single package version from the pub API.
class PubVersionInfo {
  final String version;
  final String archiveUrl;

  const PubVersionInfo({required this.version, required this.archiveUrl});
}

/// Lightweight pub.dev API client.
class PubClient {
  final String registryUrl;
  final http.Client _http;

  PubClient({
    this.registryUrl = 'https://pub.dev',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Fetch all versions of a package.
  Future<List<PubVersionInfo>> getVersions(String packageName) async {
    final url = Uri.parse('$registryUrl/api/packages/$packageName');
    final response = await _http.get(url);
    if (response.statusCode != 200) {
      throw StateError(
        'Failed to fetch package "$packageName" from $registryUrl: '
        '${response.statusCode} ${response.reasonPhrase}',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final versions = data['versions'] as List<dynamic>? ?? [];
    return versions.map((v) {
      final map = v as Map<String, dynamic>;
      return PubVersionInfo(
        version: map['version'] as String,
        archiveUrl: map['archive_url'] as String? ??
            '$registryUrl/api/packages/$packageName/versions/${map['version']}/archive',
      );
    }).toList();
  }

  /// Resolve a semver constraint to the best (highest) matching version.
  Future<PubVersionInfo> resolveVersion(
    String packageName,
    String constraint,
  ) async {
    final versions = await getVersions(packageName);
    final vc = VersionConstraint.parse(constraint);

    PubVersionInfo? best;
    Version? bestVersion;
    for (final info in versions) {
      final v = Version.parse(info.version);
      if (vc.allows(v)) {
        if (bestVersion == null || v > bestVersion) {
          best = info;
          bestVersion = v;
        }
      }
    }
    if (best == null) {
      throw StateError(
        'No version of "$packageName" matches constraint "$constraint". '
        'Available: ${versions.map((v) => v.version).join(', ')}',
      );
    }
    return best;
  }

  /// Download and extract a package archive to a temporary directory.
  /// Returns the path to the extracted package root.
  Future<Directory> downloadPackage(
    String packageName,
    String version, {
    String? archiveUrl,
  }) async {
    final url = archiveUrl ??
        '$registryUrl/api/packages/$packageName/versions/$version/archive';
    final response = await _http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw StateError(
        'Failed to download $packageName@$version: '
        '${response.statusCode} ${response.reasonPhrase}',
      );
    }

    final archive = GZipDecoder().decodeBytes(response.bodyBytes);
    final tarArchive = TarDecoder().decodeBytes(archive);

    final tempDir = await Directory.systemTemp.createTemp('ball_pub_');
    for (final file in tarArchive) {
      if (file.isFile) {
        final outFile = File('${tempDir.path}/${file.name}');
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      }
    }
    return tempDir;
  }

  void close() => _http.close();
}
