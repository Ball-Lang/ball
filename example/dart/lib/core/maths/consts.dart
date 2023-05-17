import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

class MathConsts {
  const MathConsts._();

  static const name = 'math';
  static final v1_0_0 = Version(1, 0, 0);
  static const left = 'left';
  static const right = 'right';
}

class MathAdd2Consts {
  MathAdd2Consts._();
  static final Uri uri = createBallUri(MathConsts.name, name);
  static const name = 'add2';
  static const left = MathConsts.left;
  static const right = MathConsts.right;
  static const output = BallConsts.singleOutput;
  static final v1_0_0 = MathConsts.v1_0_0;
}

class MathEqualsConsts {
  MathEqualsConsts._();
  static final Uri uri = createBallUri(MathConsts.name, name);
  static const name = 'equals';
  static const left = MathConsts.left;
  static const right = MathConsts.right;
  static const output = BallConsts.singleOutput;
  static final v1_0_0 = MathConsts.v1_0_0;
}

class MathGreaterThanConsts {
  MathGreaterThanConsts._();
  static final Uri uri = createBallUri(MathConsts.name, name);
  static const name = 'gt';
  static const left = 'left';
  static const right = 'right';
  static const output = BallConsts.singleOutput;
  static final v1_0_0 = MathConsts.v1_0_0;
}

class MathGreaterThanOrEqualsConsts {
  MathGreaterThanOrEqualsConsts._();
  static final Uri uri = createBallUri(MathConsts.name, name);
  static const name = 'gte';
  static const left = MathConsts.left;
  static const right = MathConsts.right;
  static const output = BallConsts.singleOutput;
  static final v1_0_0 = MathConsts.v1_0_0;
}

class MathLessThanConsts {
  MathLessThanConsts._();
  static final Uri uri = createBallUri(MathConsts.name, name);
  static const name = 'lt';
  static const left = MathConsts.left;
  static const right = MathConsts.right;
  static const output = BallConsts.singleOutput;
  static final v1_0_0 = MathConsts.v1_0_0;
}

class MathLessThanOrEqualsConsts {
  MathLessThanOrEqualsConsts._();
  static final Uri uri = createBallUri(MathConsts.name, name);
  static const name = 'lte';
  static const left = MathConsts.left;
  static const right = MathConsts.right;
  static const output = BallConsts.singleOutput;
  static final v1_0_0 = MathConsts.v1_0_0;
}
