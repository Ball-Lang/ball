import 'consts.dart';

Uri createBallUri(
  String defProviderName,
  String functionName, {
  String? fragment,
  Map<String, dynamic /*String?|Iterable<String>*/ >? queryParameters,
  String? query,
  Iterable<String>? extraPathSegments,
  int? port,
  String? userInfo,
}) {
  return Uri(
    scheme: kBall,
    host: defProviderName,
    port: port,
    userInfo: userInfo,
    pathSegments: [
      functionName,
      ...?extraPathSegments,
    ],
    fragment: fragment,
    queryParameters: queryParameters,
  );
}
