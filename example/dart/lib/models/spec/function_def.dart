import 'package:pub_semver/pub_semver.dart';

import 'argument_def.dart';

/// Defines a function
class BallFunctionDef {
  /// Who defined this function? usually the host in the uri
  final String defProviderName;

  /// The name of the function, must be unique per spec file
  final String name;

  /// What this function does
  final String? desc;

  /// The function definition version, follows semantic versioning.
  final Version version;

  /// The input arguments, can be empty
  final List<BallArgumentDef> inputs;

  /// The output arguments, can be empty
  final List<BallArgumentDef> outputs;

  const BallFunctionDef({
    required this.name,
    required this.defProviderName,
    this.desc,
    required this.version,
    this.inputs = const [],
    this.outputs = const [],
  });
}
