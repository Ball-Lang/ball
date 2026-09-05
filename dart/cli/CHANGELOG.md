# [0.4.0](https://github.com/Ball-Lang/ball/compare/ball_cli-v0.3.0...ball_cli-v0.4.0) (2026-09-05)


### Bug Fixes

* **#402:** audit categorizes by resolved base-fn identity — close the call.module spoofing bypass ([#413](https://github.com/Ball-Lang/ball/issues/413)) ([7b637cb](https://github.com/Ball-Lang/ball/commit/7b637cbf7d848631957b9290ab33462bde0a721d))
* **audit:** [#420](https://github.com/Ball-Lang/ball/issues/420) base-fn shadow surfacing + engine ambiguity guard ([#434](https://github.com/Ball-Lang/ball/issues/434)) ([4e56897](https://github.com/Ball-Lang/ball/commit/4e56897f7bf3af84edfc4e0a93da0aabffa9ef80)), closes [#402](https://github.com/Ball-Lang/ball/issues/402) [#402](https://github.com/Ball-Lang/ball/issues/402)
* **cli:** move version.g.dart under lib/src so pub publish stops warning ([#454](https://github.com/Ball-Lang/ball/issues/454)) ([4b6e4e7](https://github.com/Ball-Lang/ball/commit/4b6e4e761446e264dfb93169c1caf6c08d5408d8))
* **coverage:** Dart coverage job crashed on binary test stdout (FormatException) ([#121](https://github.com/Ball-Lang/ball/issues/121)) ([ff56a3a](https://github.com/Ball-Lang/ball/commit/ff56a3ae9fcddffed25352b98e23c54cf57da2a0))
* **engine:** Phase-2c coverage residual triage (issue [#261](https://github.com/Ball-Lang/ball/issues/261)) ([#271](https://github.com/Ball-Lang/ball/issues/271)) ([265c3c5](https://github.com/Ball-Lang/ball/commit/265c3c5e27c098abe360cf4de6a24b07107d03ab)), closes [#61](https://github.com/Ball-Lang/ball/issues/61)
* **ts:** [#412](https://github.com/Ball-Lang/ball/issues/412) — ball audit --reachable-only emits the termination section ([#440](https://github.com/Ball-Lang/ball/issues/440)) ([664935c](https://github.com/Ball-Lang/ball/commit/664935c6518a929ed17d83e7c5e5d324188f4dec))


### Features

* **cli:** self-host cli_core.auditReport (advances [#362](https://github.com/Ball-Lang/ball/issues/362)) ([#398](https://github.com/Ball-Lang/ball/issues/398)) ([6b82490](https://github.com/Ball-Lang/ball/commit/6b824906168008242cfbceb2c595a37b8204eb82)), closes [#55](https://github.com/Ball-Lang/ball/issues/55) [#364](https://github.com/Ball-Lang/ball/issues/364)
* **cli:** self-hosted cli-core (cli.ball.json) + single-sourced version ([#371](https://github.com/Ball-Lang/ball/issues/371)) ([514f60d](https://github.com/Ball-Lang/ball/commit/514f60d4ff49c3725145d4d37d20435eabafb3fc)), closes [#362](https://github.com/Ball-Lang/ball/issues/362) [#362](https://github.com/Ball-Lang/ball/issues/362) [#363](https://github.com/Ball-Lang/ball/issues/363)
* **cpp:** [#367](https://github.com/Ball-Lang/ball/issues/367) unified `ball` CLI (engine_rt run + compile + encode + self-hosted cli-core verbs) ([#374](https://github.com/Ball-Lang/ball/issues/374)) ([73d7a63](https://github.com/Ball-Lang/ball/commit/73d7a63fc9645b91b73242b687ef498bbd26456c)), closes [#362](https://github.com/Ball-Lang/ball/issues/362) [#362](https://github.com/Ball-Lang/ball/issues/362)
* **rust:** [#365](https://github.com/Ball-Lang/ball/issues/365) — self-host cli_core.auditReport, wire `ball audit` ([#441](https://github.com/Ball-Lang/ball/issues/441)) ([8ac38c7](https://github.com/Ball-Lang/ball/commit/8ac38c73337f4a7cc9eb8fd38529965fe9e90b81)), closes [#398](https://github.com/Ball-Lang/ball/issues/398)

## 0.3.0+6

 - Update a dependency to the latest release.

## 0.3.0+5

 - Update a dependency to the latest release.

## 0.3.0+4

 - Update a dependency to the latest release.

## 0.3.0+3

 - Update a dependency to the latest release.

## 0.3.0+2

 - Update a dependency to the latest release.

## 0.3.0+1

 - **FIX**(coverage): Dart coverage job crashed on binary test stdout (FormatException) ([#121](https://github.com/ball-lang/ball/issues/121)). ([ff56a3ae](https://github.com/ball-lang/ball/commit/ff56a3ae9fcddffed25352b98e23c54cf57da2a0))
 - **DOCS**: apply documentation + code-comment audit fixes ([#137](https://github.com/ball-lang/ball/issues/137)). ([58f3bf57](https://github.com/ball-lang/ball/commit/58f3bf578461ab14a29f77098a02e6f4b5a4e5da))
 - **DOCS**(agents): add hierarchical AGENTS.md across all packages ([#131](https://github.com/ball-lang/ball/issues/131)). ([ae2e547d](https://github.com/ball-lang/ball/commit/ae2e547da5ce0316bcb459eb444aa02550102df2))

## 0.1.0

* Initial release.
