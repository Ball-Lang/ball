## 0.4.0

> Note: This release has breaking changes.

 - **REFACTOR**(protobuf): extract the editions protobuf engine into the ball_protobuf package. ([90694786](https://github.com/ball-lang/ball/commit/9069478639c33b33484f33877dea8e8a8cf22dc9))
 - **FIX**(ci,protobuf): format, bound conformance build memory, publish hygiene. ([2d1a89ca](https://github.com/ball-lang/ball/commit/2d1a89ca42c33b78aad21d23221c669dadea78da))
 - **FIX**(protobuf): pass upstream Editions conformance — codec/bridge fixes + CI. ([e55bfa3d](https://github.com/ball-lang/ball/commit/e55bfa3d16b1cfb2f9e5497b1ac509c22a55c0d1))
 - **FEAT**(protobuf-gen): cross-file refs, per-call Any resolver, extensions (Phase 3). ([9a842e18](https://github.com/ball-lang/ball/commit/9a842e18f7e2c0d507a5212aa777f9d7fe8a22ec))
 - **FEAT**(protobuf-gen): foundation — ball_protobuf_gen pkg, plugin, Dart message codegen. ([fdd9ee50](https://github.com/ball-lang/ball/commit/fdd9ee50bfe19acd98f89a150ed3a4dc4ea973a1))
 - **FEAT**(protobuf): full upstream conformance — implement all remaining features. ([4015fb05](https://github.com/ball-lang/ball/commit/4015fb0517b011b3b27537052d236ae6319b63e0))
 - **FEAT**(protobuf): broaden upstream conformance to proto2/proto3 + fix codec bugs. ([b96a9dc7](https://github.com/ball-lang/ball/commit/b96a9dc78625e40bca4de37a8ba2a71f8efe1fe0))
 - **FEAT**(protobuf): descriptor bridge + registry-driven conformance program (upstream Editions). ([acac65eb](https://github.com/ball-lang/ball/commit/acac65eb6ee7ce19298b3e9f351fa08774683eb4))
 - **DOCS**: document the upstream protobuf conformance harness. ([f52c6c3c](https://github.com/ball-lang/ball/commit/f52c6c3cf9e3c753fd2d26658dc884fd4d31b87a))
 - **BREAKING** **REFACTOR**: eliminate all language-specific modules + fix all conformance failures. ([23fce2d9](https://github.com/ball-lang/ball/commit/23fce2d9e9909c21cfc0fcb417c3bdea8cfc7b1b))

## 0.3.0

* Initial release. The Editions-capable, pure-Dart Protocol Buffers runtime,
  extracted into its own package from `ball_base` (which now re-exports it).
* Binary and proto3-JSON marshal/unmarshal, wire codecs, well-known types,
  gRPC framing.
* Full protobuf **Editions** support: the FeatureSet model + protoc's canonical
  feature-resolution algorithm, proto2/proto3 legacy inference, and
  feature-aware codecs honoring field presence, open/closed enums,
  packed/expanded repeated, delimited (group) message encoding, utf8 validation,
  and json_format.
