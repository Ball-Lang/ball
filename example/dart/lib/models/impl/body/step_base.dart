class BallStepBase {
  const BallStepBase();
}

abstract class BallLabeledStepBase extends BallStepBase {
  const BallLabeledStepBase({this.label});
  final String? label;
}
