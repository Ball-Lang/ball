import 'dart:io';

import 'package:yaml/yaml.dart';

import 'pubspec_manifest.dart';

/// Parses `pubspec.yaml` (and optionally `pubspec.lock`) into a
/// [PackageManifest] with fully-populated dependency maps.
class PubspecParser {
  PubspecParser._();

  /// Parse the `pubspec.yaml` in [dir] and return a [PackageManifest].
  /// If `pubspec.lock` exists alongside it, exact resolved versions are
  /// also populated in [PackageManifest.resolvedVersions].
  static PackageManifest fromDirectory(Directory dir) {
    final pubspecFile = File(
      '${dir.path}${Platform.pathSeparator}pubspec.yaml',
    );
    if (!pubspecFile.existsSync()) {
      return const PackageManifest(name: 'unknown');
    }
    final manifest = fromString(pubspecFile.readAsStringSync());

    final lockFile = File(
      '${dir.path}${Platform.pathSeparator}pubspec.lock',
    );
    if (lockFile.existsSync()) {
      return _withLockVersions(manifest, lockFile.readAsStringSync());
    }
    return manifest;
  }

  /// Parse a pubspec.yaml string into a [PackageManifest].
  static PackageManifest fromString(String content) {
    final doc = loadYaml(content);
    if (doc is! YamlMap) return const PackageManifest(name: 'unknown');

    return PackageManifest(
      name: _str(doc['name']) ?? 'unknown',
      version: _str(doc['version']) ?? '0.0.0',
      description: _str(doc['description']) ?? '',
      dependencies: _parseDepsBlock(doc['dependencies']),
      devDependencies: _parseDepsBlock(doc['dev_dependencies']),
    );
  }

  static Map<String, Object?> _parseDepsBlock(Object? block) {
    if (block is! YamlMap) return {};
    final result = <String, Object?>{};
    for (final entry in block.entries) {
      final name = entry.key.toString();
      final value = entry.value;
      if (value is String) {
        result[name] = value;
      } else if (value is YamlMap) {
        result[name] = _yamlToMap(value);
      } else {
        result[name] = value?.toString();
      }
    }
    return result;
  }

  static Map<String, Object?> _yamlToMap(YamlMap m) {
    final result = <String, Object?>{};
    for (final e in m.entries) {
      final v = e.value;
      if (v is YamlMap) {
        result[e.key.toString()] = _yamlToMap(v);
      } else if (v is YamlList) {
        result[e.key.toString()] = v.toList();
      } else {
        result[e.key.toString()] = v;
      }
    }
    return result;
  }

  static PackageManifest _withLockVersions(
    PackageManifest manifest,
    String lockContent,
  ) {
    final doc = loadYaml(lockContent);
    if (doc is! YamlMap) return manifest;
    final packages = doc['packages'];
    if (packages is! YamlMap) return manifest;

    final resolved = <String, String>{};
    for (final entry in packages.entries) {
      final name = entry.key.toString();
      final info = entry.value;
      if (info is YamlMap && info['version'] != null) {
        resolved[name] = info['version'].toString();
      }
    }
    return PackageManifest(
      name: manifest.name,
      version: manifest.version,
      description: manifest.description,
      dependencies: manifest.dependencies,
      devDependencies: manifest.devDependencies,
      resolvedVersions: resolved,
    );
  }

  static String? _str(Object? v) => v?.toString();
}
