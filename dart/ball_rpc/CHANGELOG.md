## [0.3.1](https://github.com/Ball-Lang/ball/compare/ball_rpc-v0.3.0...ball_rpc-v0.3.1) (2026-09-05)

## 0.3.0+1

 - **DOCS**(agents): add hierarchical AGENTS.md across all packages ([#131](https://github.com/ball-lang/ball/issues/131)). ([ae2e547d](https://github.com/ball-lang/ball/commit/ae2e547da5ce0316bcb459eb444aa02550102df2))

## 0.3.0

* Initial release. Dart-target RPC transport runtime that generated service
  clients delegate to: `ConnectTransport`, `GrpcTransport` (over a pluggable
  `GrpcByteSender`), `FakeTransport`, and the shared `RpcCode` / `RpcException`
  status model.
