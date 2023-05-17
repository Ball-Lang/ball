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
  final Version? handlerDefVersion;
  // Version of the handler
  final Version? handlerVersion;

  //Maps output name to its value
  final Map<String, Object?> result;

  const MethodCallResult({
    required this.handled,
    required this.result,
    required this.handledBy,
    required this.handlerDefVersion,
    required this.handlerVersion,
    required this.failed,
    required this.error,
    required this.stackTrace,
    required this.message,
  });

  factory MethodCallResult.error({
    String? message,
    Object? error,
    StackTrace? stackTrace,
    required String handledBy,
    required Version handlerDefVersion,
    required Version handlerVersion,
  }) =>
      MethodCallResult(
        failed: true,
        handled: false,
        handledBy: handledBy,
        result: const {},
        handlerDefVersion: handlerDefVersion,
        handlerVersion: handlerVersion,
        error: error,
        message: message,
        stackTrace: stackTrace,
      );

  factory MethodCallResult.notHandled() => MethodCallResult(
        handled: false,
        handledBy: null,
        result: const {},
        handlerDefVersion: null,
        handlerVersion: null,
        error: null,
        stackTrace: null,
        failed: false,
        message: null,
      );

  factory MethodCallResult.handled({
    required Map<String, Object?> result,
    required String handledBy,
    required Version handlerDefVersion,
    required Version handlerVersion,
  }) =>
      MethodCallResult(
        handled: true,
        result: result,
        handledBy: handledBy,
        handlerDefVersion: handlerDefVersion,
        handlerVersion: handlerVersion,
        error: null,
        stackTrace: null,
        message: null,
        failed: false,
      );
}
