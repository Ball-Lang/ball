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

  // ignore: non_constant_identifier_names
  static final add2_v1_0_0 = Version(1, 0, 0);

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
      version: add2_v1_0_0,
      inputs: [
        BallArgumentDef(name: kAdd2n1, type: SchemaTypeInfo.$num),
        BallArgumentDef(name: kAdd2n2, type: SchemaTypeInfo.$num),
      ],
      outputs: [
        BallArgumentDef(name: kAdd2Output, type: SchemaTypeInfo.$num),
      ],
    );
  }
}
