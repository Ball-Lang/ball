/// Ball protobuf library — complete protobuf support written in pure Dart.
/// When encoded to Ball IR, provides protobuf for any target language.
library;

export 'wire_varint.dart';
export 'wire_fixed.dart';
export 'wire_bytes.dart';
export 'field_int.dart';
export 'field_fixed.dart';
export 'field_len.dart';
export 'marshal.dart';
export 'unmarshal.dart';
export 'json_codec.dart';
export 'well_known.dart';
export 'editions.dart';
export 'grpc_frame.dart';
// conformance.dart excluded — uses dart:io, not Ball-portable
