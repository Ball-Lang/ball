## 0.3.1

 - **FIX**(dart): make all workspace packages pub.dev-publishable (unblocks release-prepare) ([#54](https://github.com/ball-lang/ball/issues/54)). ([c6fb98a5](https://github.com/ball-lang/ball/commit/c6fb98a520460c1ab1c1fa1f635f3ada8f548512))
 - **FEAT**(protobuf-gen): Phase 4 — gRPC + Connect services (ball_rpc + 2 plugins). ([a6bff279](https://github.com/ball-lang/ball/commit/a6bff27909cf9081ece3dc8b8050366a463736ae))

## 0.3.0

* Initial release. Dart-target RPC transport runtime that generated service
  clients delegate to: `ConnectTransport`, `GrpcTransport` (over a pluggable
  `GrpcByteSender`), `FakeTransport`, and the shared `RpcCode` / `RpcException`
  status model.
