import 'dart:async';

import 'package:ball/ball.dart';
import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

class RepositoryBasedResolver
    with
        BallFunctionDefResolverBase,
        BallFunctionImplementationResolverBase,
        NeedsInit {
  final BallRepository repository;

  RepositoryBasedResolver(this.repository);

  final Map<({String providerName, String functionName}),
      Map<Version, BallFunctionDef>> providedFunctions = {};

  @override
  String get defResolverName => "RepositoryBasedResolver";

  @override
  String get implementationsResolverName => "RepositoryBasedResolver";

  @override
  FutureOr<void> init() async {
    for (final entry in repository.providedFunctions
        .groupListsBy((element) => element.defProviderName.toLowerCase())
        .entries) {
      final provider = entry.key;
      final defs = entry.value;

      providedFunctions.addAll(
        defs
            .groupListsBy(
              (element) => (
                providerName: provider,
                functionName: element.name.toLowerCase(),
              ),
            )
            .map(
              (key, value) => MapEntry(
                key,
                value
                    .groupListsBy((element) => element.version)
                    .map((key, value) => MapEntry(key, value.first)),
              ),
            ),
      );
    }
  }

  @override
  FutureOr<BallFunctionDef?> resolveFunctionDef({
    required String providerName,
    required String functionName,
    required VersionConstraint constraint,
  }) {
    ({String functionName, String providerName}) key = (
      providerName: providerName,
      functionName: functionName,
    );
    final defs = providedFunctions[key] ?? {};
    final matches = defs.entries
        //get defs that are allowed by the constraint
        .where((element) => constraint.allows(element.key));
    if (matches.isEmpty) {
      return null;
    }
    //get the primary version out of all the matches
    final primaryVersion = Version.primary(matches.map((e) => e.key).toList());
    return defs[primaryVersion];
  }

  @override
  Future<BallFunctionDef?> resolveFunctionDefByUri({
    required Uri functionUri,
    required VersionConstraint constraint,
  }) async {
    if (!functionUri.isScheme(kBall) || functionUri.pathSegments.isEmpty) {
      return null;
    }
    final providerName = functionUri.host;
    final functionName = functionUri.pathSegments.first;
    return resolveFunctionDef(
      constraint: constraint,
      functionName: functionName,
      providerName: providerName,
    );
  }

  @override
  FutureOr<List<BallFunctionImplementation>> resolveImplementations({
    required BallFunctionDef def,
  }) {
    //
    return repository.providedImplementations
        .where(
          (element) =>
              element.functionUri.scheme == kBall &&
              element.functionUri.host == def.defProviderName.toLowerCase() &&
              element.functionUri.pathSegments.firstOrNull == def.name.toLowerCase() &&
              element.defVersion.allows(def.version),
        )
        .toList();
  }
}
