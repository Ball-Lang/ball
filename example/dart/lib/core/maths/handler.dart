import 'dart:async';

import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

class MathCallHandler with BallCallHandlerBase {
  static const kMath = 'math';
  const MathCallHandler() : callHandlerName = kMath;

  @override
  final String callHandlerName;

  /// The actual implementation of the add2 function v1.0.0
  // ignore: non_constant_identifier_names
  num add2_v1_0_0(num n1, num n2) {
    return n1 + n2;
  }

  @override
  FutureOr<MethodCallResult> handleCall(MethodCallContext context) {
    final uri = context.methodUri;
    if (!uri.isScheme(kBall) || uri.host != MathProvider.kMath) {
      return MethodCallResult.notHandled();
    }
    if (uri.pathSegments.isEmpty) {
      return MethodCallResult.notHandled();
    }
    switch (uri.pathSegments.first) {
      case MathProvider.kAdd2:
        if (context.defVersionConstraint.allows(MathProvider.add2_v1_0_0)) {
          return MethodCallResult.handled(
            result: {
              MathProvider.kAdd2Output: add2_v1_0_0(
                context.values[MathProvider.kAdd2n1] as num,
                context.values[MathProvider.kAdd2n2] as num,
              ),
            },
            handledBy: callHandlerName,
            //what def version was this handled against
            handlerDefVersion: MathProvider.add2_v1_0_0,
            //this was handled by a resolver, so it doesn't have version
            handlerVersion: Version.none,
          );
        }
      default:
    }

    return MethodCallResult.notHandled();
  }
}
