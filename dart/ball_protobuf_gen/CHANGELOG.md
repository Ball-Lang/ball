## 0.3.1

 - **FIX**(dart): make all workspace packages pub.dev-publishable (unblocks release-prepare) ([#54](https://github.com/ball-lang/ball/issues/54)). ([c6fb98a5](https://github.com/ball-lang/ball/commit/c6fb98a520460c1ab1c1fa1f635f3ada8f548512))
 - **FEAT**(protobuf-gen): Phase 4 — gRPC + Connect services (ball_rpc + 2 plugins). ([a6bff279](https://github.com/ball-lang/ball/commit/a6bff27909cf9081ece3dc8b8050366a463736ae))
 - **FEAT**(protobuf-gen): cross-file refs, per-call Any resolver, extensions (Phase 3). ([9a842e18](https://github.com/ball-lang/ball/commit/9a842e18f7e2c0d507a5212aa777f9d7fe8a22ec))
 - **FEAT**(protobuf-gen): foundation — ball_protobuf_gen pkg, plugin, Dart message codegen. ([fdd9ee50](https://github.com/ball-lang/ball/commit/fdd9ee50bfe19acd98f89a150ed3a4dc4ea973a1))

## 0.3.0

* Initial release. Consumer codegen for the `ball_protobuf` runtime: the
  `protoc-gen-ball` (message/enum/extension models), `protoc-gen-ball-connect`,
  and `protoc-gen-ball-grpc` plugins. Generated models are thin typed views over
  a `Map<String, Object?>` backing store plus an embedded resolved-Editions
  descriptor; all wire/JSON work delegates to the `ball_protobuf` runtime.
