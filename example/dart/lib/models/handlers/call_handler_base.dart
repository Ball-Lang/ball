import 'dart:async';

import 'package:ball/ball.dart';

mixin BallCallHandlerBase {
  String get callHandlerName;

  FutureOr<MethodCallResult> handleCall(
    MethodCallContext context,
    Map<String, BallFunctionImplementation?> implementations,
  );

  String? canHandleBallUri({
    required Uri uri,
    required String defProviderName,
  }) {
    if (!uri.isScheme(kBall) || uri.host != defProviderName) {
      return null;
    }
    if (uri.pathSegments.isEmpty) {
      return null;
    }
    return uri.pathSegments.first;
  }
}
