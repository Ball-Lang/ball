## 0.3.1

 - **FIX**(audit): [#420](https://github.com/ball-lang/ball/issues/420) base-fn shadow surfacing + engine ambiguity guard ([#434](https://github.com/ball-lang/ball/issues/434)). ([4e56897f](https://github.com/ball-lang/ball/commit/4e56897f7bf3af84edfc4e0a93da0aabffa9ef80))
 - **FIX**(ci): unblock the release pipeline (dart analyze warning) + make PR analyze strict ([#418](https://github.com/ball-lang/ball/issues/418)). ([f8a9e7d1](https://github.com/ball-lang/ball/commit/f8a9e7d1fe5207ca8ca1e7ac3389f8e199da08fe))
 - **FIX**(engine): remove redundant BallDouble double-wrap ([#237](https://github.com/ball-lang/ball/issues/237)) + unique lambda paramCache key ([#246](https://github.com/ball-lang/ball/issues/246)) ([#274](https://github.com/ball-lang/ball/issues/274)). ([430f37c1](https://github.com/ball-lang/ball/commit/430f37c11c91f4501fe163a9080faf8c1860d282))
 - **FIX**(engine): Phase-2c coverage residual triage (issue [#261](https://github.com/ball-lang/ball/issues/261)) ([#271](https://github.com/ball-lang/ball/issues/271)). ([265c3c5e](https://github.com/ball-lang/ball/commit/265c3c5e27c098abe360cf4de6a24b07107d03ab))
 - **FEAT**(cli): self-host cli_core.auditReport (advances [#362](https://github.com/ball-lang/ball/issues/362)) ([#398](https://github.com/ball-lang/ball/issues/398)). ([6b824906](https://github.com/ball-lang/ball/commit/6b824906168008242cfbceb2c595a37b8204eb82))
 - **FEAT**(engine): continue-to-labelled-switch-case (goto-via-switch) ([#321](https://github.com/ball-lang/ball/issues/321)) ([#337](https://github.com/ball-lang/ball/issues/337)). ([2bc21116](https://github.com/ball-lang/ball/commit/2bc211168b45c38472d4f5580f351453daa4bdd7))

## 0.3.0+6

 - **FIX**(engine): typeDef-less constructor must preserve explicit non-this fields ([#198](https://github.com/ball-lang/ball/issues/198)) ([#216](https://github.com/ball-lang/ball/issues/216)). ([4cf4747e](https://github.com/ball-lang/ball/commit/4cf4747e5792771362071e4880a4fff8f124efc1))
 - **FIX**(engine): map_keys/map_values must fail loud on non-Map input ([#197](https://github.com/ball-lang/ball/issues/197)) ([#203](https://github.com/ball-lang/ball/issues/203)). ([9e1ac96e](https://github.com/ball-lang/ball/commit/9e1ac96ed7cbf0262d965b21fbea5c0a1b1a7b6a))
 - **FIX**: MapPattern must exclude portable Set value across compiler + engines ([#178](https://github.com/ball-lang/ball/issues/178)) ([#200](https://github.com/ball-lang/ball/issues/200)). ([369f9dab](https://github.com/ball-lang/ball/commit/369f9dabbae93491a0d3240d238da4a28f613dbc))

## 0.3.0+5

 - **FIX**(encoder): route bare .reversed getter to std_collections.list_reverse. ([49941dbe](https://github.com/ball-lang/ball/commit/49941dbe8c731f6f7c3f4dded6c5c2e28f604cd2))
 - **FIX**(cpp,encoder,engine): collision-free Set representation + self-host Set/goto ([#174](https://github.com/ball-lang/ball/issues/174), [#184](https://github.com/ball-lang/ball/issues/184)). ([b72d9d58](https://github.com/ball-lang/ball/commit/b72d9d5845c48b6b4b2b34e97aa7a50e77392d89))

## 0.3.0+4

 - **FIX**(engine,cpp): inherited field initializers, fields named List/Map/Set, byte-exact toStringAsExponential/Precision ([#166](https://github.com/ball-lang/ball/issues/166), [#167](https://github.com/ball-lang/ball/issues/167), [#100](https://github.com/ball-lang/ball/issues/100)) ([#181](https://github.com/ball-lang/ball/issues/181)). ([f0af3967](https://github.com/ball-lang/ball/commit/f0af3967009c34c36afc4064693a5fdb60b5835e))

## 0.3.0+3

 - **FIX**(engine-chain): negative-zero toStringAsFixed ([#101](https://github.com/ball-lang/ball/issues/101)), portable set value ([#68](https://github.com/ball-lang/ball/issues/68)), num double methods ([#100](https://github.com/ball-lang/ball/issues/100)) ([#170](https://github.com/ball-lang/ball/issues/170)). ([e15b769b](https://github.com/ball-lang/ball/commit/e15b769b09e924e2ae3e5cddcc22df3d44afc6e8))

## 0.3.0+2

 - **FIX**(engine): backward goto, BallDouble unwrapping, and symbol printing ([#159](https://github.com/ball-lang/ball/issues/159)). ([3ab0bb58](https://github.com/ball-lang/ball/commit/3ab0bb58e1d7eec99a63251090999efa650c8a39))
 - **FIX**: type literals ([#66](https://github.com/ball-lang/ball/issues/66)) + setter parameter binding ([#95](https://github.com/ball-lang/ball/issues/95)) ([#158](https://github.com/ball-lang/ball/issues/158)). ([cd1087b9](https://github.com/ball-lang/ball/commit/cd1087b9e7bbacac703f1344393b49963698af72))

## 0.3.0+1

 - **FIX**(engine,encoder,compilers): String.runes → code points (closes [#108](https://github.com/ball-lang/ball/issues/108)) ([#111](https://github.com/ball-lang/ball/issues/111)). ([09bd5880](https://github.com/ball-lang/ball/commit/09bd588090e4f5b626c1cd792b702fe1d1020299))
 - **FIX**(engine,encoder): List.reduce no-seed semantics + callback routing ([#108](https://github.com/ball-lang/ball/issues/108)) ([#109](https://github.com/ball-lang/ball/issues/109)). ([1da22352](https://github.com/ball-lang/ball/commit/1da2235219871aa7d1f6c2db2dd6ffe3c886deb1))
 - **FIX**(engine,encoder,compiler): primitive number getters (closes [#106](https://github.com/ball-lang/ball/issues/106)) ([#107](https://github.com/ball-lang/ball/issues/107)). ([998c2b04](https://github.com/ball-lang/ball/commit/998c2b048e541681f6d7fc470f7e70527ed603c7))
 - **FIX**(engine): implement std to_string_as_fixed handler + fixture ([#64](https://github.com/ball-lang/ball/issues/64)) ([#102](https://github.com/ball-lang/ball/issues/102)). ([50cd6bda](https://github.com/ball-lang/ball/commit/50cd6bda4d5126961f3e751d54cdf3263ff745e1))
 - **FIX**(engine): handle /= (double divide-assign); add full compound-op fixture ([#64](https://github.com/ball-lang/ball/issues/64)) ([#99](https://github.com/ball-lang/ball/issues/99)). ([4f84bed5](https://github.com/ball-lang/ball/commit/4f84bed570edbdc95dc9ee9ea1c2a6d19aaa4897))
 - **DOCS**: apply documentation + code-comment audit fixes ([#137](https://github.com/ball-lang/ball/issues/137)). ([58f3bf57](https://github.com/ball-lang/ball/commit/58f3bf578461ab14a29f77098a02e6f4b5a4e5da))
 - **DOCS**(agents): add hierarchical AGENTS.md across all packages ([#131](https://github.com/ball-lang/ball/issues/131)). ([ae2e547d](https://github.com/ball-lang/ball/commit/ae2e547da5ce0316bcb459eb444aa02550102df2))

## 0.1.0

* Initial release.
