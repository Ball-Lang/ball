/// Fetcher for FileSource — loads a module from a local filesystem path.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';

Module fetchFile(FileSource source, {String? basePath}) {
  var filePath = source.path;
  if (basePath != null && !File(filePath).isAbsolute) {
    filePath = '$basePath/$filePath';
  }
  final file = File(filePath);
  if (!file.existsSync()) {
    throw StateError('File not found: $filePath');
  }

  final encoding = source.encoding;
  if (encoding == ModuleEncoding.MODULE_ENCODING_PROTO ||
      filePath.endsWith('.ball.bin') ||
      filePath.endsWith('.ball')) {
    return Module.fromBuffer(file.readAsBytesSync());
  }
  return Module()
    ..mergeFromProto3Json(
      jsonDecode(file.readAsStringSync()),
      ignoreUnknownFields: true,
    );
}
