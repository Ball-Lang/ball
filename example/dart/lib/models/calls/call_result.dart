import 'package:ball/ball.dart';
import 'package:pub_semver/pub_semver.dart';

class MethodCallResult {
  //if the call was supposed failed due to an error
  final bool failed;
  final Object? error;
  final String? message;
  final StackTrace? stackTrace;

  //if the call was handled or not
  final bool handled;

  // Who handled it
  final String? handledBy;

  /// Def version
  final MethodCallContext? callContext;
  
  // Version of the handler
  final Version? handlerVersion;

  //Maps output name to its value
  final Map<String, Object?> result;
  final Map<String, SchemaTypeInfo> inferredTypeArguments;

  const MethodCallResult({
    required this.callContext,
    required this.handled,
    required this.result,
    required this.handledBy,
    required this.handlerVersion,
    required this.failed,
    required this.error,
    required this.stackTrace,
    required this.message,
    required this.inferredTypeArguments,
  });

  factory MethodCallResult.error({
    String? message,
    Object? error,
    StackTrace? stackTrace,
    required String handledBy,
    required MethodCallContext context,
    required Version handlerVersion,
    Map<String, SchemaTypeInfo> inferredTypeArguments = const {}
  }) =>
      MethodCallResult(
        failed: true,
        handled: false,
        handledBy: handledBy,
        result: const {},
        callContext: context,
        handlerVersion: handlerVersion,
        error: error,
        message: message,
        stackTrace: stackTrace,
        inferredTypeArguments: {},
      );

  factory MethodCallResult.notHandled({MethodCallContext? context}) =>
      MethodCallResult(
        handled: false,
        handledBy: null,
        result: const {},
        callContext: context,
        handlerVersion: null,
        error: null,
        stackTrace: null,
        failed: false,
        message: null,
        inferredTypeArguments: {},
      );

  factory MethodCallResult.handled({
    required Map<String, Object?> result,
    required String handledBy,
    required MethodCallContext context,
    required Version handlerVersion,
    required Map<String, SchemaTypeInfo> inferredTypeArguments,
  }) =>
      MethodCallResult(
        handled: true,
        result: result,
        handledBy: handledBy,
        handlerVersion: handlerVersion,
        error: null,
        stackTrace: null,
        message: null,
        failed: false,
        callContext: context,
        inferredTypeArguments: inferredTypeArguments,
      );
}
