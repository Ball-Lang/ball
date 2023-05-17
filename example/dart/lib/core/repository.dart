import 'dart:async';

import 'package:ball/ball.dart';
import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

class BallRepository {
  BallRepository._();

  factory BallRepository() {
    final res = BallRepository._()
      ..add(MathProvider())
      ..add(MathCallHandler())
      ..add(CollectionsProvider())
      ..add(CollectionsCallHandler());
    res.add(CompositeCallHandler(res));
    res.add(RepositoryBasedResolver(res));
    return res;
  }

  factory BallRepository.empty() {
    final res = BallRepository._();
    return res;
  }
  final defProviders = <BallFunctionDefProviderBase>[];
  final implProviders = <BallFunctionImplementationProviderBase>[];

  final defResolvers = <BallFunctionDefResolverBase>[];
  final implResolvers = <BallFunctionImplementationResolverBase>[];

  final callHandlers = <BallCallHandlerBase>[];

  final List<BallFunctionDef> providedFunctions = [];
  final List<BallFunctionImplementation> providedImplementations = [];

  Future<BallFunctionDef?> resolveFunctionDef({
    required String providerName,
    required String functionName,
    required VersionConstraint constraint,
  }) async {
    for (var element in defResolvers) {
      final result = await element.resolveFunctionDef(
        providerName: providerName,
        functionName: functionName,
        constraint: constraint,
      );
      if (result != null) {
        return result;
      }
    }
    return null;
  }

  Future<BallFunctionDef?> resolveFunctionDefByUri({
    required Uri functionUri,
    required VersionConstraint constraint,
  }) async {
    for (var element in defResolvers) {
      final result = await element.resolveFunctionDefByUri(
        functionUri: functionUri,
        constraint: constraint,
      );
      if (result != null) {
        return result;
      }
    }
    return null;
  }

  Future<List<BallFunctionImplementation>> resolveImplementation({
    required BallFunctionDef def,
  }) async {
    return await Future.wait(
      implResolvers.map(
        (e) async => await e.resolveImplementations(
          def: def,
        ),
      ),
    ).then((value) => value.flattened.toList());
  }

  void add<T>(T part) {
    if (part is BallFunctionDefProviderBase) {
      addDefProvider(part);
    }
    if (part is BallFunctionImplementationProviderBase) {
      addImplProvider(part);
    }
    if (part is BallFunctionDefResolverBase) {
      addDefResolver(part);
    }
    if (part is BallFunctionImplementationResolverBase) {
      addImplResolver(part);
    }

    if (part is BallCallHandlerBase) {
      addHandler(part);
    }
  }

  void addDefProvider(BallFunctionDefProviderBase provider) {
    defProviders.add(provider);
  }

  void addImplProvider(BallFunctionImplementationProviderBase provider) {
    implProviders.add(provider);
  }

  void addDefResolver(BallFunctionDefResolverBase resolver) {
    defResolvers.add(resolver);
  }

  void addImplResolver(BallFunctionImplementationResolverBase resolver) {
    implResolvers.add(resolver);
  }

  void addHandler(BallCallHandlerBase resolver) {
    callHandlers.add(resolver);
  }

  Future<void> _initProvidedDefs() async {
    final provided = await Future.wait(
      defProviders.map(
        (e) async => await e.provideDefs(),
      ),
    ).then((value) => value.flattened);
    providedFunctions.addAll(provided);
  }

  Future<void> _initProvidedImpls() async {
    final provided = await Future.wait(
      implProviders.map(
        (e) async => await e.provideImplementations(),
      ),
    ).then((value) => value.flattened);
    providedImplementations.addAll(provided);
  }

  Future<void> init() async {
    await _initProvidedDefs();
    await _initProvidedImpls();

    for (final element in Iterable.empty()
        .followedBy(defResolvers)
        .followedBy(implResolvers)
        .followedBy(callHandlers)
        .whereType<NeedsInit>()
        .toSet()) {
      await element.init();
    }
  }

  Future<MethodCallResult> callFunctionByDef({
    required Uri methodUri,
    VersionConstraint? versionConstraint,
    Map<String, Object?>? inputs,
    Map<String, SchemaTypeInfo>? genericArgumentAssignments,
  }) async {
    var initialContext = MethodCallContext(
      values: inputs ?? const {},
      genericArgumentAssignments: genericArgumentAssignments ?? const {},
      methodUri: methodUri,
      defVersionConstraint: versionConstraint ?? VersionConstraint.any,
    );
    for (var r in callHandlers) {
      final res = await r.handleCall(initialContext);
      if (res.handled) {
        return res;
      }
    }
    return MethodCallResult.notHandled();
  }
}
