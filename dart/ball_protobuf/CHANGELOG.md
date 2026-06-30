## 0.3.0+1

 - **FIX**(ball_protobuf): fix facade test inline decode + gate the suite in CI ([#75](https://github.com/ball-lang/ball/issues/75)) ([#103](https://github.com/ball-lang/ball/issues/103)). ([0d5e4cca](https://github.com/ball-lang/ball/commit/0d5e4ccae164bdc2c328dfc5d419885a1da4ac14))
 - **DOCS**: apply documentation + code-comment audit fixes ([#137](https://github.com/ball-lang/ball/issues/137)). ([58f3bf57](https://github.com/ball-lang/ball/commit/58f3bf578461ab14a29f77098a02e6f4b5a4e5da))
 - **DOCS**(agents): add hierarchical AGENTS.md across all packages ([#131](https://github.com/ball-lang/ball/issues/131)). ([ae2e547d](https://github.com/ball-lang/ball/commit/ae2e547da5ce0316bcb459eb444aa02550102df2))

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
