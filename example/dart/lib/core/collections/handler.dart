import 'dart:async';

import 'package:ball/ball.dart';
import 'package:ball/core/collections/provider.dart';
import 'package:pub_semver/pub_semver.dart';

class CollectionsCallHandler with BallCallHandlerBase {
  const CollectionsCallHandler() : callHandlerName = 'collections';

  @override
  final String callHandlerName;

  // ignore: non_constant_identifier_names
  Future<void> loop_v0_1_0(Map<String, dynamic> input) async {
    final src =
        input[CollectionsProvider.kForEachInputList] as Iterable<dynamic>;
    final fn = input[CollectionsProvider.kForEachInputFn] as FutureOr<void>
        Function(Map<String, dynamic> input);
    for (final (index, item) in src.indexed) {
      final fnRes = fn({
        CollectionsProvider.kForEachInputFnItem: item,
        CollectionsProvider.kForEachInputFnIndex: index,
      });
      if (fnRes is Future) {
        await fnRes;
      }
    }
  }

  // ignore: non_constant_identifier_names
  Future<Map<String, dynamic>> map_v0_1_0(Map<String, dynamic> input) async {
    final src =
        input[CollectionsProvider.kForEachInputList] as Iterable<dynamic>;
    final fn = input[CollectionsProvider.kForEachInputFn]
        as FutureOr<Map<String, dynamic>?> Function(Map<String, dynamic> input);

    final resList = <dynamic>[];
    for (final (index, item) in src.indexed) {
      final res = fn({
        CollectionsProvider.kMapInputFnItem: item,
        CollectionsProvider.kMapInputFnIndex: index,
      });
      if (res is Future) {
        await res;
      }
      resList.add(res);
    }
    return {
      CollectionsProvider.kMapInputFnOutput: resList,
    };
  }

  @override
  FutureOr<MethodCallResult> handleCall(MethodCallContext context) async {
    final uri = context.methodUri;
    if (!uri.isScheme(kBall) || uri.host != CollectionsProvider.kCollections) {
      return MethodCallResult.notHandled();
    }
    if (uri.pathSegments.isEmpty) {
      return MethodCallResult.notHandled();
    }
    switch (uri.pathSegments.first) {
      case CollectionsProvider.kForEach:
        if (context.defVersionConstraint
            .allows(CollectionsProvider.kForEachV0_1_0)) {
          //do the loop
          await loop_v0_1_0(context.values);

          return MethodCallResult.handled(
            result: {},
            handledBy: callHandlerName,
            //what def version was this handled against
            handlerDefVersion: CollectionsProvider.kForEachV0_1_0,
            //this was handled by a resolver, so it doesn't have version
            handlerVersion: Version.none,
          );
        }
      case CollectionsProvider.kMap:
        if (context.defVersionConstraint
            .allows(CollectionsProvider.kMapV0_1_0)) {
          //do the loop
          final result = await map_v0_1_0(context.values);

          return MethodCallResult.handled(
            result: {
              CollectionsProvider.kMapOutput:
                  result[CollectionsProvider.kMapInputFnOutput],
            },
            handledBy: callHandlerName,
            //what def version was this handled against
            handlerDefVersion: CollectionsProvider.kMapV0_1_0,
            //this was handled by a resolver, so it doesn't have version
            handlerVersion: Version.none,
          );
        }
      default:
    }

    return MethodCallResult.notHandled();
  }
}
