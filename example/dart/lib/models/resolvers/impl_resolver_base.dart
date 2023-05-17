import 'dart:async';

import '../def/function_def.dart';
import '../impl/function_impl.dart';

mixin BallFunctionImplementationResolverBase {
  String get implementationsResolverName;

  FutureOr<List<BallFunctionImplementation>> resolveImplementations({
    required BallFunctionDef def,
  });
}
