import 'package:ball/ball.dart';
import 'package:ball/core/maths/handler.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  final repository = BallRepository.withDefaults();
  //my functions
  repository.add(MyFunctionsProvider());

  setUp(() => repository.init());
  group('math', () {
    group('add2', () {
      test("v1_0_0", () async {
        final uri = createBallUri(MathProvider.kMath, MathProvider.kAdd2);
        final output = await repository.callFunctionByDef(
          methodUri: uri,
          versionConstraint:
              VersionConstraint.compatibleWith(MathProvider.v1_0_0),
          inputs: {
            MathProvider.kAdd2n1: 5,
            MathProvider.kAdd2n2: 2,
          },
        );
        expect(output.handled, true);
        expect(output.result[MathProvider.kAdd2Output], 7);
        expect(output.handledBy, MathCallHandler.kMath);
        expect(output.handlerDefVersion, MathProvider.v1_0_0);
        expect(output.handlerVersion, Version.none);
      });
    });
  });

  group("myFunctions", () {
    test('Add3', () async {
      final uri = createBallUri(
          MyFunctionsProvider.kMyFunctions, MyFunctionsProvider.kAdd3);
      final defVersion = Version(0, 1, 0);
      final output = await repository.callFunctionByDef(
        methodUri: uri,
        versionConstraint: VersionConstraint.compatibleWith(defVersion),
        inputs: {
          MyFunctionsProvider.kAdd3_x1: 5,
          MyFunctionsProvider.kAdd3_x2: 2,
          MyFunctionsProvider.kAdd3_x3: 6,
        },
      );
      expect(output.handled, true);
      expect(output.result[MyFunctionsProvider.kAdd3Output], 13);
      expect(output.handledBy, MyFunctionsProvider.kAdd3);
      expect(output.handlerDefVersion, defVersion);
      expect(output.handlerVersion, Version(0, 0, 1));
    });
  });
}
