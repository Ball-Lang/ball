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
