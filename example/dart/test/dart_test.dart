import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  final repository = BallRepository();
  //my functions

  setUp(() => repository.init());

  group('math', () {
    group('add2', () {
      test("v1_0_0", () async {
        final uri = createBallUri(MathProvider.kMath, MathProvider.kAdd2);
        final output = await repository.callFunctionByDef(
          methodUri: uri,
          versionConstraint:
              VersionConstraint.compatibleWith(MathProvider.add2_v1_0_0),
          inputs: {
            MathProvider.kAdd2n1: 5,
            MathProvider.kAdd2n2: 2,
          },
        );
        expect(output.handled, true);
        expect(output.result[MathProvider.kAdd2Output], 7);
        expect(output.handledBy, MathCallHandler.kMath);
        expect(output.handlerDefVersion, MathProvider.add2_v1_0_0);
        expect(output.handlerVersion, Version.none);
      });
    });
  });

  group("collections", () {
    group('foreach', () {
      test("v0_1_0", () async {
        final uri = createBallUri(
            CollectionsProvider.kCollections, CollectionsProvider.kForEach);

        final inputs = [6, 7, 9];
        final loopResult = <int>[];

        final result = await repository.callFunctionByDef(
          methodUri: uri,
          versionConstraint: VersionConstraint.compatibleWith(
            CollectionsProvider.kForEachV0_1_0,
          ),
          genericArgumentAssignments: {
            SchemaTypeInfo.kTValue: SchemaTypeInfo.$int,
          },
          inputs: {
            CollectionsProvider.kForEachInputList: inputs,
            CollectionsProvider.kForEachInputFn: (Map<String, dynamic> input) {
              loopResult.add(input[CollectionsProvider.kForEachInputFnItem]);
            },
          },
        );
        expect(result.handled, true);
        expect(loopResult, inputs);
      });
    });
    group("map", () {
      test("v0_1_0", () async {
        final uri = createBallUri(
          CollectionsProvider.kCollections,
          CollectionsProvider.kMap,
        );

        final inputs = [6, 7, 9];
        // final loopResult = <int>[];

        final result = await repository.callFunctionByDef(
          methodUri: uri,
          versionConstraint: VersionConstraint.compatibleWith(
            CollectionsProvider.kMapV0_1_0,
          ),
          genericArgumentAssignments: {
            CollectionsProvider.kMapTInput: SchemaTypeInfo.$int,
            CollectionsProvider.kMapTOutput: SchemaTypeInfo.string,
          },
          inputs: {
            CollectionsProvider.kMapInputList: inputs,
            CollectionsProvider.kMapInputFn: (Map<String, dynamic> input) {
              return <String, dynamic>{
                CollectionsProvider.kMapInputFnOutput:
                    input[CollectionsProvider.kMapInputFnItem].toString()
              };
            },
          },
        );
        expect(result.handled, true);
        final resMap =
            result.result[CollectionsProvider.kMapOutput] as Iterable;

        expect(
          resMap
              .cast<Map<String, dynamic>>()
              .map((e) => e[CollectionsProvider.kMapInputFnOutput])
              .toList(),
          inputs.map((e) => e.toString()).toList(),
        );
      });
    });
  });
}
