import 'package:pub_semver/pub_semver.dart';

import 'function_type.dart';

/// Defines a function
class BallFunctionDef extends FunctionTypeInfo {
  /// Who defined this function? usually the host in the uri
  final String defProviderName;

  /// The name of the function, must be unique per spec file
  final String name;

  /// What this function does
  final String? desc;

  /// The function definition version, follows semantic versioning.
  final Version version;

  const BallFunctionDef({
    required this.name,
    required this.defProviderName,
    this.desc,
    required this.version,
    super.inputs = const [],
    super.outputs = const [],
    super.genericTypeArguments = const [],
  });
}
