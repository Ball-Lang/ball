import 'package:pub_semver/pub_semver.dart';

import 'body/impl_body.dart';

/// Defins a possible implementation for the function
class BallFunctionImplementation {
  /// The function implementation name, can be the same as the path in [functionUri], but it isn't necessary
  final String name;

  /// Some notes about this implementation
  final String? desc;

  /// A reference to the function
  final Uri functionUri;

  /// The function implementation version, follows semantic versioning.
  final Version version;

  /// The function definition version that this implementation targets.
  /// Examples:
  /// - '>=1.2.3 <2.0.0' == '^1.2.3'
  /// - '>=1.2.3' (bad practice)
  /// - '<2.0.0'
  final VersionConstraint defVersion;

  /// The body of the function, can be empty.
  final List<BallFunctionImplementationBody> body;

  const BallFunctionImplementation({
    required this.name,
    required this.functionUri,
    this.desc,
    required this.version,
    required this.defVersion,
    required this.body,
  });
}
