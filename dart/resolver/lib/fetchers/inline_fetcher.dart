/// Fetcher for InlineSource — module data embedded directly in the import.
library;

import 'dart:convert';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';

Module fetchInline(InlineSource source) {
  if (source.hasProtoBytes()) {
    return Module.fromBuffer(source.protoBytes);
  }
  if (source.hasJson()) {
    return Module()
      ..mergeFromProto3Json(jsonDecode(source.json), ignoreUnknownFields: true);
  }
  throw StateError('InlineSource has neither proto_bytes nor json');
}
