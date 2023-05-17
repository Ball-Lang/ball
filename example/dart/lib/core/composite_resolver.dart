import 'dart:async';

import 'package:ball/ball.dart';
import 'package:ball/models/impl/body/loop.dart';
import 'package:collection/collection.dart';

class CompositeCallHandler with BallCallHandlerBase {
  static const kComposite = 'composite';

  final BallRepository repository;

  const CompositeCallHandler(this.repository) : callHandlerName = kComposite;

  @override
  final String callHandlerName;

  @override
  FutureOr<MethodCallResult> handleCall(
    MethodCallContext context,
    Map<String, BallFunctionImplementation?> implementations,
  ) async {
    //we loop through all available implementations for the first one to handle the call
    final failedResults = <MethodCallResult>[];
    for (var impl in implementations.values.whereNotNull()) {
      final result = await executeImplBody(impl, context);
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
    MethodCallContext context,
  ) async {
    final activeVariables = Map.of(context.values);
    final def = context.def;

    final activeVariableTypes = <String, SchemaTypeInfo>{};
    inferGenericTypes(
      activeVariableTypes: activeVariableTypes,
      genericArgumentAssignments: context.genericArgumentAssignments,
      inputTypes:
          Map.fromEntries(def.inputs.map((e) => MapEntry(e.name, e.type))),
    );
    final outputs = <String, Object?>{};
    return await _executeBody(
      activeVariables: activeVariables,
      activeVariableTypes: activeVariableTypes,
      body: impl.body,
      context: context,
      impl: impl,
      outputs: outputs,
      genericArgumentAssignments: context.genericArgumentAssignments,
    );
  }

  void inferGenericTypes({
    required Map<String, SchemaTypeInfo> genericArgumentAssignments,
    required Map<String, SchemaTypeInfo> inputTypes,
    required Map<String, SchemaTypeInfo> activeVariableTypes,
  }) {
    for (final MapEntry(key: name, value: value) in inputTypes.entries) {
      //value might contain generic values
      activeVariableTypes[name] = inferNewType(
        original: value,
        genericArgumentAssignments: genericArgumentAssignments,
      );
    }
  }

  static SchemaTypeInfo inferNewType({
    required SchemaTypeInfo original,
    required Map<String, SchemaTypeInfo> genericArgumentAssignments,
  }) {
    final assignedValue = genericArgumentAssignments[original.root];
    return SchemaTypeInfo(
      root: assignedValue?.root ?? original.root,
      genericTypeArguments:
          original.genericTypeArguments.map((originalArgument) {
        return BallArgumentDef(
          name: originalArgument.name,
          desc: originalArgument.desc,
          type: inferNewType(
            original: originalArgument.type,
            genericArgumentAssignments: genericArgumentAssignments,
          ),
        );
      }).toList(),
    );
  }

  Future<MethodCallResult> _executeBody({
    required MethodCallContext context,
    required BallFunctionImplementation impl,
    required Map<String, Object?> activeVariables,
    required Map<String, SchemaTypeInfo> activeVariableTypes,
    required Map<String, Object?> outputs,
    required List<BallStepBase> body,
    required Map<String, SchemaTypeInfo> genericArgumentAssignments,
  }) async {
    MethodCallResult handled() => MethodCallResult.handled(
          result: outputs,
          handledBy: impl.name,
          context: context,
          //TODO: infer
          inferredTypeArguments: {},
          handlerVersion: impl.version,
        );
    MethodCallResult notHandled() => MethodCallResult.notHandled();
    void declareVariable({
      required String name,
      required SchemaTypeInfo type,
      Object? value,
    }) {
      activeVariables[name] = value;
      activeVariableTypes[name] = type;
    }

    for (BallStepBase element in body) {
      switch (element) {
        case BallCall(
            uri: final uri,
            inputMapping: final inputMapping,
            defConstraint: final constraint,
            outputVariableMapping: final outputMapping,
          ):
          final subResult = await repository.callFunctionByDef(
            functionUri: uri,
            inputs: resolveInputMapping(
              inputMapping: inputMapping,
              activeVariables: activeVariables,
              activeVariableTypes: activeVariableTypes,
            ),
            versionConstraint: constraint,
          );

          if (subResult.handled) {
            assignOutputsBasedOnMapping(
              declareVariable: declareVariable,
              activeVariables: activeVariables,
              activeVariableTypes: activeVariableTypes,
              mapping: outputMapping,
              result: subResult.result,
              def: subResult.callContext!.def,
            );
          } else if (subResult.failed) {
            return MethodCallResult.error(
              handledBy: callHandlerName,
              context: context,
              handlerVersion: impl.version,
              message: subResult.message,
              error: subResult.error,
              stackTrace: StackTrace.current,
            );
          } else {
            //not handled
            return MethodCallResult.error(
              handledBy: callHandlerName,
              context: context,
              handlerVersion: impl.version,
              message: "subResult wasn't handled",
              error: null,
              stackTrace: StackTrace.current,
            );
          }
        case BallVar(
            name: final name,
            initialValue: final initialValue,
            type: final type,
          ):
          declareVariable(
            name: name,
            type: type,
            value: initialValue,
          );
        case BallReturn(
            outputName: final outputName,
            variableName: final variableName
          ):
          outputs[outputName ?? variableName] = activeVariables[variableName];
        case BallLoopOver(
            iterable: final iterableMapping,
            body: final subBody,
            itemVariableName: final itemVariableName,
            // label: final label
          ):
          final iterableValueMapped = selectInputFromMapping(
            mapping: iterableMapping,
            activeVariables: activeVariables,
            activeVariableTypes: activeVariableTypes,
            shouldBeOfType: null,
          );
          for (final item in iterableValueMapped.value as Iterable) {
            declareVariable(
              name: itemVariableName,
              value: item,
              type: iterableValueMapped.type,
            );
            final bodyRes = await _executeBody(
              context: context,
              impl: impl,
              activeVariables: activeVariables,
              activeVariableTypes: activeVariableTypes,
              outputs: outputs,
              body: subBody,
              genericArgumentAssignments: genericArgumentAssignments,
            );
            if (!bodyRes.handled) {
              return bodyRes;
            }
          }
          activeVariables.remove(itemVariableName);

        case BallLoop(
            body: final subBody,
            // label: final label
          ):
          while (true) {
            final bodyRes = await _executeBody(
              context: context,
              impl: impl,
              activeVariables: activeVariables,
              activeVariableTypes: activeVariableTypes,
              outputs: outputs,
              body: subBody,
              genericArgumentAssignments: genericArgumentAssignments,
            );
            if (!bodyRes.handled) {
              return bodyRes;
            }
          }
        default:
          return notHandled();
      }
    }

    return handled();
  }

  //TODO: should output value and type ?
  ({SchemaTypeInfo type, dynamic value}) selectInputFromMapping({
    required BallInputMappingBase mapping,
    required Map<String, Object?> activeVariables,
    required Map<String, SchemaTypeInfo> activeVariableTypes,
    required SchemaTypeInfo? shouldBeOfType,
  }) {
    switch (mapping) {
      case TypedValueInputMapping(value: final value, type: final type):
        return (value: value, type: type);
      case VariableInputMapping(variableName: final variableName):
        return (
          value: activeVariables[variableName],
          type: activeVariableTypes[variableName] ?? shouldBeOfType!,
        );
      case ValueInputMapping(value: final value):
        return (value: value, type: shouldBeOfType!);

      default:
        throw StateError("$mapping is not supported");
    }
  }

  Map<String, Object?> resolveInputMapping({
    required Map<String, BallInputMappingBase> inputMapping,
    required Map<String, Object?> activeVariables,
    required Map<String, SchemaTypeInfo> activeVariableTypes,
  }) {
    final result = <String, Object?>{};
    for (final element in inputMapping.entries) {
      result[element.key] = selectInputFromMapping(
        activeVariables: activeVariables,
        mapping: element.value,
        activeVariableTypes: activeVariableTypes,
        shouldBeOfType: null,
      ).value;
    }
    return result;
  }

  void assignOutputsBasedOnMapping({
    required Map<String, String> mapping,
    required void Function({
      required String name,
      required SchemaTypeInfo type,
      Object? value,
    }) declareVariable,
    required Map<String, Object?> activeVariables,
    required Map<String, SchemaTypeInfo> activeVariableTypes,
    required Map<String, Object?> result,
    required BallFunctionDef def,
  }) {
    for (final MapEntry(key: oldName, value: value) in result.entries) {
      final newName = mapping[oldName];
      if (newName == null) {
        continue;
      }
      final outputRawTypes = Map.fromEntries(
        def.outputs.map((e) => MapEntry(e.name, e.type)),
      );
      declareVariable(
        name: newName,
        //TODO: change to proper type
        type: SchemaTypeInfo.$dynamic,
        value: value,
      );
    }
  }
}
