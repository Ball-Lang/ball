import 'dart:async';

import 'package:pub_semver/pub_semver.dart';

import '../function_def.dart';

/// A provider can provide definations or implementations or both
mixin BallFunctionDefResolverBase {
  String get defResolverName;

  FutureOr<BallFunctionDef?> resolveFunctionDefByUri({
    required Uri functionUri,
    required VersionConstraint constraint,
  });
  
  FutureOr<BallFunctionDef?> resolveFunctionDef({
    required String providerName,
    required String functionName,
    required VersionConstraint constraint,
  });
}
