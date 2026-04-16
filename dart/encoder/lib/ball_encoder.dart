/// Dart-to-Ball encoder -- translates Dart source code into Ball programs.
///
/// Provides:
/// - [DartEncoder] -- encodes Dart source into a Ball [Program]
/// - [PackageEncoder] -- encodes a full Dart package directory
/// - [PubspecParser] -- parse/generate pubspec.yaml
/// - [PackageManifest] / [PackageDependency] -- structured pubspec data
/// - [PubClient] -- pub.dev API client for dependency resolution
library;

export 'encoder.dart';
export 'package_encoder.dart';
export 'pub_client.dart';
export 'pubspec_manifest.dart';
export 'pubspec_parser.dart';
