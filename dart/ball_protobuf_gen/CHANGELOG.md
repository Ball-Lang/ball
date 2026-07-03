## 0.3.0+4

 - Update a dependency to the latest release.

## 0.3.0+3

 - Update a dependency to the latest release.

## 0.3.0+2

 - **FIX**(gen,compiler,cpp): presence rule, real memory_realloc, extension guard, orphan runtime removal ([#151](https://github.com/ball-lang/ball/issues/151)). ([97c85be5](https://github.com/ball-lang/ball/commit/97c85be50dc57219abe0b79c220f0ecefee9d739))

## 0.3.0+1

 - **DOCS**: apply documentation + code-comment audit fixes ([#137](https://github.com/ball-lang/ball/issues/137)). ([58f3bf57](https://github.com/ball-lang/ball/commit/58f3bf578461ab14a29f77098a02e6f4b5a4e5da))
 - **DOCS**(agents): add hierarchical AGENTS.md across all packages ([#131](https://github.com/ball-lang/ball/issues/131)). ([ae2e547d](https://github.com/ball-lang/ball/commit/ae2e547da5ce0316bcb459eb444aa02550102df2))

## 0.3.0

* Initial release. Consumer codegen for the `ball_protobuf` runtime: the
  `protoc-gen-ball` (message/enum/extension models), `protoc-gen-ball-connect`,
  and `protoc-gen-ball-grpc` plugins. Generated models are thin typed views over
  a `Map<String, Object?>` backing store plus an embedded resolved-Editions
  descriptor; all wire/JSON work delegates to the `ball_protobuf` runtime.
