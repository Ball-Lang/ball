import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'custom_showcase/_exports.dart';

void main() {
  final repository = BallRepository();
  repository.add(MyFunctionsProvider());

  setUp(() => repository.init());

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
    test('Sum', () async {});
  });
}
