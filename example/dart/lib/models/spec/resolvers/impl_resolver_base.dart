import 'dart:async';

import '../function_def.dart';
import '../function_impl.dart';

mixin BallFunctionImplementationResolverBase {
  String get implementationsResolverName;

  FutureOr<List<BallFunctionImplementation>> resolveImplementations({
    required BallFunctionDef def,
  });
}
