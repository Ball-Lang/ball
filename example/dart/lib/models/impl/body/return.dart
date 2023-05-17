import 'step_base.dart';

class BallReturn extends BallStepBase {
  final String variableName;
  final String? outputName;

  const BallReturn({
    required this.variableName,
    this.outputName,
  });
}
