import 'package:pub_semver/pub_semver.dart';

/// Tracks the internal state of method calls
class MethodCallContext {
  /// Maps variable names to their values
  final Map<String, Object?> values;

  /// Uri of the method to be called
  final Uri methodUri;

  /// Version of the expected function def
  final VersionConstraint defVersionConstraint;

  const MethodCallContext({
    required this.values,
    required this.methodUri,
    required this.defVersionConstraint,
  });
}
