# ball_rpc

Dart-target RPC transport runtime for `ball_protobuf` service clients. Generated
service stubs (from `ball_protobuf_gen`'s service plugins) delegate bytes-level
calls to an `RpcTransport`; this package supplies the transports and the shared
status model.

> **Not Ball-portable.** Unlike `ball_protobuf` (which is pure
> `dart:core`/`convert`/`typed_data` so it can be encoded to Ball IR and run on
> every target), `ball_rpc` is Dart-target runtime support and uses `dart:io` /
> `dart:async`.

## Status model — `RpcCode`

The 17 canonical codes (`0`..`16`) are the gRPC status-code set. Each carries:

- `value` — the integer gRPC status code (verified against the
  [gRPC status-code list](https://grpc.github.io/grpc/core/md_doc_statuscodes.html)).
- `connectName` — the Connect-protocol `lower_snake_case` string name (verified
  against the [Connect protocol error table](https://connectrpc.com/docs/protocol/#error-codes)).

`RpcCode.fromValue(int)` and `RpcCode.fromConnectName(String)` are the inverse
lookups; both map anything unrecognized to `RpcCode.unknown`.

> **Spelling note:** code `1` is `RpcCode.cancelled` (matching the gRPC
> `CANCELLED` constant) but its Connect wire name is `canceled` (single `l`).

Failures surface as `RpcException(code, message, {details, metadata})`.
`RpcMetadata` is `Map<String, String>`.

## Transports

All transports implement `RpcTransport`, which has bytes-level methods for the
four method kinds: `unary`, `serverStream`, `clientStream`, `bidiStream`.

### `ConnectTransport` (Connect protocol, HTTP/1.1 via `dart:io`)

- **Unary:** `POST {baseUrl}/{package}.{Service}/{Method}`, `content-type:
  application/proto`, body = the single message bytes, header
  `connect-protocol-version: 1`. A non-200 response is parsed as JSON
  `{code, message, details}` into an `RpcException`.
- **Server-streaming:** `content-type: application/connect+proto`; each message
  is enveloped (1 flag byte + 4-byte big-endian length, reusing `grpc_frame`).
  The final end-of-stream envelope sets flag bit 1 and carries the
  `EndStreamResponse` JSON (`{error?, metadata?}`).
- **`clientStream` / `bidiStream`: best-effort over HTTP/1.1.** A fully
  interleaved bidirectional stream needs HTTP/2 flow control that `dart:io`'s
  `HttpClient` does not expose. These buffer the outbound request stream into a
  single request body, then read the response envelopes. This is correct for
  client-streaming (one response) and for bidi exchanges that do not require the
  client to react to server messages mid-stream, but not for truly concurrent
  bidi. For full bidi, use `GrpcTransport` with an HTTP/2 sender.

### `GrpcTransport` (gRPC-over-HTTP/2)

gRPC mandates HTTP/2 and `dart:io`'s `HttpClient` does not speak it. To keep the
framing + status mapping fully implemented and testable without pulling a heavy
HTTP/2 dependency, the socket layer is a **pluggable injection point**:

```dart
abstract class GrpcByteSender {
  Future<GrpcResponse> send(
    String path, Map<String, String> headers, List<int> framedRequest);
}
```

`GrpcTransport` owns path construction, gRPC framing/unframing, and
`grpc-status`/`grpc-message` trailer → `RpcException` mapping. A production
binding plugs an HTTP/2 client (e.g. over `package:http2`) in as a
`GrpcByteSender`; tests plug in an in-memory sender.

### `FakeTransport` (in-memory, for tests)

Routes each method `path` to a registered handler (`registerUnary`,
`registerServerStream`, `registerClientStream`, `registerBidiStream`). No
sockets. Handlers throw `RpcException` to exercise error propagation; an
unregistered path yields `RpcCode.unimplemented`.

## Codec helpers

`connect_codec.dart` and `grpc_codec.dart` expose the pure (socket-free) wire
helpers the transports use — `connectEncodeMessage` / `connectEncodeEndStream` /
`connectDecodeEnvelope(s)` / `errorFromJson`, and `grpcStatusFromTrailers` /
`grpcEncodeMessage` / `grpcDecodeMessage` / `rpcMethodPath` — so the protocol is
unit-testable independent of any transport.
