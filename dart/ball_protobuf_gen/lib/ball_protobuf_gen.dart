/// ball_protobuf_gen — consumer-model code generator support for the
/// `ball_protobuf` runtime.
///
/// This package owns the **descriptor bridge**: it turns a protoc-emitted
/// `FileDescriptorSet` into the Map-based, Editions-resolved field descriptors
/// that `ball_protobuf`'s codecs consume. It legitimately depends on both
/// `ball_base` (the generated `descriptor.pb.dart` types) and `ball_protobuf`
/// (the runtime + editions resolver), so — unlike the `ball_protobuf` runtime
/// `lib/` — it is **not** Ball-portable.
library;

export 'src/connect_emitter.dart';
export 'src/descriptor_bridge.dart';
export 'src/gen_model.dart';
export 'src/dart_emitter.dart';
export 'src/generator.dart';
export 'src/grpc_emitter.dart';
export 'src/plugin.dart';
export 'src/service_common.dart';
