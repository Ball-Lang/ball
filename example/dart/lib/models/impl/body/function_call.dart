import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

/// Represents a function call
class BallCall extends BallStepBase {
  /// The function name
  final Uri uri;

  /// Maps input argument names with actual values.
  /// The values must conform to the json schema defined in [BallArgumentDef.type]
  final Map<String, BallInputMappingBase> inputMapping;

  /// Maps output arguments from that function to new names to avoid conflicts
  final Map<String, String> outputVariableMapping;

  final VersionConstraint? defConstraint;

  const BallCall({
    required this.uri,
    this.inputMapping = const {},
    this.outputVariableMapping = const {},
    this.defConstraint,
  });
}
