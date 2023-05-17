import 'package:ball/ball.dart';

class BallLoop extends BallLabeledStepBase {
  final List<BallStepBase> body;

  const BallLoop({
    this.body = const [],
    super.label,
  });
}

class BallLoopOver extends BallLoop {
  final BallInputMappingBase iterable;
  final String itemVariableName;

  const BallLoopOver({
    super.body = const [],
    super.label,
    required this.iterable,
    required this.itemVariableName,
  });
}
