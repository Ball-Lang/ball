## 0.3.0

* **Extracted the portable protobuf runtime** into the standalone
  [`ball_protobuf`](https://pub.dev/packages/ball_protobuf) package; `ball_base`
  now depends on it and re-exports it for backward compatibility.
* **Protobuf Editions support** (via `ball_protobuf`): the FeatureSet model and
  protoc's canonical feature-resolution algorithm, plus proto2/proto3 legacy
  inference.
* **Module-native capability & termination analyzers** — analyze a list of
  `Module`s (and binary Ball files) directly, without wrapping them in a
  synthetic `Program`.
* **`BallFile` model** (`BallProgramFile` / `BallModuleFile`) with
  `google.protobuf.Any` envelope decode/encode.
* Type declarations are emitted from `typeDefs[]` only; the legacy
  `Module.types` and `_meta_*` paths were removed.

## 0.1.0

* Initial release.
