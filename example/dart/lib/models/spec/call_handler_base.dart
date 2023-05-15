import 'dart:async';

import 'package:ball/ball.dart';

mixin BallCallHandlerBase {
  String get callHandlerName;

  FutureOr<MethodCallResult> handleCall(MethodCallContext context);
}
