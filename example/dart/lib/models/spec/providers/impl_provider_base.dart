import 'dart:async';

import '../function_impl.dart';

mixin BallFunctionImplementationProviderBase {
  String get implementationsProviderName;

  FutureOr<List<BallFunctionImplementation>> provideImplementations();
}
