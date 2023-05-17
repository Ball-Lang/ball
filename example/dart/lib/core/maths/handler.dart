// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

class MathCallHandler with BallCallHandlerBase {
  static const name = 'mathHandler';
  const MathCallHandler() : callHandlerName = name;

  @override
  final String callHandlerName;

  static final funcNameMap = <(Version, String),
      Map<String, dynamic> Function(Map<String, dynamic> inputs)>{
    (MathConsts.v1_0_0, MathAdd2Consts.name): add2_v1_0_0,
    (MathConsts.v1_0_0, MathEqualsConsts.name): equals_v1_0_0,
    (MathConsts.v1_0_0, MathGreaterThanConsts.name): gt_v1_0_0,
    (MathConsts.v1_0_0, MathGreaterThanOrEqualsConsts.name): gte_v1_0_0,
    (MathConsts.v1_0_0, MathLessThanConsts.name): lt_v1_0_0,
    (MathConsts.v1_0_0, MathLessThanOrEqualsConsts.name): lte_v1_0_0,
  };

  /// The actual implementation of the add2 function v1.0.0
  static Map<String, dynamic> add2_v1_0_0(Map<String, dynamic> inputs) {
    return {
      MathAdd2Consts.output: (inputs[MathAdd2Consts.left] as num) +
          (inputs[MathAdd2Consts.right] as num),
    };
  }

  static Map<String, dynamic> equals_v1_0_0(Map<String, dynamic> inputs) {
    return {
      MathEqualsConsts.output:
          inputs[MathEqualsConsts.left] == inputs[MathEqualsConsts.right],
    };
  }

  static Map<String, dynamic> gt_v1_0_0(Map<String, dynamic> inputs) {
    return {
      MathEqualsConsts.output: (inputs[MathEqualsConsts.left] as num) >
          (inputs[MathEqualsConsts.right] as num),
    };
  }

  static Map<String, dynamic> gte_v1_0_0(Map<String, dynamic> inputs) {
    return {
      MathEqualsConsts.output: (inputs[MathEqualsConsts.left] as num) >=
          (inputs[MathEqualsConsts.right] as num),
    };
  }

  static Map<String, dynamic> lt_v1_0_0(Map<String, dynamic> inputs) {
    return {
      MathEqualsConsts.output: (inputs[MathEqualsConsts.left] as num) <
          (inputs[MathEqualsConsts.right] as num),
    };
  }

  static Map<String, dynamic> lte_v1_0_0(Map<String, dynamic> inputs) {
    return {
      MathEqualsConsts.output: (inputs[MathEqualsConsts.left] as num) <=
          (inputs[MathEqualsConsts.right] as num),
    };
  }

  @override
  FutureOr<MethodCallResult> handleCall(
    MethodCallContext context,
    Map<String, BallFunctionImplementation?> implementations,
  ) {
    final name = canHandleBallUri(
      uri: context.methodUri,
      defProviderName: MathConsts.name,
    );
    if (name == null) {
      return MethodCallResult.notHandled();
    }
    if (context.def.version.allows(MathConsts.v1_0_0)) {
      //handle all of v1
      final res = funcNameMap[(MathConsts.v1_0_0, name)]?.call(context.values);
      if (res == null) {
        return MethodCallResult.notHandled();
      }
      return MethodCallResult.handled(
        result: res,
        handledBy: callHandlerName,
        //what def version was this handled against
        context: context,
        //TODO: infer
        inferredTypeArguments: {},
        //this was handled by a resolver, so it doesn't have version
        handlerVersion: Version.none,
      );
    }
    return MethodCallResult.notHandled();
  }
}
