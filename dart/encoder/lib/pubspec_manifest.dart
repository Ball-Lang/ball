/// Structured representation of a Dart package's pubspec.yaml manifest.
class PackageManifest {
  /// Package name from pubspec.yaml.
  final String name;

  /// Package version from pubspec.yaml (e.g. '1.0.0').
  final String version;

  /// Direct dependencies (name → version constraint or path).
  final Map<String, Object?> dependencies;

  /// Dev dependencies.
  final Map<String, Object?> devDependencies;

  /// Package description from pubspec.yaml.
  final String description;

  const PackageManifest({
    required this.name,
    this.version = '0.0.0',
    this.dependencies = const {},
    this.devDependencies = const {},
    this.description = '',
  });
}
