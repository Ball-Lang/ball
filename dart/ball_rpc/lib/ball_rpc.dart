/// Dart-target RPC transport runtime for `ball_protobuf` service clients.
///
/// Generated service stubs delegate bytes-level calls to an [RpcTransport]:
/// [ConnectTransport] (Connect protocol over HTTP/1.1), [GrpcTransport]
/// (gRPC-over-HTTP/2 framing + status mapping over a pluggable [GrpcByteSender]),
/// or [FakeTransport] (in-memory, for tests). [RpcCode] is the canonical status
/// model shared by both protocols; failures surface as [RpcException].
///
/// This package is **not** Ball-portable — it uses `dart:io` / `dart:async`.
library;

export 'src/connect_codec.dart';
export 'src/connect_transport.dart';
export 'src/fake_transport.dart';
export 'src/grpc_codec.dart';
export 'src/grpc_transport.dart';
export 'src/rpc_code.dart';
export 'src/rpc_exception.dart';
export 'src/rpc_transport.dart';
