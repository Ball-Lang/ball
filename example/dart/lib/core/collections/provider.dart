import 'dart:async';

import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

/// Simulates the core provider
class CollectionsProvider with BallFunctionDefProviderBase {
  static const kCollections = 'collections';
  //Foreach
  static const kForEach = 'foreach';
  static const kForEachInputList = 'inputList';
  static const kForEachInputFn = 'inputFn';
  static const kForEachInputFnIndex = 'index';
  static const kForEachInputFnItem = 'item';
  //Map
  static const kMap = 'map';
  static const kMapInputList = 'inputList';
  static const kMapInputFn = 'inputFn';
  static const kMapInputFnIndex = 'index';
  static const kMapInputFnItem = 'item';
  static const kMapInputFnOutput = 'mappedItem';
  static const kMapOutput = 'mapped';

  static const kMapTInput = 'TInput';
  static const kMapTOutput = 'TOutput';

  static final kForEachV0_1_0 = Version(0, 1, 0);
  static final kMapV0_1_0 = Version(0, 1, 0);
  static final kMapV0_2_0 = Version(0, 2, 0);

  const CollectionsProvider() : defProviderName = kCollections;

  @override
  final String defProviderName;

  @override
  FutureOr<List<BallFunctionDef>> provideDefs() {
    return createDefsSync().toList();
  }

  Iterable<BallFunctionDef> createDefsSync() sync* {
    //foreach v0.1.0
    yield BallFunctionDef(
      defProviderName: defProviderName,
      name: kForEach,
      desc: "Loops over a collection",
      version: kForEachV0_1_0,
      //these arguments are valid types for the rest of the inputs/outputs
      genericTypeArguments: [
        BallArgumentDef(
          name: SchemaTypeInfo.kTValue,
          type: SchemaTypeInfo.$dynamic,
        ),
      ],
      inputs: [
        BallArgumentDef(
          name: kForEachInputList,
          type: SchemaTypeInfo.listOf(
            SchemaTypeInfo(root: SchemaTypeInfo.kTValue),
          ),
        ),
        BallArgumentDef(
          name: kForEachInputFn,
          type: FunctionTypeInfo(
            //This function doesn't output anything
            inputs: [
              BallArgumentDef(
                name: kForEachInputFnIndex,
                type: SchemaTypeInfo.uInt,
              ),
              BallArgumentDef(
                name: kForEachInputFnItem,
                type: SchemaTypeInfo(root: SchemaTypeInfo.kTValue),
              ),
            ],
            outputs: [],
          ),
        ),
      ],
      outputs: [],
    );
    //Map v0.1.0
    yield BallFunctionDef(
      defProviderName: defProviderName,
      name: kMap,
      desc: "Maps a collection to another collection",
      version: kMapV0_1_0,
      //these arguments are valid types for the rest of the inputs/outputs
      genericTypeArguments: [
        BallArgumentDef(
          name: kMapTInput,
          type: SchemaTypeInfo.$dynamic,
        ),
        BallArgumentDef(
          name: kMapTOutput,
          type: SchemaTypeInfo.$dynamic,
        ),
      ],
      inputs: [
        BallArgumentDef(
          name: kMapInputList,
          type: SchemaTypeInfo.listOf(
            SchemaTypeInfo(root: kMapTInput),
          ),
        ),
        BallArgumentDef(
          name: kMapInputFn,
          type: FunctionTypeInfo(
            //This function doesn't output anything
            inputs: [
              BallArgumentDef(
                  name: kMapInputFnIndex, type: SchemaTypeInfo.uInt),
              BallArgumentDef(
                  name: kMapInputFnItem,
                  type: SchemaTypeInfo(root: SchemaTypeInfo.kTValue))
            ],
            outputs: [
              BallArgumentDef(
                name: kMapInputFnOutput,
                type: SchemaTypeInfo(root: kMapTOutput),
              ),
            ],
          ),
        ),
      ],
      outputs: [
        BallArgumentDef(
          name: kMapOutput,
          type: SchemaTypeInfo.listOf(
            SchemaTypeInfo(root: kMapTOutput),
          ),
        ),
      ],
    );
    //Map v0.2.0
    yield BallFunctionDef(
      defProviderName: defProviderName,
      name: kMap,
      desc: "Maps a collection to another collection",
      version: kMapV0_2_0,
      //these arguments are valid types for the rest of the inputs/outputs
      genericTypeArguments: [
        BallArgumentDef(
          name: kMapTInput,
          type: SchemaTypeInfo.$dynamic,
        ),
        BallArgumentDef(
          name: kMapTOutput,
          type: SchemaTypeInfo.$dynamic,
        ),
      ],
      inputs: [
        BallArgumentDef(
          name: kMapInputList,
          type: SchemaTypeInfo.listOf(
            SchemaTypeInfo(root: kMapTInput),
          ),
        ),
        BallArgumentDef(
          name: kMapInputFn,
          type: FunctionTypeInfo(
            //This function doesn't output anything
            inputs: [
              BallArgumentDef(
                name: kMapInputFnItem,
                type: SchemaTypeInfo(root: SchemaTypeInfo.kTValue),
              ),
            ],
            outputs: [
              BallArgumentDef(
                name: kMapInputFnOutput,
                type: SchemaTypeInfo(root: kMapTOutput),
              ),
            ],
          ),
        ),
      ],
      outputs: [
        BallArgumentDef(
          name: kMapOutput,
          type: SchemaTypeInfo.listOf(
            SchemaTypeInfo(root: kMapTOutput),
          ),
        ),
      ],
    );
  }
}
