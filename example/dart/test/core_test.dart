import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  final repository = BallRepository();
  //my functions

  setUp(() => repository.init());

  group('math', () {
    group('V1.0.0', () {
      test('Add2', () async {
        final uri = createBallUri(MathConsts.name, MathAdd2Consts.name);
        final output = await repository.callFunctionByDef(
          functionUri: uri,
          versionConstraint: MathAdd2Consts.v1_0_0,
          inputs: {
            MathAdd2Consts.left: 5,
            MathAdd2Consts.right: 2,
          },
        );
        expect(output.handled, true);
        expect(output.result[MathAdd2Consts.output], 7);
        expect(output.handledBy, MathCallHandler.name);
        expect(output.callContext?.def.version, MathAdd2Consts.v1_0_0);
        expect(output.handlerVersion, Version.none);
      });
      test('equals', () async {
        final uri = createBallUri(MathConsts.name, MathEqualsConsts.name);
        Future<void> baseTest(Object? left, Object? right, bool result) async {
          final output = await repository.callFunctionByDef(
            functionUri: uri,
            versionConstraint: MathEqualsConsts.v1_0_0,
            inputs: {
              MathEqualsConsts.left: left,
              MathEqualsConsts.right: right,
            },
          );
          expect(output.handled, true);
          expect(output.result[MathEqualsConsts.output], result);
          expect(output.handledBy, MathCallHandler.name);
          expect(output.callContext?.def.version, MathEqualsConsts.v1_0_0);
          expect(output.handlerVersion, Version.none);
        }

        await baseTest(10, 10, true);
        await baseTest(10, 5, false);
        await baseTest(null, null, true);
        await baseTest('Hello', null, false);
      });
      group('Compares', () {
        Future<void> baseTest(
          String name,
          num left,
          num right,
          bool result,
        ) async {
          final uri = createBallUri(MathConsts.name, name);
          final output = await repository.callFunctionByDef(
            functionUri: uri,
            versionConstraint: MathConsts.v1_0_0,
            inputs: {
              MathConsts.left: left,
              MathConsts.right: right,
            },
          );
          expect(output.handled, true);
          expect(output.result[BallConsts.singleOutput], result);
          expect(output.handledBy, MathCallHandler.name);
          expect(output.callContext?.def.version, MathConsts.v1_0_0);
          expect(output.handlerVersion, Version.none);
        }

        test('gt', () async {
          await baseTest(MathGreaterThanConsts.name, 10, 5, true);
          await baseTest(MathGreaterThanConsts.name, 5, 10, false);
          await baseTest(MathGreaterThanConsts.name, 10, 10, false);
        });
        test('gte', () async {
          await baseTest(MathGreaterThanOrEqualsConsts.name, 10, 5, true);
          await baseTest(MathGreaterThanOrEqualsConsts.name, 5, 10, false);
          await baseTest(MathGreaterThanOrEqualsConsts.name, 10, 10, true);
        });
        test('lt', () async {
          await baseTest(MathLessThanConsts.name, 10, 5, false);
          await baseTest(MathLessThanConsts.name, 5, 10, true);
          await baseTest(MathLessThanConsts.name, 10, 10, false);
        });
        test('lte', () async {
          await baseTest(MathLessThanOrEqualsConsts.name, 10, 5, false);
          await baseTest(MathLessThanOrEqualsConsts.name, 5, 10, true);
          await baseTest(MathLessThanOrEqualsConsts.name, 10, 10, true);
        });
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
          functionUri: uri,
          versionConstraint: CollectionsProvider.kForEachV0_1_0,
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
          functionUri: uri,
          versionConstraint: CollectionsProvider.kMapV0_1_0,
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
