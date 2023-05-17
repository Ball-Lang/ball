import 'dart:async';

import 'package:ball/ball.dart';
import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

class CompositeCallHandler with BallCallHandlerBase {
  static const kComposite = 'composite';

  final BallRepository repository;

  const CompositeCallHandler(this.repository) : callHandlerName = kComposite;

  @override
  final String callHandlerName;

  @override
  FutureOr<MethodCallResult> handleCall(MethodCallContext context) async {
    //we get all implementations related to the host

    final def = await repository.resolveFunctionDefByUri(
      functionUri: context.methodUri,
      constraint: context.defVersionConstraint,
    );
    if (def == null) {
      return MethodCallResult.notHandled();
    }
    final implementations = await repository.resolveImplementation(def: def);

    if (implementations.isEmpty) {
      return MethodCallResult.notHandled();
    }

    //we loop through all available implementations for the first one to handle the call
    final failedResults = <MethodCallResult>[];
    for (var impl in implementations
        .sorted((a, b) => Version.prioritize(a.version, b.version))) {
      final result = await executeImplBody(impl, def, context);
      if (result.handled) {
        return result;
      } else if (result.failed) {
        failedResults.add(result);
      }
    }
    return MethodCallResult.notHandled();
  }

  Future<MethodCallResult> executeImplBody(
    BallFunctionImplementation impl,
    BallFunctionDef def,
    MethodCallContext context,
  ) async {
    final activeVariables = Map.of(context.values);
    final newVariableTypes = <String, List<SchemaTypeInfo>>{};
    final outputs = <String, Object?>{};
    for (BallFunctionImplementationBody element in impl.body) {
      switch (element) {
        case BallFunctionCall(
            uri: final uri,
            inputMapping: final inputMapping,
            constraint: final constraint,
            outputVariableMapping: final outputMapping,
          ):
          final subResult = await repository.callFunctionByDef(
            methodUri: uri,
            inputs: resolveInputMapping(
              inputMapping: inputMapping,
              activeVariables: activeVariables,
            ),
            versionConstraint: constraint,
          );
          if (subResult.handled) {
            assignOutputsBasedOnMapping(
              activeVariables: activeVariables,
              mapping: outputMapping,
              result: subResult.result,
            );
          } else if (subResult.failed) {
            return MethodCallResult.error(
              handledBy: callHandlerName,
              handlerDefVersion: def.version,
              handlerVersion: impl.version,
              message: subResult.message,
              error: subResult.error,
              stackTrace: StackTrace.current,
            );
          } else {
            //not handled
            return MethodCallResult.error(
              handledBy: callHandlerName,
              handlerDefVersion: def.version,
              handlerVersion: impl.version,
              message: "subResult wasn't handled",
              error: null,
              stackTrace: StackTrace.current,
            );
          }
        case BallDeclareVariable(
            name: final name,
            initialValue: final initialValue,
            types: final types,
          ):
          activeVariables[name] = initialValue;
          newVariableTypes[name] = types;
        case BallGiveOutput(
            outputName: final outputName,
            variableName: final variableName
          ):
          outputs[outputName] = activeVariables[variableName ?? outputName];
        default:
      }
    }
    return MethodCallResult.handled(
      result: outputs,
      handledBy: impl.name,
      handlerDefVersion: def.version,
      handlerVersion: impl.version,
    );
  }

  Map<String, Object?> resolveInputMapping({
    required Map<String, BallFunctionCallInputMappingBase> inputMapping,
    required Map<String, Object?> activeVariables,
  }) {
    final result = <String, Object?>{};
    for (final element in inputMapping.entries) {
      switch (element.value) {
        case ValueInputMapping(value: final value):
          result[element.key] = value;
        case VariableInputMapping(variableName: final variableName):
          result[element.key] = activeVariables[variableName];
        default:
      }
    }
    return result;
  }

  void assignOutputsBasedOnMapping({
    required Map<String, String> mapping,
    required Map<String, Object?> activeVariables,
    required Map<String, Object?> result,
  }) {
    for (var entry in result.entries) {
      final newName = mapping[entry.key];
      if (newName == null) {
        continue;
      }
      activeVariables[newName] = entry.value;
    }
  }
}
