## 0.3.0

* Initial release. Consumer codegen for the `ball_protobuf` runtime: the
  `protoc-gen-ball` (message/enum/extension models), `protoc-gen-ball-connect`,
  and `protoc-gen-ball-grpc` plugins. Generated models are thin typed views over
  a `Map<String, Object?>` backing store plus an embedded resolved-Editions
  descriptor; all wire/JSON work delegates to the `ball_protobuf` runtime.
