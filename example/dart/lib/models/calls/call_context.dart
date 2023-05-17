import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

/// Tracks the internal state of method calls
class MethodCallContext {
  /// Maps variable names to their values
  final Map<String, Object?> values;
  final Map<String, TypeInfoBase> genericArgumentAssignments;

  /// Uri of the method to be called
  final Uri methodUri;

  /// Version of the expected function def
  final VersionConstraint defVersionConstraint;

  const MethodCallContext({
    this.values = const {},
    required this.methodUri,
    required this.defVersionConstraint,
    this.genericArgumentAssignments = const {},
  });
}
