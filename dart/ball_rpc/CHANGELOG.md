## 0.3.0

* Initial release. Dart-target RPC transport runtime that generated service
  clients delegate to: `ConnectTransport`, `GrpcTransport` (over a pluggable
  `GrpcByteSender`), `FakeTransport`, and the shared `RpcCode` / `RpcException`
  status model.
