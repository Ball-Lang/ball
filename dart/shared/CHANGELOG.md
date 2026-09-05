## [0.4.1](https://github.com/Ball-Lang/ball/compare/ball_base-v0.4.0...ball_base-v0.4.1) (2026-09-05)


### Bug Fixes

* **std:** one bool contract for set_add/set_remove across all targets + declared-outputType gate ([#545](https://github.com/Ball-Lang/ball/issues/545)) ([#562](https://github.com/Ball-Lang/ball/issues/562)) ([d902ab1](https://github.com/Ball-Lang/ball/commit/d902ab19711c220244d18300a578386e213dc7e3)), closes [#488](https://github.com/Ball-Lang/ball/issues/488)

# [0.4.0](https://github.com/Ball-Lang/ball/compare/ball_base-v0.3.0...ball_base-v0.4.0) (2026-09-05)


### Bug Fixes

* **#402:** audit categorizes by resolved base-fn identity — close the call.module spoofing bypass ([#413](https://github.com/Ball-Lang/ball/issues/413)) ([7b637cb](https://github.com/Ball-Lang/ball/commit/7b637cbf7d848631957b9290ab33462bde0a721d))
* **audit:** [#420](https://github.com/Ball-Lang/ball/issues/420) base-fn shadow surfacing + engine ambiguity guard ([#434](https://github.com/Ball-Lang/ball/issues/434)) ([4e56897](https://github.com/Ball-Lang/ball/commit/4e56897f7bf3af84edfc4e0a93da0aabffa9ef80)), closes [#402](https://github.com/Ball-Lang/ball/issues/402) [#402](https://github.com/Ball-Lang/ball/issues/402)
* **ball_protobuf:** portable wire-buffer append (.add per item, not addAll) ([#18](https://github.com/Ball-Lang/ball/issues/18), [#25](https://github.com/Ball-Lang/ball/issues/25)) ([#331](https://github.com/Ball-Lang/ball/issues/331)) ([8fa610c](https://github.com/Ball-Lang/ball/commit/8fa610ced2fafb7111716759b000bd76873cca7b))
* **ci,website:** repair [#137](https://github.com/Ball-Lang/ball/issues/137) regressions + restore the broken website deploy ([#144](https://github.com/Ball-Lang/ball/issues/144)) ([6dbec37](https://github.com/Ball-Lang/ball/commit/6dbec37d0f3bdb4c8be216d5b7baeccbf8d4c95e))
* **dart:** declare the routed-but-undeclared std functions and dispatch collection methods by receiver type (closes [#505](https://github.com/Ball-Lang/ball/issues/505)) ([#547](https://github.com/Ball-Lang/ball/issues/547)) ([6e7b703](https://github.com/Ball-Lang/ball/commit/6e7b7039f1309d97ddc40087eb0fb71a2f71512c)), closes [#488](https://github.com/Ball-Lang/ball/issues/488) [#488](https://github.com/Ball-Lang/ball/issues/488) [#545](https://github.com/Ball-Lang/ball/issues/545)
* **engine-chain:** negative-zero toStringAsFixed ([#101](https://github.com/Ball-Lang/ball/issues/101)), portable set value ([#68](https://github.com/Ball-Lang/ball/issues/68)), num double methods ([#100](https://github.com/Ball-Lang/ball/issues/100)) ([#170](https://github.com/Ball-Lang/ball/issues/170)) ([e15b769](https://github.com/Ball-Lang/ball/commit/e15b769b09e924e2ae3e5cddcc22df3d44afc6e8)), closes [hi#precision](https://github.com/hi/issues/precision)
* **engine,encoder,compilers:** String.runes → code points (closes [#108](https://github.com/Ball-Lang/ball/issues/108)) ([#111](https://github.com/Ball-Lang/ball/issues/111)) ([09bd588](https://github.com/Ball-Lang/ball/commit/09bd588090e4f5b626c1cd792b702fe1d1020299)), closes [#106](https://github.com/Ball-Lang/ball/issues/106)
* **engine:** await constructor futures inside _callFunction's try; weekly toolchain-drift CI run ([#500](https://github.com/Ball-Lang/ball/issues/500)) ([7910c82](https://github.com/Ball-Lang/ball/commit/7910c82475d835d7fd6bac25315d8b76a0822897)), closes [#497](https://github.com/Ball-Lang/ball/issues/497) [C#-only](https://github.com/C/issues/-only)
* **shared:** regenerate stale ball_protobuf.json/.bin artifact ([c2749b6](https://github.com/Ball-Lang/ball/commit/c2749b63294dbe44bcf3a11af1f8d9c8e39d5a36))


### Features

* **cli:** self-host cli_core.auditReport (advances [#362](https://github.com/Ball-Lang/ball/issues/362)) ([#398](https://github.com/Ball-Lang/ball/issues/398)) ([6b82490](https://github.com/Ball-Lang/ball/commit/6b824906168008242cfbceb2c595a37b8204eb82)), closes [#55](https://github.com/Ball-Lang/ball/issues/55) [#364](https://github.com/Ball-Lang/ball/issues/364)
* **cli:** self-hosted cli-core (cli.ball.json) + single-sourced version ([#371](https://github.com/Ball-Lang/ball/issues/371)) ([514f60d](https://github.com/Ball-Lang/ball/commit/514f60d4ff49c3725145d4d37d20435eabafb3fc)), closes [#362](https://github.com/Ball-Lang/ball/issues/362) [#362](https://github.com/Ball-Lang/ball/issues/362) [#363](https://github.com/Ball-Lang/ball/issues/363)
* **cpp:** [#18](https://github.com/Ball-Lang/ball/issues/18) stage 3 — binary-path cutover behind BALL_USE_BALL_PROTOBUF + byte-equivalence proof ([#341](https://github.com/Ball-Lang/ball/issues/341)) ([143219f](https://github.com/Ball-Lang/ball/commit/143219f5cef1e6ed92d0bd7da1bd62644a978710)), closes [addAll-throu#alias](https://github.com/addAll-throu/issues/alias) [#25](https://github.com/Ball-Lang/ball/issues/25) [addAll-throu#alias](https://github.com/addAll-throu/issues/alias) [#25](https://github.com/Ball-Lang/ball/issues/25)
* **std:** add the universal std.type_of base function and stop a constructor from returning self ([#512](https://github.com/Ball-Lang/ball/issues/512)) ([0e06d7d](https://github.com/Ball-Lang/ball/commit/0e06d7dc9d33878132290b766cbbcae2ad676272)), closes [#502](https://github.com/Ball-Lang/ball/issues/502) [#489](https://github.com/Ball-Lang/ball/issues/489) [#489](https://github.com/Ball-Lang/ball/issues/489) [#499](https://github.com/Ball-Lang/ball/issues/499) [#499](https://github.com/Ball-Lang/ball/issues/499) [#489](https://github.com/Ball-Lang/ball/issues/489) [#489](https://github.com/Ball-Lang/ball/issues/489) [#513](https://github.com/Ball-Lang/ball/issues/513) [#514](https://github.com/Ball-Lang/ball/issues/514) [#499](https://github.com/Ball-Lang/ball/issues/499) [#513](https://github.com/Ball-Lang/ball/issues/513) [#514](https://github.com/Ball-Lang/ball/issues/514) [#499](https://github.com/Ball-Lang/ball/issues/499) [#499](https://github.com/Ball-Lang/ball/issues/499) [#499](https://github.com/Ball-Lang/ball/issues/499) [#527](https://github.com/Ball-Lang/ball/issues/527) [#528](https://github.com/Ball-Lang/ball/issues/528) [#528](https://github.com/Ball-Lang/ball/issues/528) [#527](https://github.com/Ball-Lang/ball/issues/527) [#532](https://github.com/Ball-Lang/ball/issues/532) [#532](https://github.com/Ball-Lang/ball/issues/532) [513/#514](https://github.com/Ball-Lang/ball/issues/514)

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
