/// Fetcher for HttpSource — downloads a module from an HTTP/HTTPS URL.
library;

import 'dart:convert';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:http/http.dart' as http;

Future<Module> fetchHttp(HttpSource source, {http.Client? client}) async {
  final c = client ?? http.Client();
  final shouldClose = client == null;
  try {
    final uri = Uri.parse(source.url);
    final request = http.Request('GET', uri);
    for (final entry in source.headers.entries) {
      request.headers[entry.key] = entry.value;
    }
    final streamedResponse = await c.send(request);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw StateError(
        'HTTP ${response.statusCode} fetching ${source.url}: '
        '${response.reasonPhrase}',
      );
    }

    final encoding = source.encoding;
    final contentType = response.headers['content-type'] ?? '';

    if (encoding == ModuleEncoding.MODULE_ENCODING_PROTO ||
        contentType.contains('x-protobuf') ||
        source.url.endsWith('.ball.bin') ||
        source.url.endsWith('.ball')) {
      return Module.fromBuffer(response.bodyBytes);
    }
    return Module()
      ..mergeFromProto3Json(
        jsonDecode(response.body),
        ignoreUnknownFields: true,
      );
  } finally {
    if (shouldClose) c.close();
  }
}
