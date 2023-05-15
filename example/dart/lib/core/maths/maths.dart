import 'dart:async';

import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

/// Simulates the core provider
class MathProvider with BallFunctionDefProviderBase {
  static const kMath = 'math';

  static const kAdd2 = 'add2';
  static const kAdd2n1 = 'n1';
  static const kAdd2n2 = 'n2';
  static const kAdd2Output = 'o';

  static final v1_0_0 = Version(1, 0, 0);

  const MathProvider() : defProviderName = kMath;

  @override
  final String defProviderName;

  @override
  FutureOr<List<BallFunctionDef>> provideDefs() {
    return createDefsSync().toList();
  }

  Iterable<BallFunctionDef> createDefsSync() sync* {
    yield BallFunctionDef(
      defProviderName: defProviderName,
      name: kAdd2,
      desc: "Adds two numbers",
      version: v1_0_0,
      inputs: [
        BallArgumentDef(name: kAdd2n1, types: [TypeInfo.$num]),
        BallArgumentDef(name: kAdd2n2, types: [TypeInfo.$num]),
      ],
      outputs: [
        BallArgumentDef(name: kAdd2Output, types: [TypeInfo.$num]),
      ],
    );
  }
}
