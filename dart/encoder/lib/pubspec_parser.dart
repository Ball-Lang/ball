import 'dart:io';

import 'pubspec_manifest.dart';

/// Parses a `pubspec.yaml` file into a [PackageManifest].
///
/// Uses a lightweight line-based parser — no YAML dependency required.
class PubspecParser {
  PubspecParser._();

  /// Parse the `pubspec.yaml` in [dir] and return a [PackageManifest].
  static PackageManifest fromDirectory(Directory dir) {
    final pubspecFile = File(
      '${dir.path}${Platform.pathSeparator}pubspec.yaml',
    );
    if (!pubspecFile.existsSync()) {
      return const PackageManifest(name: 'unknown');
    }
    return fromString(pubspecFile.readAsStringSync());
  }

  /// Parse a pubspec.yaml string into a [PackageManifest].
  static PackageManifest fromString(String content) {
    String? name;
    String? version;
    String? description;

    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('name:')) {
        name = _extractValue(trimmed);
      } else if (trimmed.startsWith('version:')) {
        version = _extractValue(trimmed);
      } else if (trimmed.startsWith('description:')) {
        description = _extractValue(trimmed);
      }
    }

    return PackageManifest(
      name: name ?? 'unknown',
      version: version ?? '0.0.0',
      description: description ?? '',
    );
  }

  static String _extractValue(String line) {
    final colonIdx = line.indexOf(':');
    if (colonIdx < 0) return '';
    var value = line.substring(colonIdx + 1).trim();
    // Strip surrounding quotes if present.
    if ((value.startsWith("'") && value.endsWith("'")) ||
        (value.startsWith('"') && value.endsWith('"'))) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }
}
