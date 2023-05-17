import 'dart:async';

import 'package:ball/ball.dart';

/// Simulates the core provider
class MathProvider with BallFunctionDefProviderBase {
  const MathProvider() : defProviderName = MathConsts.name;

  @override
  final String defProviderName;

  @override
  FutureOr<List<BallFunctionDef>> provideDefs() {
    return createDefsSync().toList();
  }

  Iterable<BallFunctionDef> createDefsSync() sync* {
    yield BallFunctionDef(
      defProviderName: defProviderName,
      name: MathAdd2Consts.name,
      desc: "Adds two numbers",
      version: MathConsts.v1_0_0,
      inputs: [
        BallArgumentDef(name: MathAdd2Consts.left, type: SchemaTypeInfo.$num),
        BallArgumentDef(name: MathAdd2Consts.right, type: SchemaTypeInfo.$num),
      ],
      outputs: [
        BallArgumentDef(
          name: MathAdd2Consts.output,
          type: SchemaTypeInfo.$num,
        ),
      ],
    );

    yield BallFunctionDef(
      defProviderName: defProviderName,
      name: MathEqualsConsts.name,
      desc: "Compares two objects",
      version: MathConsts.v1_0_0,
      inputs: [
        BallArgumentDef(
          name: MathEqualsConsts.left,
          type: SchemaTypeInfo.$dynamic,
        ),
        BallArgumentDef(
          name: MathEqualsConsts.right,
          type: SchemaTypeInfo.$dynamic,
        ),
      ],
      outputs: [
        BallArgumentDef(
          name: MathEqualsConsts.output,
          type: SchemaTypeInfo.$bool,
        ),
      ],
    );

    final compareFuncs = [
      [MathGreaterThanConsts.name, "Greater than"],
      [MathGreaterThanOrEqualsConsts.name, "Greater than or equals"],
      [MathLessThanConsts.name, "Less than"],
      [MathLessThanOrEqualsConsts.name, "Less than or equals"],
    ];
    for (final [name, desc] in compareFuncs) {
      yield BallFunctionDef(
        defProviderName: defProviderName,
        name: name,
        desc: desc,
        version: MathConsts.v1_0_0,
        inputs: [
          BallArgumentDef(
            name: MathEqualsConsts.left,
            type: SchemaTypeInfo.$num,
          ),
          BallArgumentDef(
            name: MathEqualsConsts.right,
            type: SchemaTypeInfo.$num,
          ),
        ],
        outputs: [
          BallArgumentDef(
            name: MathEqualsConsts.output,
            type: SchemaTypeInfo.$bool,
          ),
        ],
      );
    }
  }
}
