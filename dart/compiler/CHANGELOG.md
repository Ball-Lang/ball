## 0.3.0+5

 - **FIX**(cpp): finish [#18](https://github.com/ball-lang/ball/issues/18) protobuf-RT smoke canary verification; regenerate real functions. ([5b5917f2](https://github.com/ball-lang/ball/commit/5b5917f29ae1a19c4e36a626caa13dde953616ab))
 - **FIX**(compiler): keep implicit-ctor field initializers, drop synthesized param. ([9e26d421](https://github.com/ball-lang/ball/commit/9e26d421a2a890ad560194922cda95d70e734a8b))

## 0.3.0+4

 - **FIX**(engine,cpp): inherited field initializers, fields named List/Map/Set, byte-exact toStringAsExponential/Precision ([#166](https://github.com/ball-lang/ball/issues/166), [#167](https://github.com/ball-lang/ball/issues/167), [#100](https://github.com/ball-lang/ball/issues/100)) ([#181](https://github.com/ball-lang/ball/issues/181)). ([f0af3967](https://github.com/ball-lang/ball/commit/f0af3967009c34c36afc4064693a5fdb60b5835e))

## 0.3.0+3

 - **FIX**(engine-chain): negative-zero toStringAsFixed ([#101](https://github.com/ball-lang/ball/issues/101)), portable set value ([#68](https://github.com/ball-lang/ball/issues/68)), num double methods ([#100](https://github.com/ball-lang/ball/issues/100)) ([#170](https://github.com/ball-lang/ball/issues/170)). ([e15b769b](https://github.com/ball-lang/ball/commit/e15b769b09e924e2ae3e5cddcc22df3d44afc6e8))

## 0.3.0+2

 - **FIX**(engine): backward goto, BallDouble unwrapping, and symbol printing ([#159](https://github.com/ball-lang/ball/issues/159)). ([3ab0bb58](https://github.com/ball-lang/ball/commit/3ab0bb58e1d7eec99a63251090999efa650c8a39))
 - **FIX**: type literals ([#66](https://github.com/ball-lang/ball/issues/66)) + setter parameter binding ([#95](https://github.com/ball-lang/ball/issues/95)) ([#158](https://github.com/ball-lang/ball/issues/158)). ([cd1087b9](https://github.com/ball-lang/ball/commit/cd1087b9e7bbacac703f1344393b49963698af72))
 - **FIX**(gen,compiler,cpp): presence rule, real memory_realloc, extension guard, orphan runtime removal ([#151](https://github.com/ball-lang/ball/issues/151)). ([97c85be5](https://github.com/ball-lang/ball/commit/97c85be50dc57219abe0b79c220f0ecefee9d739))

## 0.3.0+1

 - **FIX**(engine,encoder,compilers): String.runes → code points (closes [#108](https://github.com/ball-lang/ball/issues/108)) ([#111](https://github.com/ball-lang/ball/issues/111)). ([09bd5880](https://github.com/ball-lang/ball/commit/09bd588090e4f5b626c1cd792b702fe1d1020299))
 - **FIX**(engine,encoder,compiler): primitive number getters (closes [#106](https://github.com/ball-lang/ball/issues/106)) ([#107](https://github.com/ball-lang/ball/issues/107)). ([998c2b04](https://github.com/ball-lang/ball/commit/998c2b048e541681f6d7fc470f7e70527ed603c7))
 - **DOCS**: apply documentation + code-comment audit fixes ([#137](https://github.com/ball-lang/ball/issues/137)). ([58f3bf57](https://github.com/ball-lang/ball/commit/58f3bf578461ab14a29f77098a02e6f4b5a4e5da))
 - **DOCS**(agents): add hierarchical AGENTS.md across all packages ([#131](https://github.com/ball-lang/ball/issues/131)). ([ae2e547d](https://github.com/ball-lang/ball/commit/ae2e547da5ce0316bcb459eb444aa02550102df2))

## 0.1.0

* Initial release.
