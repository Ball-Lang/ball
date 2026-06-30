<!-- Parent: ../AGENTS.md -->

# ball_rpc (`ball_rpc`)

## Purpose
Dart-target RPC transport runtime that generated `ball_protobuf` service clients delegate to: the canonical status model (`RpcCode`/`RpcException`), metadata, and pluggable transports for the Connect protocol and gRPC-over-HTTP/2, plus an in-memory `FakeTransport` for testing. NOT Ball-portable (uses `dart:io`/`dart:async`).

## Key Files
| File | Description |
|------|-------------|
| `lib/ball_rpc.dart` | Public library entry |
| `lib/src/rpc_transport.dart` | `RpcTransport` abstraction (bytes-level calls) |
| `lib/src/connect_transport.dart` / `connect_codec.dart` | Connect-protocol transport |
| `lib/src/grpc_transport.dart` / `grpc_codec.dart` | gRPC-over-HTTP/2 transport (`GrpcByteSender`) |
| `lib/src/fake_transport.dart` | In-memory transport for tests |
| `lib/src/rpc_code.dart` / `rpc_exception.dart` | Status-code model + exceptions/metadata |

## For AI Agents
- Generated service stubs call into the `RpcTransport` interface — keep its bytes-level contract stable; add protocols as new transport implementations.
- Pairs with `ball_protobuf_gen` (the connect/grpc emitters generate clients that import this). Design context: `docs/PROTOBUF_CODEGEN_PLAN.md`; proto rules: `.claude/rules/proto.md`.
- Tests in `test/` (use `FakeTransport`).

## Dependencies
- Internal: `ball_protobuf`.
- External: `dart:io` / `dart:async` only.
