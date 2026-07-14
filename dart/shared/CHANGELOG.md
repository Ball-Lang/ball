## 0.3.1

 - **FIX**(audit): [#420](https://github.com/ball-lang/ball/issues/420) base-fn shadow surfacing + engine ambiguity guard ([#434](https://github.com/ball-lang/ball/issues/434)). ([4e56897f](https://github.com/ball-lang/ball/commit/4e56897f7bf3af84edfc4e0a93da0aabffa9ef80))
 - **FIX**(ball_protobuf): portable wire-buffer append (.add per item, not addAll) ([#18](https://github.com/ball-lang/ball/issues/18), [#25](https://github.com/ball-lang/ball/issues/25)) ([#331](https://github.com/ball-lang/ball/issues/331)). ([8fa610ce](https://github.com/ball-lang/ball/commit/8fa610ced2fafb7111716759b000bd76873cca7b))
 - **FEAT**(cli): self-host cli_core.auditReport (advances [#362](https://github.com/ball-lang/ball/issues/362)) ([#398](https://github.com/ball-lang/ball/issues/398)). ([6b824906](https://github.com/ball-lang/ball/commit/6b824906168008242cfbceb2c595a37b8204eb82))
 - **FEAT**(cli): self-hosted cli-core (cli.ball.json) + single-sourced version ([#371](https://github.com/ball-lang/ball/issues/371)). ([514f60d4](https://github.com/ball-lang/ball/commit/514f60d4ff49c3725145d4d37d20435eabafb3fc))
 - **FEAT**(cpp): [#18](https://github.com/ball-lang/ball/issues/18) stage 3 — binary-path cutover behind BALL_USE_BALL_PROTOBUF + byte-equivalence proof ([#341](https://github.com/ball-lang/ball/issues/341)). ([143219f5](https://github.com/ball-lang/ball/commit/143219f5cef1e6ed92d0bd7da1bd62644a978710))

## 0.3.0+3

 - **FIX**(shared): regenerate stale ball_protobuf.json/.bin artifact. ([c2749b63](https://github.com/ball-lang/ball/commit/c2749b63294dbe44bcf3a11af1f8d9c8e39d5a36))

## 0.3.0+2

 - **FIX**(engine-chain): negative-zero toStringAsFixed ([#101](https://github.com/ball-lang/ball/issues/101)), portable set value ([#68](https://github.com/ball-lang/ball/issues/68)), num double methods ([#100](https://github.com/ball-lang/ball/issues/100)) ([#170](https://github.com/ball-lang/ball/issues/170)). ([e15b769b](https://github.com/ball-lang/ball/commit/e15b769b09e924e2ae3e5cddcc22df3d44afc6e8))

## 0.3.0+1

 - **FIX**(ci,website): repair [#137](https://github.com/ball-lang/ball/issues/137) regressions + restore the broken website deploy ([#144](https://github.com/ball-lang/ball/issues/144)). ([6dbec37d](https://github.com/ball-lang/ball/commit/6dbec37d0f3bdb4c8be216d5b7baeccbf8d4c95e))
 - **FIX**(engine,encoder,compilers): String.runes → code points (closes [#108](https://github.com/ball-lang/ball/issues/108)) ([#111](https://github.com/ball-lang/ball/issues/111)). ([09bd5880](https://github.com/ball-lang/ball/commit/09bd588090e4f5b626c1cd792b702fe1d1020299))
 - **DOCS**: apply documentation + code-comment audit fixes ([#137](https://github.com/ball-lang/ball/issues/137)). ([58f3bf57](https://github.com/ball-lang/ball/commit/58f3bf578461ab14a29f77098a02e6f4b5a4e5da))
 - **DOCS**(agents): add hierarchical AGENTS.md across all packages ([#131](https://github.com/ball-lang/ball/issues/131)). ([ae2e547d](https://github.com/ball-lang/ball/commit/ae2e547da5ce0316bcb459eb444aa02550102df2))

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
