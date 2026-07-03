## 0.3.2

 - **FIX**(encoder): route bare .reversed getter to std_collections.list_reverse. ([49941dbe](https://github.com/ball-lang/ball/commit/49941dbe8c731f6f7c3f4dded6c5c2e28f604cd2))
 - **FIX**(cpp,encoder,engine): collision-free Set representation + self-host Set/goto ([#174](https://github.com/ball-lang/ball/issues/174), [#184](https://github.com/ball-lang/ball/issues/184)). ([b72d9d58](https://github.com/ball-lang/ball/commit/b72d9d5845c48b6b4b2b34e97aa7a50e77392d89))
 - **FEAT**(conformance): hand-authored fixtures for int_to_string/double_to_string/label. ([94d53c65](https://github.com/ball-lang/ball/commit/94d53c657de1810fe9ccd87a40b59114a7ac65cc))

## 0.3.1

 - **FIX**(engine-chain): negative-zero toStringAsFixed ([#101](https://github.com/ball-lang/ball/issues/101)), portable set value ([#68](https://github.com/ball-lang/ball/issues/68)), num double methods ([#100](https://github.com/ball-lang/ball/issues/100)) ([#170](https://github.com/ball-lang/ball/issues/170)). ([e15b769b](https://github.com/ball-lang/ball/commit/e15b769b09e924e2ae3e5cddcc22df3d44afc6e8))
 - **FEAT**(encoder): generate std base-function coverage inventory from std.json ([#165](https://github.com/ball-lang/ball/issues/165)). ([7e3f6d6e](https://github.com/ball-lang/ball/commit/7e3f6d6ea8ba7064ad854614022c0d7a0770a13f))

## 0.3.0+2

 - **FIX**: type literals ([#66](https://github.com/ball-lang/ball/issues/66)) + setter parameter binding ([#95](https://github.com/ball-lang/ball/issues/95)) ([#158](https://github.com/ball-lang/ball/issues/158)). ([cd1087b9](https://github.com/ball-lang/ball/commit/cd1087b9e7bbacac703f1344393b49963698af72))

## 0.3.0+1

 - **FIX**(engine,encoder,compilers): String.runes → code points (closes [#108](https://github.com/ball-lang/ball/issues/108)) ([#111](https://github.com/ball-lang/ball/issues/111)). ([09bd5880](https://github.com/ball-lang/ball/commit/09bd588090e4f5b626c1cd792b702fe1d1020299))
 - **FIX**(engine,encoder): List.reduce no-seed semantics + callback routing ([#108](https://github.com/ball-lang/ball/issues/108)) ([#109](https://github.com/ball-lang/ball/issues/109)). ([1da22352](https://github.com/ball-lang/ball/commit/1da2235219871aa7d1f6c2db2dd6ffe3c886deb1))
 - **FIX**(engine,encoder,compiler): primitive number getters (closes [#106](https://github.com/ball-lang/ball/issues/106)) ([#107](https://github.com/ball-lang/ball/issues/107)). ([998c2b04](https://github.com/ball-lang/ball/commit/998c2b048e541681f6d7fc470f7e70527ed603c7))
 - **FIX**(ball_protobuf): fix facade test inline decode + gate the suite in CI ([#75](https://github.com/ball-lang/ball/issues/75)) ([#103](https://github.com/ball-lang/ball/issues/103)). ([0d5e4cca](https://github.com/ball-lang/ball/commit/0d5e4ccae164bdc2c328dfc5d419885a1da4ac14))
 - **DOCS**: apply documentation + code-comment audit fixes ([#137](https://github.com/ball-lang/ball/issues/137)). ([58f3bf57](https://github.com/ball-lang/ball/commit/58f3bf578461ab14a29f77098a02e6f4b5a4e5da))
 - **DOCS**(agents): add hierarchical AGENTS.md across all packages ([#131](https://github.com/ball-lang/ball/issues/131)). ([ae2e547d](https://github.com/ball-lang/ball/commit/ae2e547da5ce0316bcb459eb444aa02550102df2))

## 0.1.0

* Initial release.
