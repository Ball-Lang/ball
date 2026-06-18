## 0.4.0

> Note: This release has breaking changes.

 - **REVERT**: remove Pattern messages + Reference.is_cascade_target. ([1a9e8d27](https://github.com/ball-lang/ball/commit/1a9e8d2710fec0cf250ac59014077e3b321772a2))
 - **REFACTOR**(proto): add Reference.is_cascade_target + migrate dunder fields. ([a8c2b50b](https://github.com/ball-lang/ball/commit/a8c2b50b2f4f4e798ea080b68701929db640afc3))
 - **REFACTOR**: migrate __type_args__ to structured TypeRef (WIP). ([1f13b5d4](https://github.com/ball-lang/ball/commit/1f13b5d47234180fa88933e211b48a057f5095b8))
 - **REFACTOR**(protobuf): extract the editions protobuf engine into the ball_protobuf package. ([90694786](https://github.com/ball-lang/ball/commit/9069478639c33b33484f33877dea8e8a8cf22dc9))
 - **FIX**: address all code review issues in ball_protobuf. ([9fe06fb2](https://github.com/ball-lang/ball/commit/9fe06fb264d00356e0c5c32bfe4842da639c8062))
 - **FIX**(shared): regenerate stale ball_protobuf.{json,bin} + add Ball freshness gate. ([9d60e97b](https://github.com/ball-lang/ball/commit/9d60e97b7cf6a41a26e8672a9be26d90156fab8f))
 - **FIX**(ci): resolve all dart analyze warnings, add github_token to buf-setup. ([6974f9fb](https://github.com/ball-lang/ball/commit/6974f9fb2dd723e71dbc737cf6e8d4a553e90f47))
 - **FIX**(cli): audit Modules natively (no synthetic Program) + dart format. ([2ba5a84d](https://github.com/ball-lang/ball/commit/2ba5a84dc735044ce41123d0308fb9df7c48020e))
 - **FIX**(shared): regenerate stale ball_protobuf.{json,bin} for std_convert routing. ([286acddb](https://github.com/ball-lang/ball/commit/286acddbae5df81bac35b3d63c10af2ec0555d22))
 - **FEAT**(protobuf): Editions Phase 6b — private-call fix + portability proof. ([b321c310](https://github.com/ball-lang/ball/commit/b321c3102062b509a4c078c0d5ff44e42ba20c45))
 - **FEAT**(proto): add Pattern message with 12 universal pattern kinds. ([5c88627a](https://github.com/ball-lang/ball/commit/5c88627a10418c658b0565d5793666a3f2ef1aca))
 - **FEAT**(proto): add TypeRef message and FunctionCall.type_args. ([90c44f38](https://github.com/ball-lang/ball/commit/90c44f3852bc73adcfea42593a501dbdd39a8f37))
 - **FEAT**(protobuf): Editions Phase 6a — repackage ball_protobuf as facade Module. ([7aa46c61](https://github.com/ball-lang/ball/commit/7aa46c619bab594ea4c34ef53b2a56b24c2b0c44))
 - **FEAT**(protobuf): Editions Phase 5 conformance harness + Phase 3 review fixes. ([b3ea6d6d](https://github.com/ball-lang/ball/commit/b3ea6d6d089529d7c2f635537db0510c75b64f19))
 - **FEAT**(protobuf): Editions Phase 4 — thread features through JSON codec + UTF-8. ([68c7231d](https://github.com/ball-lang/ball/commit/68c7231d16e511784c02efb322803c41d3025c0e))
 - **FEAT**(protobuf): complete Editions Phases 0/2/3 — resolution, legacy, binary. ([92124f62](https://github.com/ball-lang/ball/commit/92124f62c3d8077d2f87eb226975e93b86239bea))
 - **FEAT**(protobuf): thread resolved features through binary marshal (Phase 3). ([2a36e632](https://github.com/ball-lang/ball/commit/2a36e632253322dcef626aeff55a7b405f5a0da5))
 - **FEAT**(protobuf): editions feature-resolution core (Phase 0-2) — protoc-grounded. ([53277801](https://github.com/ball-lang/ball/commit/53277801b77a4ba601a4ba979591658268b5b93f))
 - **FEAT**: proto schema evolution + static capability analyzer (ball audit). ([63f62064](https://github.com/ball-lang/ball/commit/63f62064a0ebddd195ea8ba5879b287eb4bbdcdc))
 - **FEAT**: compile ball_protobuf to C++ — Ball eating its own dogfood. ([98e56646](https://github.com/ball-lang/ball/commit/98e56646bf29e21e4b94522e4dac45102ab89e82))
 - **FEAT**: ball_protobuf library complete — 89 functions, 113 tests, generated module. ([4ff8e849](https://github.com/ball-lang/ball/commit/4ff8e8499b2ed22dd0b13ddda939e12c04a1fcf3))
 - **FEAT**: buf CLI CMake integration, protobuf v34.1, CI/CD pipeline, test fixes. ([a25f649d](https://github.com/ball-lang/ball/commit/a25f649d2733114588a339295b1f7707d5f45f40))
 - **FEAT**: Phases D+E+F — Proto3 JSON, well-known types, edition support. ([e6335b15](https://github.com/ball-lang/ball/commit/e6335b156202e09b66089cb5af8bbc84c90fc19b))
 - **FEAT**: Phase C — ball_protobuf message marshal/unmarshal (12 functions). ([52ad674b](https://github.com/ball-lang/ball/commit/52ad674b09df23f24c04cb40469428b1dd74e84f))
 - **FEAT**: Phase B — ball_protobuf field encoding (26 functions). ([13d72b52](https://github.com/ball-lang/ball/commit/13d72b52eff3bef8efa8257dbee99fab6a4909f5))
 - **FEAT**: Phase A — ball_protobuf wire primitives (15 functions). ([db5f9183](https://github.com/ball-lang/ball/commit/db5f918308857986e684e9c2359bd2b4cca5b0e4))
 - **FEAT**: add ball_proto module — protobuf compatibility layer for Ball. ([75cda058](https://github.com/ball-lang/ball/commit/75cda0585d4a9458613d3e76ca303c8345802760))
 - **FEAT**: static termination analysis — infinite loops, recursion, dead code. ([4b94e119](https://github.com/ball-lang/ball/commit/4b94e11917efed2517d1214ac907a5a02d222086))
 - **FEAT**: new README, pub.dev prep, playground on ball-lang.dev. ([c86ddac7](https://github.com/ball-lang/ball/commit/c86ddac7ed6342f10885b8be16de9c4b582d07f8))
 - **FEAT**: Phases G+H — gRPC framing + conformance suite plugin. ([a0bf6b04](https://github.com/ball-lang/ball/commit/a0bf6b04fe7e14b65de39a53dcbf3b6c8ffe2fce))
 - **DOCS**: async architecture design + add async capability category. ([6c1ee6d0](https://github.com/ball-lang/ball/commit/6c1ee6d032cbc18bd7fea44872a10925d74444ef))
 - **DOCS**(dart): READMEs + CHANGELOGs for 6 pub packages + real-world wordcount demo. ([9ee28565](https://github.com/ball-lang/ball/commit/9ee28565716fa9d3cd6360dfefc3a608862ccb5b))
 - **BREAKING** **REFACTOR**: eliminate all language-specific modules + fix all conformance failures. ([23fce2d9](https://github.com/ball-lang/ball/commit/23fce2d9e9909c21cfc0fcb417c3bdea8cfc7b1b))
 - **BREAKING** **FEAT**: typeDefs unification, self-describing Any file envelope, 0.3.0. ([e0ba20ef](https://github.com/ball-lang/ball/commit/e0ba20ef905cdc8ba7a57595ef7a4aa42b42565b))

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
