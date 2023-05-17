import 'dart:async';

import '../impl/function_impl.dart';

mixin BallFunctionImplementationProviderBase {
  String get implementationsProviderName;

  FutureOr<List<BallFunctionImplementation>> provideImplementations();
}
