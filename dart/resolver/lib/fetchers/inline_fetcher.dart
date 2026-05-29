/// Fetcher for InlineSource — module data embedded directly in the import.
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart'
    show decodeModuleBinary, decodeModuleJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';

Module fetchInline(InlineSource source) {
  if (source.hasProtoBytes()) {
    return decodeModuleBinary(source.protoBytes);
  }
  if (source.hasJson()) {
    return decodeModuleJson(jsonDecode(source.json));
  }
  throw StateError('InlineSource has neither proto_bytes nor json');
}
