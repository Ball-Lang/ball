// ignore_for_file: constant_identifier_names

import 'dart:async';

import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

/// This provider provides both Defs and Implementations
class MyFunctionsProvider
    with BallFunctionDefProviderBase, BallFunctionImplementationProviderBase {
  static const kMyFunctions = 'myFunctions';

  const MyFunctionsProvider()
      : defProviderName = kMyFunctions,
        implementationsProviderName = kMyFunctions;

  @override
  final String defProviderName;
  @override
  final String implementationsProviderName;

  static const kAdd3 = 'add3';
  static const kAdd3_x1 = 'x1';
  static const kAdd3_x2 = 'x2';
  static const kAdd3_x3 = 'x3';
  static const kAdd3Output = 'o';

  static const kSum = 'sum';
  static const kSumInputItems = 'items';
  static const kSumOutputResult = 'result';

  @override
  FutureOr<List<BallFunctionDef>> provideDefs() {
    return initDefs().toList();
  }

  @override
  FutureOr<List<BallFunctionImplementation>> provideImplementations() {
    return initImpls().toList();
  }

  Iterable<BallFunctionDef> initDefs() sync* {
    yield BallFunctionDef(
      defProviderName: defProviderName,
      name: kAdd3,
      version: Version(0, 1, 0),
      desc: 'Adds 3 numbers',
      inputs: [
        BallArgumentDef(
          name: kAdd3_x1,
          type: SchemaTypeInfo.$num,
        ),
        BallArgumentDef(
          name: kAdd3_x2,
          type: SchemaTypeInfo.$num,
        ),
        BallArgumentDef(
          name: kAdd3_x3,
          type: SchemaTypeInfo.$num,
        ),
      ],
      outputs: [
        BallArgumentDef(
          name: kAdd3Output,
          type: SchemaTypeInfo.$num,
        ),
      ],
    );

    yield BallFunctionDef(
      defProviderName: defProviderName,
      name: kSum,
      version: Version(0, 0, 1),
      desc: 'Adds an arbitrary amount of numbers',
      inputs: [
        BallArgumentDef(
          name: kSumInputItems,
          desc: "A list of numbers",
          type: SchemaTypeInfo.listOf(SchemaTypeInfo.$num),
        ),
      ],
      outputs: [
        BallArgumentDef(
          name: kSumOutputResult,
          type: SchemaTypeInfo.$num,
        ),
      ],
    );
  }

  Iterable<BallFunctionImplementation> initImpls() sync* {
    final coreAdd2Uri = createBallUri(MathProvider.kMath, MathProvider.kAdd2);
    //Remember that this function takes x1,x2,x3 and outputs o
    yield BallFunctionImplementation(
      functionUri: createBallUri(kMyFunctions, kAdd3),
      name: kAdd3,
      version: Version(0, 0, 1),
      defVersion: VersionConstraint.compatibleWith(Version(0, 1, 0)),
      body: [
        //first sum x1+x2 into z1
        BallCall(
          uri: coreAdd2Uri,
          inputMapping: {
            MathProvider.kAdd2n1: VariableInputMapping(variableName: kAdd3_x1),
            MathProvider.kAdd2n2: VariableInputMapping(variableName: kAdd3_x2),
          },
          outputVariableMapping: {
            MathProvider.kAdd2Output: 'z1',
          },
          constraint:
              VersionConstraint.compatibleWith(MathProvider.add2_v1_0_0),
        ),
        //then sum z1+x3 into o
        BallCall(
          uri: coreAdd2Uri,
          inputMapping: {
            MathProvider.kAdd2n1: VariableInputMapping(variableName: 'z1'),
            MathProvider.kAdd2n2: VariableInputMapping(variableName: kAdd3_x3),
          },
          outputVariableMapping: {
            MathProvider.kAdd2Output: 'z2',
          },
          constraint:
              VersionConstraint.compatibleWith(MathProvider.add2_v1_0_0),
        ),
        //Send z2 as the output
        BallReturn(
          variableName: 'z2',
          outputName: kAdd3Output,
        ),
      ],
    );

    //sum

    yield BallFunctionImplementation(
      defVersion: CollectionsProvider.kForEachV0_1_0,
      name: kSum,
      functionUri: createBallUri(
          CollectionsProvider.kCollections, CollectionsProvider.kForEach),
      version: Version(0, 1, 0),
      desc: "Sums a collection",
      body: [
        //TODO: add sum body
      ],
    );
  }
}
