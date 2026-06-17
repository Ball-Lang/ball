## [1.1.1](https://github.com/Ball-Lang/ball/compare/v1.1.0...v1.1.1) (2026-06-17)


### Bug Fixes

* **dart:** make all workspace packages pub.dev-publishable (unblocks release-prepare) ([#54](https://github.com/Ball-Lang/ball/issues/54)) ([c6fb98a](https://github.com/Ball-Lang/ball/commit/c6fb98a520460c1ab1c1fa1f635f3ada8f548512)), closes [#53](https://github.com/Ball-Lang/ball/issues/53)

# [1.1.0](https://github.com/Ball-Lang/ball/compare/v1.0.1...v1.1.0) (2026-06-17)


### Features

* **cpp:** protobuf-free Ball IR loader (ball_ir.h) — [#18](https://github.com/Ball-Lang/ball/issues/18) foundation ([#51](https://github.com/Ball-Lang/ball/issues/51)) ([1f078ba](https://github.com/Ball-Lang/ball/commit/1f078baac39ebd1a0440939a8d0e5845e94c3b69))

## [1.0.1](https://github.com/Ball-Lang/ball/compare/v1.0.0...v1.0.1) (2026-06-17)


### Bug Fixes

* **patterns:** when-guards, record arity, nullable-type patterns across all engines ([#48](https://github.com/Ball-Lang/ball/issues/48)) ([dd66987](https://github.com/Ball-Lang/ball/commit/dd669878c3e662c41fc14f6221ddeadef2c38a07)), closes [#47](https://github.com/Ball-Lang/ball/issues/47)

# [1.0.0](https://github.com/Ball-Lang/ball/compare/v0.2.1...v1.0.0) (2026-06-17)


* feat!: typeDefs unification, self-describing Any file envelope, 0.3.0 ([e0ba20e](https://github.com/Ball-Lang/ball/commit/e0ba20ef905cdc8ba7a57595ef7a4aa42b42565b))
* refactor!: eliminate all language-specific modules + fix all conformance failures ([23fce2d](https://github.com/Ball-Lang/ball/commit/23fce2d9e9909c21cfc0fcb417c3bdea8cfc7b1b))


### Bug Fixes

* 148 expected output = 19 (matches Dart source, Dart engine has bug) ([3171ec7](https://github.com/Ball-Lang/ball/commit/3171ec72d3d81207049da1625ab237f36b5db485))
* accept labeled continue semantics (Count: 14) ([111a453](https://github.com/Ball-Lang/ball/commit/111a4536faa4e106b76f2c4f680c9026936f8532))
* address all code review issues in ball_protobuf ([9fe06fb](https://github.com/Ball-Lang/ball/commit/9fe06fb264d00356e0c5c32bfe4842da639c8062))
* **all:** cast patterns assert/throw on type mismatch (Dart semantics) across every target ([57e4291](https://github.com/Ball-Lang/ball/commit/57e42919e5ac0051bf84fc0085a5447b5cc711b7))
* **ci,protobuf:** format, bound conformance build memory, publish hygiene ([2d1a89c](https://github.com/Ball-Lang/ball/commit/2d1a89ca42c33b78aad21d23221c669dadea78da))
* **ci:** ball-audit needs full history for the PR-base diff ([4b26e9c](https://github.com/Ball-Lang/ball/commit/4b26e9c2bffaeff5c5dbcad5f7c876eacc640dc3))
* **ci:** bump stale TS regression-gate floors (engine 270→291, compiler 270→315) ([83e1507](https://github.com/Ball-Lang/ball/commit/83e15077c6739df87ab164fe3eae380f3cb13942))
* **ci:** C++ build uses pinned protobuf v34.1, not incompatible apt one ([d1a7dd7](https://github.com/Ball-Lang/ball/commit/d1a7dd73e25516b17bff1e5867c22620757bb1f5))
* **ci:** correct TS compiler floor to 313 (new-encoder engine.ball.json) ([2f59d57](https://github.com/Ball-Lang/ball/commit/2f59d57e868dd1d44828a4d88cfd59809f5776d1)), closes [#46](https://github.com/Ball-Lang/ball/issues/46) [#47](https://github.com/Ball-Lang/ball/issues/47)
* **ci:** Dart gate aborted under `bash -e` when a count grep found no match ([eb441d2](https://github.com/Ball-Lang/ball/commit/eb441d295188e4724db32101a94dc9b650421881))
* **ci:** e2e C++20 and ci-build compiler lookup ([41c730a](https://github.com/Ball-Lang/ball/commit/41c730a00aaba25b6755fadc148deb94d5c4feb6))
* **ci:** exclude self-host generated file + parity test from analysis ([44a0b2c](https://github.com/Ball-Lang/ball/commit/44a0b2c01faa9d2a7cdd3068f1255fb93186d4f8))
* **ci:** find ball_cpp_compile in ci-build on Linux ([a531478](https://github.com/Ball-Lang/ball/commit/a5314787847314873b1eb5c04ab2c68361b56759))
* **ci:** keep dart/self_host/lib/ present for C++ self-host engine_rt write ([af63efb](https://github.com/Ball-Lang/ball/commit/af63efb7912505e36b1379ff54a6a26fcebd55c3))
* **ci:** Linux C++ build, TS engine types, regression gate floors ([2652ed5](https://github.com/Ball-Lang/ball/commit/2652ed58fdefbf6b9d4accd5a0a9006f18d0d13d))
* **ci:** make self-host tally crash-resilient + regenerate cpp snapshots ([223caa5](https://github.com/Ball-Lang/ball/commit/223caa525af207aa8b6f29478884ac2b6eb53346))
* **ci:** pass-floor regression gate and C++ build parity ([12b2bec](https://github.com/Ball-Lang/ball/commit/12b2bec731518a1e5e122b937fa43b925d38d17f))
* **ci:** skip self-host C++ when engine_rt absent ([33047af](https://github.com/Ball-Lang/ball/commit/33047afa531734dd877db807affce2752a19f6af))
* **cli:** audit Modules natively (no synthetic Program) + dart format ([2ba5a84](https://github.com/Ball-Lang/ball/commit/2ba5a84dc735044ce41123d0308fb9df7c48020e))
* **compiler+encoder:** 25 → 0 round-trip errors on top 20 pub packages ([22e6c98](https://github.com/Ball-Lang/ball/commit/22e6c984eb00d7d048941ce011b5735f22788a58))
* **compiler:** do not rewrite e.field → e['field'] for bare catch-bound vars ([680a66f](https://github.com/Ball-Lang/ball/commit/680a66f27e459d9aaed72f0ef58b555a7f83e46a))
* **compiler:** field name aliases + Set polyfills for self-host ([4f7dcbc](https://github.com/Ball-Lang/ball/commit/4f7dcbc6ad59b81c30006d2e569b858ac877d21f))
* **compiler:** honour lambda has_return + accept fill pad-char alias ([176af37](https://github.com/Ball-Lang/ball/commit/176af376068b6496dcaa1a2a5ab50a0ccacc8959))
* **compiler:** match typed alternatives in or-patterns (`case int _ || String _:`) ([c7da65c](https://github.com/Ball-Lang/ball/commit/c7da65c703574209e5c317488580cb82552ff07e))
* **compiler:** read FunctionCall.typeArgs for generic type arguments ([e403b2f](https://github.com/Ball-Lang/ball/commit/e403b2f3afc7acac3b82f0360c126ad53abce09b))
* **compiler:** TS list_push mutation + Dart compiler hardening ([a74335d](https://github.com/Ball-Lang/ball/commit/a74335dd593b9d8dbd61b83156b8de65fd95b6c4))
* conformance baseline 191→3 (188 fixed, 98.4%) ([313f31d](https://github.com/Ball-Lang/ball/commit/313f31dfb2ddb2420b5795ab6ac697cf694509e3))
* **conformance:** regenerate 229 to correct closure semantics + generator newline ([8a54639](https://github.com/Ball-Lang/ball/commit/8a546396347a1a350c765501a39171ef8738f4b2))
* **corpus:** add missing else branch in 184_nested_patterns Ball IR ([cd7cbd9](https://github.com/Ball-Lang/ball/commit/cd7cbd9a230a25abd773a54ee17f7e8db1799494))
* **corpus:** patch 165 Ball IR — replace dead Base() with empty list ([7513ed2](https://github.com/Ball-Lang/ball/commit/7513ed250ecd04b5d6620670c99386779e86bde1))
* correct expected output for 148_labeled_loops ([aa4adf4](https://github.com/Ball-Lang/ball/commit/aa4adf4d9246581cf1fa3b3304210681241f9e32))
* **cpp:** _ballMap* helper fast-paths read positional args (arg0/arg1/arg2) ([1caf993](https://github.com/Ball-Lang/ball/commit/1caf9932aacaa20573166b7ebeea459455fd2f91))
* **cpp-compiler:** ++/-- on an index target persists (read-modify-write) ([e32e3d2](https://github.com/Ball-Lang/ball/commit/e32e3d2ad6cdbf2b2b9c5599f6f10e986aa157c8))
* **cpp-compiler:** 230/230 — factory identical() + cascade write-back ([6905e0f](https://github.com/Ball-Lang/ball/commit/6905e0f8917a59ca9587053dd10eeb3112a2ce1c))
* **cpp-compiler:** add math_is_nan/is_finite/is_infinite/gcd/string_is_empty + conformance 263 ([3cbc2ed](https://github.com/Ball-Lang/ball/commit/3cbc2ed97fce1259b3386e923dcd6db31cb54e72))
* **cpp-compiler:** add math_sign handler + conformance 262 (getter properties) ([04d7c43](https://github.com/Ball-Lang/ball/commit/04d7c43cfe553b7b1f2ee8d50eb542c9ad485bb3))
* **cpp-compiler:** ball_index_of + empty expr fallback + BallValue types ([0740c50](https://github.com/Ball-Lang/ball/commit/0740c50353df6b33cc4daea89db4399bc98fe45e))
* **cpp-compiler:** ball_protobuf compiles to C++ — 0 g++ errors ([e17493d](https://github.com/Ball-Lang/ball/commit/e17493de3b27daa16ec1c6b6e8ffccadb1e48b6d))
* **cpp-compiler:** BallValue transparent types + proto helpers + copy fns ([6a9c610](https://github.com/Ball-Lang/ball/commit/6a9c6100e7f78bdd949f63745ce8db372d0ff360))
* **cpp-compiler:** fix 4 e2e codegen bugs (type patterns, enum switch, double-inf, loop-capture) ([4dcc2f5](https://github.com/Ball-Lang/ball/commit/4dcc2f59ef6f9bd4bd4efa5727255849eea5815c))
* **cpp-compiler:** fix 4 e2e runtime bugs (empty-map, throw payload, to_int clamp, control-char escape) ([0419152](https://github.com/Ball-Lang/ball/commit/0419152a3ca28f988f83db8cb4aeed06b3e1d576))
* **cpp-compiler:** int64_t literals + field access portability (Linux conformance) ([3627999](https://github.com/Ball-Lang/ball/commit/3627999591f62b81d14cf2312116280df4620749))
* **cpp-compiler:** list_slice/sublist drops its bounds (segfault) ([81ea1dc](https://github.com/Ball-Lang/ball/commit/81ea1dcbb76d91dd9d7bf7bd92c7777ca79872f2))
* **cpp-compiler:** list_sort honors a custom comparator ([3b8f043](https://github.com/Ball-Lang/ball/commit/3b8f04380df8a72126e9e45cc4abe86c47f27975))
* **cpp-compiler:** nested list literals — wrap rows in BallDyn ([cab2478](https://github.com/Ball-Lang/ball/commit/cab247892832fd5abdcc56e5646129f1b6a7f9bb))
* **cpp-compiler:** operator==, named-ctor fields, doubles, strings, patterns, matrix ([4bb397d](https://github.com/Ball-Lang/ball/commit/4bb397d9930b166531d3c7c2de4351a586af81f6))
* **cpp-compiler:** resolve 9 g++ build errors (set ops, overloads, cross-module, cascade, factory) ([4d6f190](https://github.com/Ball-Lang/ball/commit/4d6f1903f1b0637d74c0295a80657508f2bb24a7))
* **cpp-compiler:** self-host compile errors — iterating ([16a6ca1](https://github.com/Ball-Lang/ball/commit/16a6ca1ceaf8f23324d2aa3d7baba1769608a3e1))
* **cpp-compiler:** self-host down to 4 compile errors ([1212edc](https://github.com/Ball-Lang/ball/commit/1212edce48ec35961d21d7e43fc7be0f5eb2f073))
* **cpp-compiler:** static-method clamp arg-shift + empty map literal ([2da1031](https://github.com/Ball-Lang/ball/commit/2da10315d090f040a3a481165db7d99e3791d3ea))
* **cpp-compiler:** StringBuffer runtime type + switch-case break in loops ([8dc8a41](https://github.com/Ball-Lang/ball/commit/8dc8a41e589fb977a1057d8ba5a03fbde6a0a347))
* **cpp-compiler:** switch_expr + lambda issues + ball_index_of overload ([e9d2668](https://github.com/Ball-Lang/ball/commit/e9d266876eb1bc450ffafd9473094db0ef1a73ed))
* **cpp-compiler:** switch_expr compilation + ball_is_map SFINAE ([a3b897c](https://github.com/Ball-Lang/ball/commit/a3b897cef6b1fa2be862e9815065dc907ccdc68c))
* **cpp-compiler:** switch_expr plain value cases (case N => body) ([ae273b1](https://github.com/Ball-Lang/ball/commit/ae273b1f8106c5842b0c44ba8b1fa4082688da04))
* **cpp-compiler:** try-catch types, switch, parser, nested currying ([945a4ef](https://github.com/Ball-Lang/ball/commit/945a4eff5566c3937552a348e531570c420d73d6))
* **cpp-compiler:** void returns/calls, enum BallDyn equality, hashCode ([74f7594](https://github.com/Ball-Lang/ball/commit/74f7594e1a2e85ff33c9ece596c07fd5a4dc41b7))
* **cpp-engine:** improve method dispatch + super constructor chain ([33f92ba](https://github.com/Ball-Lang/ball/commit/33f92ba3b3acd8103044c34f58a499df5e963486))
* **cpp-selfhost:** runtime+compiler fixes take self-host conformance 0 → 253/277 ([6d553ab](https://github.com/Ball-Lang/ball/commit/6d553ab5442698062ead29fc2f7663061613ba80)), closes [#19](https://github.com/Ball-Lang/ball/issues/19)
* **cpp-selfhost:** self-host conformance 253 → 277/277 (all green) ([e9efdf4](https://github.com/Ball-Lang/ball/commit/e9efdf457021dbb8c5b15c4e0e77892a1a0753c3))
* **cpp,engine:** drop type_args pollution from map literals; map keys/values via entries ([0072795](https://github.com/Ball-Lang/ball/commit/00727957fd3169110a1b77ecb0beb330f55bcc69))
* **cpp/compiler:** coerce filter predicate results to bool safely ([bb5b5f1](https://github.com/Ball-Lang/ball/commit/bb5b5f1c0a476df8d76d946092597e7644e7d0e4))
* **cpp/compiler:** correct try/finally — run finally on return path, stop swallowing ([69af6f2](https://github.com/Ball-Lang/ball/commit/69af6f2665e22f30f4d1bcb21f877c40465ac8e9))
* **cpp/compiler:** dynamic-invoke closure dispatch (self-host 141->144) ([2a2a75e](https://github.com/Ball-Lang/ball/commit/2a2a75e7b23fd32045100f501360c547c6325514))
* **cpp/compiler:** emit _stdFunctionToOperator as a BallMap ([e3aa4ed](https://github.com/Ball-Lang/ball/commit/e3aa4ed5d8e6d3009a7eaf63383564191dfc36ce))
* **cpp/compiler:** emit distinct dispatch-not-found sentinel ([b5bade5](https://github.com/Ball-Lang/ball/commit/b5bade5c3da1ef286231ff02cb5f5ab76934350f))
* **cpp/compiler:** preserve thrown payload through throw/catch ([9fa4e01](https://github.com/Ball-Lang/ball/commit/9fa4e01e67383e7a1bda96d28b1f6e22047e52a7))
* **cpp/compiler:** resolve higher-order callback from value/function field ([0563e1d](https://github.com/Ball-Lang/ball/commit/0563e1d1b1b9216a7460d81cf0934f1b9b7c1310))
* **cpp/compiler:** resolve positional ctor args to param names for stub types ([b717e98](https://github.com/Ball-Lang/ball/commit/b717e988a8c3b7b343822e7742e7b1494971970b))
* **cpp/compiler:** route null_aware_call method to method dispatch ([99b8340](https://github.com/Ball-Lang/ball/commit/99b834078630521dc9bfa149a09d70a434f7ac21))
* **cpp/compiler:** top-level vars before classes + null-aware assign ([1ddf694](https://github.com/Ball-Lang/ball/commit/1ddf6940a4e0eb97b6ca93d68b61cb88b2da4b98))
* **cpp/compiler:** UTF-16 code-unit semantics for string length/substring ([5415ae4](https://github.com/Ball-Lang/ball/commit/5415ae43504c50b0a3c0bfc6e6a16fcfb4a3ab13))
* **cpp/engine:** format_timestamp emits .millisZ suffix to match Dart ([83abf4f](https://github.com/Ball-Lang/ball/commit/83abf4f031c2084e250ca497efdb6061e43a60d5))
* **cpp/engine:** list_generate accepts length/generator field names ([6d22688](https://github.com/Ball-Lang/ball/commit/6d22688fdd5d18318e6bd2fbb87f5650b459a24c))
* **cpp/engine:** print accepts message/arg0/value keys ([33d1fbc](https://github.com/Ball-Lang/ball/commit/33d1fbcea59e15a73265ccbf0f62af72c490fabe))
* **cpp/runtime:** reference-semantic program lists in BallDyn ([40ccd74](https://github.com/Ball-Lang/ball/commit/40ccd747ef00cbd852e9c4e8a83c6afcd46032af))
* **cpp/runtime:** unwrap BallDyn-in-any for List.filled length/value ([1e74621](https://github.com/Ball-Lang/ball/commit/1e746217313728777d913e4b0fc189b3bbe1b72f))
* **cpp/ts:** TS engine parity for NaN, int64, and list patterns ([76ce4ef](https://github.com/Ball-Lang/ball/commit/76ce4efb1eeac3f1afb9e1f24ae160b7ddb272ac))
* **cpp:** auto-unwrap BallDyn-in-std::any in constructor ([c971dab](https://github.com/Ball-Lang/ball/commit/c971dabdfc4f96ac1cbe0202484d4cc77996f697))
* **cpp:** ball_is_map SFINAE for BallDyn + handles/call dispatch ([c92e857](https://github.com/Ball-Lang/ball/commit/c92e857e7a4e67384cfe64c7c2170d5f2485ae86))
* **cpp:** ball_scope_bind for OOP self-binding gate ([cffafb0](https://github.com/Ball-Lang/ball/commit/cffafb08dfeb3522d6e335efb3fbd8910f1ac43f))
* **cpp:** BallObjectRef aliasing, map dispatch, and self-host runtime helpers ([06c3da9](https://github.com/Ball-Lang/ball/commit/06c3da931e164a13e399e06b7bc7febc8c4350c7))
* **cpp:** close the e2e runtime gaps — lists, compound-assign, exceptions, closures ([5dae524](https://github.com/Ball-Lang/ball/commit/5dae5249afee04487478a8ca8551c7e8deb3c585))
* **cpp:** emit _Scope(parent) as child(parent) for proper lexical scopes ([00a3151](https://github.com/Ball-Lang/ball/commit/00a3151171c51b722e4eca9b2d93b8a757010087))
* **cpp:** emit real for/while in expression context when body has no jumps ([f4e4c28](https://github.com/Ball-Lang/ball/commit/f4e4c280d3141dfe5048a817f8303544ca15d6e6))
* **cpp:** emit real for/while loops in expression context (was stubbed) ([778a93d](https://github.com/Ball-Lang/ball/commit/778a93df1d94ee9294821959211cd34e754fcab9))
* **cpp:** emit real statement bodies for expression-context for/while loops ([54f8ecb](https://github.com/Ball-Lang/ball/commit/54f8ecb70904a1f1269ce24d05a5a5c045bcbc54))
* **cpp:** format double Infinity/NaN via ball_to_string in BallDyn string cast ([3744c1e](https://github.com/Ball-Lang/ball/commit/3744c1e54fac7da1445c9e1b6fb31cb786083797))
* **cpp:** gcc/clang-compat — ball_assign for std::string = BallDyn (batch 2) ([e9db111](https://github.com/Ball-Lang/ball/commit/e9db111d096afad69f9ae26ce3550aed38b0ae6f))
* **cpp:** gcc/clang-compat — remaining most-vexing-parse sites (batch 4) ([3f264af](https://github.com/Ball-Lang/ball/commit/3f264afc12a39f3dd5222639eef3468ab53aa051))
* **cpp:** gcc/clang-compat — static_cast field/index access (batch 5) ([755a38a](https://github.com/Ball-Lang/ball/commit/755a38a9d35f6dc97bb2dab14b13d31072a61265))
* **cpp:** gcc/clang-compat — vexing-parse, integral ==/=, string-assign (batch 3) ([cdea111](https://github.com/Ball-Lang/ball/commit/cdea1114ff61c152dfb06b0fad5b437fbfe3508c))
* **cpp:** gcc/clang-compat in generated engine_rt.cpp (batch 1) ([3ed2c21](https://github.com/Ball-Lang/ball/commit/3ed2c2189dbeacc8520cde9fb30df7b03e2428d1))
* **cpp:** guard self-hosted engine BallDyn methods with BALL_SELFHOST ifdef ([64f426f](https://github.com/Ball-Lang/ball/commit/64f426f95123746d30efb92bd6237e87fbb09c54)), closes [#ifdef](https://github.com/Ball-Lang/ball/issues/ifdef)
* **cpp:** handles/call dispatch + direct debug probes ([391494d](https://github.com/Ball-Lang/ball/commit/391494d4d6ffe744c33146befca01af0e1141674))
* **cpp:** improve C++ compiler class emission + fix engine toString/exception bugs ([868c795](https://github.com/Ball-Lang/ball/commit/868c795c7e44f30921c6213a0ca8e757789c0aee))
* **cpp:** is-check type functions as free functions in emit runtime ([026d9f1](https://github.com/Ball-Lang/ball/commit/026d9f13f583166cbc8511726b46390c5eeca06d))
* **cpp:** labeled break/continue across loop bodies; refresh snapshots ([95a9daa](https://github.com/Ball-Lang/ball/commit/95a9daa7be498c53109302649752a72ce79626c8))
* **cpp:** lambda statement-form bodies, list_pop element return, string repeat ([1691f44](https://github.com/Ball-Lang/ball/commit/1691f44efecc05890d24dcf6ff5734a98321dff2))
* **cpp:** list_sort default comparison uses numeric order ([34c9582](https://github.com/Ball-Lang/ball/commit/34c95826f3e4ca7369dd0bdeb5227ecc0b432b4e))
* **cpp:** native engine parity for maps, NaN, unicode, and patterns ([eca7735](https://github.com/Ball-Lang/ball/commit/eca7735a67719099b952c0b5440c5b6c9edf1f96))
* **cpp:** positional list index for integer BallDyn keys (list[i] reads) ([b2e6f2c](https://github.com/Ball-Lang/ball/commit/b2e6f2c3e2e045da0e22aaeae2c33be766b7d4d0))
* **cpp:** preserve proto3 zero scalars in self-host harness; add BallOrderedMap ([f12c1d3](https://github.com/Ball-Lang/ball/commit/f12c1d312818173d9f9a6cb78173a124f45cac30))
* **cpp:** preserve rethrown exception payload, real JSON codec, Map.keys ([9175102](https://github.com/Ball-Lang/ball/commit/917510236f1ef9414ecc97ccc11243fa992a9522))
* **cpp:** proto helpers + for-init scoping + conformance alignment ([2c3201c](https://github.com/Ball-Lang/ball/commit/2c3201cb5166db22598981ab51a3cd958bba80db))
* **cpp:** recursive BallDyn unwrapping in constructor (while instead of if) ([5ac745c](https://github.com/Ball-Lang/ball/commit/5ac745c9caa7137f7b6ce82fc93b0c99a41b8a1b))
* **cpp:** remove #ifdef BALL_SELFHOST, add forward declarations instead ([2ac3980](https://github.com/Ball-Lang/ball/commit/2ac398030e1f8b4b6745def089a2d91750132c17)), closes [#ifdef](https://github.com/Ball-Lang/ball/issues/ifdef)
* **cpp:** remove bloated skip list — honest 75/135 C++ self-host ([8a10613](https://github.com/Ball-Lang/ball/commit/8a106135ee2c7c555cc7714ebb417daf48b9d29b))
* **cpp:** restore self-host build + fix generators, map order, StringBuffer (212→221/227) ([1ef12f5](https://github.com/Ball-Lang/ball/commit/1ef12f53194d666b4171fef5ef0d9ab69efd546e))
* **cpp:** restore self-host tally 156/205 — HasField harness + regen ball_dyn embed ([c6ac4ea](https://github.com/Ball-Lang/ball/commit/c6ac4ea0dca978fbfaa38a2e19d86a07d55e890a))
* **cpp:** scope reference semantics in child() + runtime BallOrderedMap extensions (211/231) ([8052d78](https://github.com/Ball-Lang/ball/commit/8052d781b9421ca678d02594d96fd2524cc86fe1))
* **cpp:** self-host engine compiles + runs on latest IR (0→56/175) ([861cb5f](https://github.com/Ball-Lang/ball/commit/861cb5f0fc35cea050f8a9d5ddaa4d1deef0841f))
* **cpp:** self-host engine_rt.cpp compiles under g++ ([#19](https://github.com/Ball-Lang/ball/issues/19)) ([726c69f](https://github.com/Ball-Lang/ball/commit/726c69f09efdad4d482e2c9330414c0973175b49))
* **cpp:** self-host list equality and numeric predicate intrinsics ([e540e08](https://github.com/Ball-Lang/ball/commit/e540e08be1ad85b3ea6e95a02260bceeab7391bf))
* **cpp:** stop duplicate engine_rt TU in selfhost conformance ([f46b187](https://github.com/Ball-Lang/ball/commit/f46b1874a119b1781ecdbe93d05fc06cf5a9036c))
* **cpp:** struct for all classes + is-check free functions ([17186d7](https://github.com/Ball-Lang/ball/commit/17186d7bb8954f088abebf62316fc05822178f74))
* **cpp:** unwrap BallDyn-in-any in ball_map_entries — OOP field reads work ([17e8b25](https://github.com/Ball-Lang/ball/commit/17e8b25b0198bbce4aef35884a43522cd0c1dcc5))
* Dart engine scoping bug, C++ build error, CI gate updates ([40706ef](https://github.com/Ball-Lang/ball/commit/40706efd5f4a582c47ad6a786b6dad6353e1fcc3))
* **dart-compiler:** async safety return in code_builder path ([4419a74](https://github.com/Ball-Lang/ball/commit/4419a7498406d4a420eadc2f7446434c19769d20))
* **dart-compiler:** conditional switch exhaustiveness + async safety return ([213aa80](https://github.com/Ball-Lang/ball/commit/213aa80f7f8369105d99ed3ec3acdfa528cd1067))
* **dart-compiler:** DateTime accessors + async nullable returns + baseline (191→37) ([b04ef13](https://github.com/Ball-Lang/ball/commit/b04ef130d149f23d39496f1c56d476c5b4af0f81))
* **dart-compiler:** DateTime component accessors + re-encode 189 + baseline ([f4f12fa](https://github.com/Ball-Lang/ball/commit/f4f12fad82b84f2b55352711c3b8f31ec6ec8b1c))
* **dart-compiler:** exclude generators from safety return (can't return value) ([3176283](https://github.com/Ball-Lang/ball/commit/3176283c193a7576d03e4eb1c3676318b68c39fb))
* **dart-compiler:** flexible field name resolution for collections ([5373a84](https://github.com/Ball-Lang/ball/commit/5373a84d039478149ee756afd13f435e4655a458))
* **dart-compiler:** format_timestamp uses UTC DateTime ([0c33bd6](https://github.com/Ball-Lang/ball/commit/0c33bd653136c8849cc6524523f65a77edad52bb))
* **dart-compiler:** handle 4-field math_clamp (user static method clamp) ([c00d9f1](https://github.com/Ball-Lang/ball/commit/c00d9f13440cf5b71125bc54fa42a510c10afd39))
* **dart-compiler:** handle duplicate field names in list_slice (sublist) ([ce940ce](https://github.com/Ball-Lang/ball/commit/ce940ce1ca325c8c9c4c0ac931901798c33b1455))
* **dart-compiler:** infer this.field initializing formals for OOP constructors ([e59e6e5](https://github.com/Ball-Lang/ball/commit/e59e6e5e50e4dd7e9a83daac301cd2b22c2f4b24))
* **dart-compiler:** nullable async return type for free functions ([0ac543f](https://github.com/Ball-Lang/ball/commit/0ac543fd9dc44e622e2309aa2d23eb5d6a694125))
* **dart-compiler:** nullable return types + switch value cases + snapshots ([16598d7](https://github.com/Ball-Lang/ball/commit/16598d7b375310ff662154b86119a433d5126f45))
* **dart-compiler:** prevent input rename when shadowing top-level variable ([a4c98d0](https://github.com/Ball-Lang/ball/commit/a4c98d05509a42b576765e23dde2f0204e7effc8))
* **dart-compiler:** replace Object→dynamic in generic type parameters ([cbc4d3f](https://github.com/Ball-Lang/ball/commit/cbc4d3f778204733ad51500d28e7a04b431218e0))
* **dart-compiler:** revert ALL nullable return types (restore 6 async programs) ([9c5b75d](https://github.com/Ball-Lang/ball/commit/9c5b75d226ffb13ff14ced5a864a1c1b833846ca))
* **dart-compiler:** revert nullable returns to async-only (prevents regression) ([f2184ea](https://github.com/Ball-Lang/ball/commit/f2184ea951f38399d00c219bdd44dcd12426344d))
* **dart-compiler:** skip 'elements' field in _compileMapCreate ([2e0a762](https://github.com/Ball-Lang/ball/commit/2e0a76259103df10ee6be3d19840fb48d0e30e8f))
* **dart-compiler:** strip module prefix from constructor FunctionCall names ([957a6d4](https://github.com/Ball-Lang/ball/commit/957a6d44f516ddbcef0f36a2674bf27bed62de6d))
* **dart-compiler:** suppress self→this rewrite when a local `self` shadows ([b823b9e](https://github.com/Ball-Lang/ball/commit/b823b9e71f6726a560466237521faecf3a4eca39))
* **dart-compiler:** switch_expr adds default wildcard for exhaustiveness ([ef35532](https://github.com/Ball-Lang/ball/commit/ef355322e733e360cacc79abb6987ee9c63f5456))
* **dart-compiler:** switch_expr handles value-field cases + is_default ([9e6ecbd](https://github.com/Ball-Lang/ball/commit/9e6ecbd11cc259c6668e5219bed13914ac8e74eb))
* **dart-compiler:** translate self→this in instance method bodies ([d2a8727](https://github.com/Ball-Lang/ball/commit/d2a8727c9ef372bd4d59716e62f161464a5b3beb))
* **dart-encoder:** fix catch-variable aliasing, cascade routing, empty stmts ([a9d2ef8](https://github.com/Ball-Lang/ball/commit/a9d2ef8dcf5e7a154734f1b1c4c2112ac827162a))
* **dart-encoder:** padLeft/padRight arg1 → padding (was fill) + conformance 264 ([031c73b](https://github.com/Ball-Lang/ball/commit/031c73b779b891894b7f3cfcf78109d343461bba))
* **dart-encoder:** route getter properties + missing methods to Ball std ([657d1a6](https://github.com/Ball-Lang/ball/commit/657d1a62052c2d41e023531f788916802e3661fd))
* **dart-encoder:** use left/right field names for binary std functions + 3 conformance programs ([3b80515](https://github.com/Ball-Lang/ball/commit/3b805158de7ed4d2ab156d0ee64ed2cbde7055b3))
* **dart/compiler:** surface failed modules + handle goto/label in stmt context ([0c621c1](https://github.com/Ball-Lang/ball/commit/0c621c17fe292de246622a2c8f4ad045edc8f111))
* **dart:** conformance test prefers expected-output file over `dart run` subprocess ([4aa1853](https://github.com/Ball-Lang/ball/commit/4aa185375e67c79414c4568c3473f51826f374d2))
* **dart:** don't clobber a block-bodied setter's field with its null return ([fb46ac3](https://github.com/Ball-Lang/ball/commit/fb46ac3606cfc2fba8b01a9cccd5d85394a8d8ab))
* **dart:** finish self-host codegen — map-merge, catch-var promotion, nullable call ([d9f2ef5](https://github.com/Ball-Lang/ball/commit/d9f2ef5cffcaac50dcdccfb8f0b8474f5c252a85))
* **dart:** guard against unbounded constructor recursion (Stack Overflow / CI hang) ([60b9680](https://github.com/Ball-Lang/ball/commit/60b9680d425995b191978a190e75342c269d5812))
* **dart:** unwrap BallMap to a plain Map before dispatching to base-function handlers ([93cf89d](https://github.com/Ball-Lang/ball/commit/93cf89d587917e479688a0fb95543a69c5c5b600))
* **encoder)+feat(protobuf:** Editions Phase 6b — private-call fix + portability proof ([b321c31](https://github.com/Ball-Lang/ball/commit/b321c3102062b509a4c078c0d5ff44e42ba20c45))
* **encoder:** dedupe extension members across part files ([74f5ddd](https://github.com/Ball-Lang/ball/commit/74f5ddd11e31c7c5e2b8a0674076937e45d386fc))
* **encoder:** emit for-loop init as expression tree, not string ([22367ec](https://github.com/Ball-Lang/ball/commit/22367ecfc462e05472f8f771421fae6af76e1849))
* **encoder:** fix read-only map + re-encode 4 conformance programs ([62bde97](https://github.com/Ball-Lang/ball/commit/62bde97aa46341389f1c6632d9f32177830925c3))
* **encoder:** map Dart replaceAll to std.string_replace_all ([633ae72](https://github.com/Ball-Lang/ball/commit/633ae72e3d0b350e22fc019a3510015bd23fbb9c))
* **encoder:** migrate to analyzer 13.0.0 AST API ([ddf51bb](https://github.com/Ball-Lang/ball/commit/ddf51bb65955784ad32574492ee681bd34b32aec))
* **encoder:** preserve generic type args + fix this→self encoding ([0969041](https://github.com/Ball-Lang/ball/commit/0969041ca29c11f910976bd4ada452761dd0867b))
* **encoder:** preserve null-aware method call for toString() and unary routes ([24776ea](https://github.com/Ball-Lang/ball/commit/24776eaf84c0610cd3b57fa63667476c5af20e8a))
* **encoder:** use bundler moduleResolution for .ts imports ([7121229](https://github.com/Ball-Lang/ball/commit/712122937937b1ecf0b52f5f2deef72e6bec4bef))
* **engine,cpp:** persist index assignment (map mutation) in self-host engine ([2451fd4](https://github.com/Ball-Lang/ball/commit/2451fd49b76b180e814bfd6b135f9591d2eed09a))
* **engine:** apply no-body constructor initializers in messageCreation ([06cdeef](https://github.com/Ball-Lang/ball/commit/06cdeef51cbfc12d3f30f59348bd9372fb6b1b14))
* **engine:** BallListRef aliasing for native list mutations ([437773e](https://github.com/Ball-Lang/ball/commit/437773e9b43dfd5cce693e73f52b0fa7a2c8203a))
* **engine:** BallListRef/BallOrderedMapRef aliasing and map patterns ([a4ba5fc](https://github.com/Ball-Lang/ball/commit/a4ba5fc830ead35d53c06963c52dc33bbe4ca5fc))
* **engine:** BallOrderedMap map intrinsics for std_collections ([25cfad1](https://github.com/Ball-Lang/ball/commit/25cfad1a1ddf6680888b15303d50f50db9f805e0))
* **engine:** BallOrderedMapRef aliasing for native map mutations ([3b1398b](https://github.com/Ball-Lang/ball/commit/3b1398be0169f7937fe728eaa030db2c8c5da5e4))
* **engine:** correct NaN/inf predicates and -0.0 formatting ([ade97d2](https://github.com/Ball-Lang/ball/commit/ade97d2eabac5e9e330a35ed8ea3f0bab51a448a))
* **engine:** dispatch std arithmetic/comparison ops to operator overrides ([334fd54](https://github.com/Ball-Lang/ball/commit/334fd541da2d3db9e32f27aa66e3ed43948e35f7))
* **engine:** duck-typed _typeRefToStr for compiled engine compatibility ([602a67c](https://github.com/Ball-Lang/ball/commit/602a67c694f9e9d3cfecf3653be832a3caf5cfd9))
* **engine:** enum .values sorted by declaration index ([0913725](https://github.com/Ball-Lang/ball/commit/09137256932749f615f105e491da984e24863ad6))
* **engine:** for-loop closures capture a fresh per-iteration variable ([208f6ad](https://github.com/Ball-Lang/ball/commit/208f6ad0854e4454a802f59d2646942f380a0b11))
* **engine:** GCC json_const, null field bind, int-key maps ([7c36efb](https://github.com/Ball-Lang/ball/commit/7c36efbe1820d5e56c160c860c2de84c3496f83f))
* **engine:** harden _typeRefValueToString + regenerate compiled_engine.ts ([0bfe300](https://github.com/Ball-Lang/ball/commit/0bfe300fd67f2b940bc18c1dcd21fcef3a3b7463))
* **engine:** OOP getter dispatch and scope child semantics for self-host ([ca039a6](https://github.com/Ball-Lang/ball/commit/ca039a6c0d82f29caff15d818a777a74c9472f59))
* **engine:** prefer __type_args__ field over metadata for compiled engine compat ([caeded0](https://github.com/Ball-Lang/ball/commit/caeded0d4ace25928818854da50fbb580a5c72cb))
* **engine:** print enum values as EnumName.value instead of the raw map ([6290c94](https://github.com/Ball-Lang/ball/commit/6290c947042088347944fcc9d5f7a3e05683358f))
* **engine:** resolve super via lookup(self) not has(self) ([064581c](https://github.com/Ball-Lang/ball/commit/064581cb9e9bb2fb1e3664271213ec6c1ddd82d2))
* **engine:** unwrap Ball numeric wrappers in math_floor/ceil/round/abs/trunc ([b843ced](https://github.com/Ball-Lang/ball/commit/b843cedc546ad642c6833a6b9edb17225b3d5cdb))
* **engine:** write mutated instance map back after obj.field = val ([eeee02c](https://github.com/Ball-Lang/ball/commit/eeee02c715be242f9cefcf547f0df4f8dc98af62))
* enrich conformance std modules with collection method declarations ([68c394d](https://github.com/Ball-Lang/ball/commit/68c394da426072ec25668a229657bf06fb17d2ef))
* **protobuf:** pass upstream Editions conformance — codec/bridge fixes + CI ([e55bfa3](https://github.com/Ball-Lang/ball/commit/e55bfa3d16b1cfb2f9e5497b1ac509c22a55c0d1))
* re-encode corpus programs + TS compiler tweaks (WIP) ([481d75c](https://github.com/Ball-Lang/ball/commit/481d75c0ff6667d6530d0c47463820d3a918433d))
* rename "TS Hand-Written Engine" → "TS Self-Hosted Engine" ([2b94e40](https://github.com/Ball-Lang/ball/commit/2b94e401a0184fe5162ddb35bf0247bfe41b51df))
* **resolver:** correct pub.dev archive URL, prioritize pre-built Ball artifacts ([29835dd](https://github.com/Ball-Lang/ball/commit/29835dd55f1cd5543a33868ab27a8e3238a1e038))
* restore 148_labeled_loops expected output to match Dart source ([f24e80c](https://github.com/Ball-Lang/ball/commit/f24e80cc91fddfe8c38777e7db61697054f9f49f))
* restore original 242_generic_fn_chains Ball IR ([adbbfdf](https://github.com/Ball-Lang/ball/commit/adbbfdf2e24916df67c24e2cb9617c12e2c74877))
* revert 163/165 re-encodings (caused regressions) + baseline 43 ([6648d14](https://github.com/Ball-Lang/ball/commit/6648d14f1594ac4a7f5f8861ab3a52abed03c6cd))
* **self-host:** BallDouble literals + Map.from spread + TS compiler fixes ([e9d9a7b](https://github.com/Ball-Lang/ball/commit/e9d9a7bbd48b4426c7c830b1d4dc237431f38f6d))
* **self-host:** BallDouble.toString + globalThis + divide_double ([277e087](https://github.com/Ball-Lang/ball/commit/277e087c89339c612a9d65a69207564e6bac5280))
* **self-host:** List.of spread + field merge fix ([38d7b63](https://github.com/Ball-Lang/ball/commit/38d7b63f6800a211b56fb90ee3d2e893c6f2a27c))
* **self-host:** null-prototype scope bindings + Set.isEmpty ([226d2b9](https://github.com/Ball-Lang/ball/commit/226d2b97bc0e19c4d299d480d2e7159fb4260de0))
* **self-host:** regenerate round-trip engine to fix 113 + 204 parity ([591ef02](https://github.com/Ball-Lang/ball/commit/591ef029a0cc688725b452c8d2bdb218cb4c1f79))
* **self-host:** Set.isEmpty, Array.setAll, in-place sort ([94f0e1f](https://github.com/Ball-Lang/ball/commit/94f0e1f6d34add3879b1b954f1f2f71bb85bb911))
* **self-host:** StringBuffer string concat + List.of/from spread ([6523bb8](https://github.com/Ball-Lang/ball/commit/6523bb84daea4154e5a2ffb78d9ae819262814e2))
* **self-host:** StringBuffer, Set.length, MapEntry.arg0 fixes ([0438ce3](https://github.com/Ball-Lang/ball/commit/0438ce3d802ce7b717066a9fd259fbf85690de75))
* **shared:** regenerate stale ball_protobuf.{json,bin} + add Ball freshness gate ([9d60e97](https://github.com/Ball-Lang/ball/commit/9d60e97b7cf6a41a26e8672a9be26d90156fab8f))
* **shared:** regenerate stale ball_protobuf.{json,bin} for std_convert routing ([286acdd](https://github.com/Ball-Lang/ball/commit/286acddbae5df81bac35b3d63c10af2ec0555d22))
* **test:** Any-aware loadProgram + typeDefs in buildProgram (CI Dart gate) ([ba48c4a](https://github.com/Ball-Lang/ball/commit/ba48c4a7e289919ee865885f719a32c1c4b25183))
* **test:** repair malformed return statement in 164_oop_inheritance ([54b2a30](https://github.com/Ball-Lang/ball/commit/54b2a30ac2aa729bd8df535e52f5c40e98e7ccb7))
* **test:** rewrite 169_pattern_destructure to canonical switch_expr IR ([ab8ef59](https://github.com/Ball-Lang/ball/commit/ab8ef5915542aa6f89c55efa41ad20dee8706da5))
* **ts-compiler:** add list_foreach + map_foreach std function handlers ([263f519](https://github.com/Ball-Lang/ball/commit/263f5197c7d97483edb31ebfc5534004e966d386))
* **ts-compiler:** add Number.prototype polyfills for Dart num/int methods ([c7bc07f](https://github.com/Ball-Lang/ball/commit/c7bc07faa84eaf31fa194c096ab90e44aa21784c))
* **ts-compiler:** add parse_timestamp + time_components std_time handlers ([b023b25](https://github.com/Ball-Lang/ball/commit/b023b2597dde8bf4fd4ef8ffbc2f6c0e9a0b81ca))
* **ts-compiler:** add std_time module recognition + now/format_timestamp + sort fix ([07a7f7c](https://github.com/Ball-Lang/ball/commit/07a7f7c1fa7692cd61136a751a9fe87aa1a2b899))
* **ts-compiler:** add utf8/base64 encode/decode + generator function* + std_time ([123acb9](https://github.com/Ball-Lang/ball/commit/123acb914c078f1df69e27fa5822268c511e0b3b))
* **ts-compiler:** async await detection + list_generate/list_filled JS emit ([2e5dad8](https://github.com/Ball-Lang/ball/commit/2e5dad8a2f14b3ad100af399a1e03797b9bf41ae))
* **ts-compiler:** auto-await async function calls + async main detection ([3152279](https://github.com/Ball-Lang/ball/commit/31522793e460ca1a96bee784a12b5271aa8cf8ce))
* **ts-compiler:** BallDouble isNaN/isFinite/isNegative + NaN-safe equality ([40609fa](https://github.com/Ball-Lang/ball/commit/40609fa4dea209305b7b1edbc2178c3af6b6358c))
* **ts-compiler:** BallDouble propagation through arithmetic + double literals ([5f58eb4](https://github.com/Ball-Lang/ball/commit/5f58eb43666398d98770d1ca3d5333db987f90ad))
* **ts-compiler:** BallValue transparent constructors + is-checks ([b8b0f95](https://github.com/Ball-Lang/ball/commit/b8b0f95321f44ef67749116b83e9f82568c91b58))
* **ts-compiler:** BallValue type handling + proto helpers for self-host ([c7a670e](https://github.com/Ball-Lang/ball/commit/c7a670eb0f074f4ef7e483971ef79d222fe34c22))
* **ts-compiler:** constructor field init for single-input convention ([c4e1e16](https://github.com/Ball-Lang/ball/commit/c4e1e16803630587fd9085cff306c5d452ab5814))
* **ts-compiler:** dedup also renames function REFERENCES (not just calls) ([806f142](https://github.com/Ball-Lang/ball/commit/806f14293751930c0ad4ea9570a2aa3e1283e4dc))
* **ts-compiler:** deduplicate function names across inline modules in compileModule ([e860101](https://github.com/Ball-Lang/ball/commit/e8601013f2c89b032374b1d421997332099ec249))
* **ts-compiler:** divide_double returns BallDouble for .0 formatting ([f5b0be2](https://github.com/Ball-Lang/ball/commit/f5b0be2949e628e692bcbe89ea773f0b2587ef00))
* **ts-compiler:** do-while(false) switch wrapper + Set.push polyfill ([667544f](https://github.com/Ball-Lang/ball/commit/667544f0ce54981197d9b8107ed47974569aaa71))
* **ts-compiler:** fix Infinity/NaN/-0 formatting + utf8/base64 handlers ([9d84d40](https://github.com/Ball-Lang/ball/commit/9d84d406d060bd469d06896d02ec20d7dcf9703e))
* **ts-compiler:** fix type error in inherited fields superclass walk ([bc66018](https://github.com/Ball-Lang/ball/commit/bc66018bb73e456be885904ec999957367c90830))
* **ts-compiler:** generator function* support + yield-aware IIFE wrappers ([baa3de2](https://github.com/Ball-Lang/ball/commit/baa3de285269fe745264b40e51e288a5c6308d9c))
* **ts-compiler:** guard catch instanceof with typeof + catch-all types ([706634d](https://github.com/Ball-Lang/ball/commit/706634d35fca1cbb2795a6832a00ee35cf9ca94e))
* **ts-compiler:** handle duplicate field names in list_slice ([56002ee](https://github.com/Ball-Lang/ball/commit/56002eee52b75afe5ae641587e2f514553dc8c97))
* **ts-compiler:** IIFE wrappers for control-flow-as-expression + baseline update ([92f5a94](https://github.com/Ball-Lang/ball/commit/92f5a946370fd4643c3b7051005f978c3c87823d))
* **ts-compiler:** include inherited fields in class method context ([0cc0cf4](https://github.com/Ball-Lang/ball/commit/0cc0cf4cdbee98f38902e15f0b2ea8752e858747))
* **ts-compiler:** inline math_clamp + string_code_unit_at + string_replace ([7dd51e7](https://github.com/Ball-Lang/ball/commit/7dd51e7c11de6ffcefc6a5b00b31e9f031780f9d))
* **ts-compiler:** narrow double type-guard in compileStructuredPattern ([3f73f34](https://github.com/Ball-Lang/ball/commit/3f73f34cd0dde5841eee42d54063a8cfcb20814a))
* **ts-compiler:** not_equals uses __ball_eq for NaN/BallDouble consistency ([54784d9](https://github.com/Ball-Lang/ball/commit/54784d95ed9ec88ff40417dc5faa2f1ea675aab3))
* **ts-compiler:** numeric sort comparator + baseline update (191→86) ([53ee353](https://github.com/Ball-Lang/ball/commit/53ee35369025fb9c5de8b179e75212b5ba896b1f))
* **ts-compiler:** OOP hierarchy, operator overloading, generators, patterns ([771ebeb](https://github.com/Ball-Lang/ball/commit/771ebebf3cf6b7f9bde28dc1db4b9a2828bb67f6))
* **ts-compiler:** route module:Class.new calls to new Class() constructors ([a301b99](https://github.com/Ball-Lang/ball/commit/a301b992f178c3b7b6cf99cc71433108c6ae1b19))
* **ts-compiler:** Set.prototype.push/length polyfill + var for-loop ([cea5433](https://github.com/Ball-Lang/ball/commit/cea5433e14ad3aebc9d11ff2e438679e8588a2f5))
* **ts-compiler:** shadow-rename conflicting variables + ~/= operator ([68e9ed1](https://github.com/Ball-Lang/ball/commit/68e9ed1231befed92f3415d3f3a16439402471b7))
* **ts-compiler:** StringBuffer, Map.fromEntries, const→let for reassigned input ([1160748](https://github.com/Ball-Lang/ball/commit/1160748688f8cd5afc08b9d9a7c8e460efed44c1))
* **ts-compiler:** super→super keyword + Infinity/NaN/-0 formatting ([fd3b4f2](https://github.com/Ball-Lang/ball/commit/fd3b4f22b48dbcc7c9662aa4d727c2b43476c241))
* **ts-compiler:** to_double/int_to_double return BallDouble for .0 formatting ([90c2cfa](https://github.com/Ball-Lang/ball/commit/90c2cfa06c540b069839e6eb0df8b2148741c65d))
* **ts-compiler:** translate self.field → this.field in class methods ([c2b8c10](https://github.com/Ball-Lang/ball/commit/c2b8c10210c513b7b408f370594ad499dfdf0b96))
* **ts-compiler:** translate standalone self→this in class methods ([296a514](https://github.com/Ball-Lang/ball/commit/296a5143c017aec289e9807504deefaeddb3006a))
* **ts-compiler:** type-check typed wildcard patterns in switch (`case T _:`) ([4a897d4](https://github.com/Ball-Lang/ball/commit/4a897d47b310e9012612d658c524a9f6310e5510))
* **ts-compiler:** use let instead of const for top-level variables ([02e032e](https://github.com/Ball-Lang/ball/commit/02e032ef523344c2242ced06ac387f40cfff3203))
* **ts-compiler:** use var for for-loop init (Dart shared-variable semantics) ([1385d03](https://github.com/Ball-Lang/ball/commit/1385d03b7becde6d6fca2c096a68c6c99a0d306e))
* **ts-compiler:** VarPattern with type annotation generates type-check condition ([7ca74d0](https://github.com/Ball-Lang/ball/commit/7ca74d037c0176c24ee05b12f3ea68582524cd30))
* **ts-compiler:** which* method delegation + length getter + std overrides ([b96b499](https://github.com/Ball-Lang/ball/commit/b96b499baf9631a05f465df01fe05966e68e523d))
* **ts-compiler:** wrap try-as-expression in IIFE ([97ea147](https://github.com/Ball-Lang/ball/commit/97ea14799e397d5ba53dbf74157f956f07daaa18))
* **ts-encoder:** split base modules by prefix (std, std_collections, std_io) ([b287b08](https://github.com/Ball-Lang/ball/commit/b287b088278183ae347f2e11f1528aa603761933))
* **ts-engine:** eval for-loop block init in forScope, not child scope ([2d835d1](https://github.com/Ball-Lang/ball/commit/2d835d12d86228daf0b0054a2fd78209947a20cb))
* **ts-engine:** map clear uses delete instead of length=0 ([6c46620](https://github.com/Ball-Lang/ball/commit/6c4662063f89caa1886293a898c10d137307ebb1))
* **ts-engine:** remove duplicate encoder-generated test scan ([b95a61d](https://github.com/Ball-Lang/ball/commit/b95a61d1fa5ef24a6e943fee7346e9f62e89ab55))
* **ts/compiler test:** assert BallValue emitted as class, not type alias ([d780fed](https://github.com/Ball-Lang/ball/commit/d780fed7381f5cab2370adec2b1906b2ca61c044))
* **ts/compiler test:** correct BallEngine ctor arity in conformance harness ([31a10c9](https://github.com/Ball-Lang/ball/commit/31a10c902f3ca61ffebdc208d471e4eb0610ec6f))
* **ts/compiler:** only swallow unknown-function errors in std dispatch probes ([7ccc9f4](https://github.com/Ball-Lang/ball/commit/7ccc9f42a642c360089881e2a13259a9cfbfd796))
* **ts/encoder:** null as empty literal, polymorphic +, strict mode + warnings ([5b7c92b](https://github.com/Ball-Lang/ball/commit/5b7c92bc925ff2743d31e8d2cffcb9f5f1d67f58))
* **ts:** bounds-check list index access to throw Dart-style RangeError ([a83ede6](https://github.com/Ball-Lang/ball/commit/a83ede64c9c19f1139fe880af3e856672a90cb19))
* **ts:** canonicalize comparison/shift std fn names across encoder+compiler ([125e518](https://github.com/Ball-Lang/ball/commit/125e518ea5934a301f0d2a6afa6acdb76015ab0d))
* **ts:** defer generators to the native engine (211->216) ([bf7667e](https://github.com/Ball-Lang/ball/commit/bf7667e8a81d5271cc242a1c7fcbf51cdfae89b6))
* **ts:** don't strip self when unwrapping single-param method input (216->220) ([d69f2c2](https://github.com/Ball-Lang/ball/commit/d69f2c2f965608c5e56678d0f458d8643b57978f))
* **ts:** emit all math_* base functions in TS compiler ([#47](https://github.com/Ball-Lang/ball/issues/47)) ([6ad5771](https://github.com/Ball-Lang/ball/commit/6ad5771462f5959696ab527f779da47ddb878c3a))
* **ts:** list_concat handles map merge — fixes inheritance/virtual dispatch (220->223) ([dc6822f](https://github.com/Ball-Lang/ball/commit/dc6822f6f0e59ab13fa3edc862d8d1e06556b9d1))
* **ts:** map_create must read entries as own property (223->224) ([2aac810](https://github.com/Ball-Lang/ball/commit/2aac810b4977515625cd256251385743bcf7dd5f))
* **ts:** parity for fixtures 230-255 ([869dd38](https://github.com/Ball-Lang/ball/commit/869dd389c63260acd76004fe0ccc79aa6bdd6333))
* **ts:** preserve int64 precision for large integer literals ([ea5b4f3](https://github.com/Ball-Lang/ball/commit/ea5b4f3515e8b79a4256d30810507573dcff3ea1))
* **ts:** share engine setup between ts/engine and Phase 2.7b harness ([823827c](https://github.com/Ball-Lang/ball/commit/823827cd1969b81e5513b607dbf921a5bb34e49b))
* **ts:** TS self-host conformance 198->211 (Object.prototype pollution, std field-name fixes, module:fn calls) ([382a4f1](https://github.com/Ball-Lang/ball/commit/382a4f12ce861c10c08ce2f13520bba87f539638))
* **ts:** use __bts instead of e._ball_to_string for async/generator support ([8055dbc](https://github.com/Ball-Lang/ball/commit/8055dbc7c4a10e679bd2a6aaa4f00988cb86968b))


### Features

* 125 conformance programs + CI matrix + TS engine collection routing ([b6a2301](https://github.com/Ball-Lang/ball/commit/b6a230162bea7739727be7fc4df3f9fb161848fd))
* add ball_proto module — protobuf compatibility layer for Ball ([75cda05](https://github.com/Ball-Lang/ball/commit/75cda0585d4a9458613d3e76ca303c8345802760))
* add sealed BallValue class hierarchy for typed value representation ([7318685](https://github.com/Ball-Lang/ball/commit/7318685bfca5f46875139c95a77c7a6a395c5b83))
* ball publish command + playground improvements ([4cbeeb6](https://github.com/Ball-Lang/ball/commit/4cbeeb62ba39f8cdf68e1d8cbffdf76b23600291))
* ball_protobuf library complete — 89 functions, 113 tests, generated module ([4ff8e84](https://github.com/Ball-Lang/ball/commit/4ff8e8499b2ed22dd0b13ddda939e12c04a1fcf3))
* **ci:** Melos 3-workflow pub.dev publishing (OIDC) + hosted deps ([cfcd30e](https://github.com/Ball-Lang/ball/commit/cfcd30e1b4084fbee55d63609411c27acb9dbd09))
* **cli:** ball build reads ball.lock.json for cached resolution ([cc65665](https://github.com/Ball-Lang/ball/commit/cc656654aa3793f69590d05884ff71f4bbb4c9f5))
* **cli:** wire ball build with PubAdapter + on-the-fly encoding ([57dee1d](https://github.com/Ball-Lang/ball/commit/57dee1da6b9bac458bdd1a9a5f8611c259e79106))
* compile ball_protobuf to C++ — Ball eating its own dogfood ([98e5664](https://github.com/Ball-Lang/ball/commit/98e56646bf29e21e4b94522e4dac45102ab89e82))
* **compiler,encoder:** self-host roundtrip cuts dart-analyze errors 511 → 20 ([8f132fd](https://github.com/Ball-Lang/ball/commit/8f132fdcb4f45142ab490504c606020a589ce8bf))
* **compiler:** conformance compile+encode round-trip harness ([3f2098b](https://github.com/Ball-Lang/ball/commit/3f2098bb965e439a401971dfe1026203c1f57146))
* conformance suite 10→55, C++ runtime header, ball build wiring ([6c79c93](https://github.com/Ball-Lang/ball/commit/6c79c9314ad99aa0aaf40537335f86d4a1e98d24))
* **conformance:** generate 44 orphan fixtures + fix 6 encoder mis-encodings ([dcfa5ed](https://github.com/Ball-Lang/ball/commit/dcfa5ed23c17d24a24344ead597e05159c95433f))
* **conformance:** make orphan fixtures generated + fix multi-engine/compiler bugs they exposed ([d18ba43](https://github.com/Ball-Lang/ball/commit/d18ba43daa24359757efdb17653924d2af9d5692))
* **cpp-compiler:** 5 quick wins for conformance coverage ([8348dea](https://github.com/Ball-Lang/ball/commit/8348dea2168099cf81cb44b7f230d8d3465c82d4))
* **cpp-compiler:** C++ self-host infrastructure — BallDyn + runtime helpers ([5015445](https://github.com/Ball-Lang/ball/commit/5015445ab28c25886014fee14776d8f20ffe8b88))
* **cpp-compiler:** closure conversion — box captured params, value-capture fn params ([79d8f70](https://github.com/Ball-Lang/ball/commit/79d8f700a363b73d3a3dd58c1755a82f5b19d231))
* **cpp-compiler:** closure conversion — box loop-captured locals ([d6a8f33](https://github.com/Ball-Lang/ball/commit/d6a8f3391de0183a72a4579f3a44d1ca73e9db92))
* **cpp-compiler:** dynamic method dispatch + generics erasure ([a3fefeb](https://github.com/Ball-Lang/ball/commit/a3fefeb3d5e47d22e854890e2b044597840246c0))
* **cpp-compiler:** emit real type checks instead of stub true/false ([adb766b](https://github.com/Ball-Lang/ball/commit/adb766b7e72df01e6057fed95d9b0677d48c6d83))
* **cpp-compiler:** implement collections, OOP, generics, and misc features ([cfc8064](https://github.com/Ball-Lang/ball/commit/cfc8064c2bd0583c712086c2a29ee844502eaf91))
* **cpp-compiler:** implement list_foreach + map iteration (forEach) ([48d1ebf](https://github.com/Ball-Lang/ball/commit/48d1ebfaf2067102b85c79df4e6909228cd54e28))
* **cpp-compiler:** implement pattern matching + async/generator support ([5872abd](https://github.com/Ball-Lang/ball/commit/5872abd95057e569528592fac10883f1d9c64fe6))
* **cpp-compiler:** implement std-lib codecs (json/utf8/base64/time) ([df459cf](https://github.com/Ball-Lang/ball/commit/df459cfcaecdaa35f592203ae1cda5a3aa4b9544))
* **cpp-compiler:** map literals are insertion-ordered + reference-typed ([c378e2b](https://github.com/Ball-Lang/ball/commit/c378e2b6fd6b3a381aeab3b9a7628d648d16c695))
* **cpp-compiler:** Phase 3a — all 37 fixtures compile + run; stack-trace binding ([395c575](https://github.com/Ball-Lang/ball/commit/395c5756f3f4bfe2157cfd6de55c1eb1509850e6))
* **cpp-compiler:** Phase 3b — bump to C++20; emit records as std::tuple ([56be7a6](https://github.com/Ball-Lang/ball/commit/56be7a63f1d52eb45f5595bb8dcc40349c41853f))
* **cpp-compiler:** Phase 5 — BallByteData runtime + library compile mode ([29e3d4b](https://github.com/Ball-Lang/ball/commit/29e3d4b79370999c5a6d7662111366668b72d5a1))
* **cpp-compiler:** self-host compiles with ZERO errors ([9d53e4a](https://github.com/Ball-Lang/ball/commit/9d53e4ac5f51d347fd6e6879cdff1398a578a71b))
* **cpp-engine:** 106/134 conformance — OOP support + collection fixes ([6c4d2ae](https://github.com/Ball-Lang/ball/commit/6c4d2ae57fd79ffd280c67f0b3e9fee51f540dd2))
* **cpp-engine:** 106/134 conformance with OOP support ([2ea4070](https://github.com/Ball-Lang/ball/commit/2ea4070c7053769d78d0a99012338f1df7e9cc58))
* **cpp-engine:** 106/134 conformance with OOP support ([e82e425](https://github.com/Ball-Lang/ball/commit/e82e425d2f6b8e2fe412862872a89e2091a8e56e))
* **cpp-engine:** 132/134 conformance — fix 17 test failures ([257ac61](https://github.com/Ball-Lang/ball/commit/257ac6170796e8cfa990251368e6a058bd741288))
* **cpp-engine:** 133/134 conformance — super constructor + input fix ([f84719a](https://github.com/Ball-Lang/ball/commit/f84719a7e94bd50c3654b86b875dbaa83858ffa8))
* **cpp-engine:** 134/134 conformance — ALL TESTS PASS ([aa34f77](https://github.com/Ball-Lang/ball/commit/aa34f7758484aeec4d7f5739809d612e8f5e7f69))
* **cpp-engine:** 80/80 conformance — full collection method dispatch ([b599037](https://github.com/Ball-Lang/ball/commit/b5990374d258a7acab739c4504fb028170d8ae24))
* **cpp-engine:** OOP parity with Dart — constructors, getters/setters, operators, enums ([80a2fa3](https://github.com/Ball-Lang/ball/commit/80a2fa3c8c25d4a1d7fe25265d10effc75172d87))
* **cpp/compiler:** preserve typed-throw class names in BallException ([cf2ca4b](https://github.com/Ball-Lang/ball/commit/cf2ca4b9ab88abe12a310f68759d44c34be74185))
* **cpp/engine:** add list_filled dispatch ([c0cad5e](https://github.com/Ball-Lang/ball/commit/c0cad5efb50e384be906ca1c850dfad4f5c1b891))
* **cpp/engine:** route std_time / std_convert helpers via std module too ([f5b14ce](https://github.com/Ball-Lang/ball/commit/f5b14ce800d81246815d4248be97adfe230b6798))
* **cpp:** 106/106 e2e — collection method dispatch + runtime helpers ([2b43b32](https://github.com/Ball-Lang/ball/commit/2b43b328d755c8eed4ddf50b088f26554dc80774))
* **cpp:** 92/92 e2e + 55/55 conformance — full parity with TS/Dart ([06f5eef](https://github.com/Ball-Lang/ball/commit/06f5eef714d0b519a768277d8597da5274ca22fa))
* **cpp:** 98/134 conformance + 111/111 e2e on expanded suite ([93f8fac](https://github.com/Ball-Lang/ball/commit/93f8facbc03076c2eb4eac3df019b20c21536a91))
* **cpp:** add BallDyn methods for self-hosted engine compatibility ([9c808d8](https://github.com/Ball-Lang/ball/commit/9c808d8f0957e3024b95d52a0bd2ad5a30457807))
* **cpp:** add maxSteps execution guardrail to prevent infinite loops ([878518e](https://github.com/Ball-Lang/ball/commit/878518ec7f1b6ea25bfabdc3bf5b80171c433d82))
* **cpp:** align conformance suite + stack trace binding ([2e2893e](https://github.com/Ball-Lang/ball/commit/2e2893ea9520c29a944ef4b539865bbd737e5a04))
* **cpp:** BallOrderedMap ref semantics for self-host runtime maps ([2267c2f](https://github.com/Ball-Lang/ball/commit/2267c2fe9396e281e8ff0f4e00be946dd5557683))
* **cpp:** C++ self-host 17/17 conformance — ALL PASS ([856380d](https://github.com/Ball-Lang/ball/commit/856380df343df7e82cb24fdcb7d2efb42496f090))
* **cpp:** C++ self-host 5/17 conformance — first programs pass! ([9b95af1](https://github.com/Ball-Lang/ball/commit/9b95af1252df73f453f1de9015e63aab2a520b23))
* **cpp:** C++ self-host 60/135 conformance — scope refs + try/catch ([c587507](https://github.com/Ball-Lang/ball/commit/c5875072d51bbc8a6ac27c621421cbeb15bc7fed))
* **cpp:** C++ self-host compiles — 0 errors in engine_rt.cpp ([183556a](https://github.com/Ball-Lang/ball/commit/183556a6ccf4859532f0f9d708bf57519b3df1e1))
* **cpp:** C++ self-host harness + is-check compiler fix needed ([b1c9f47](https://github.com/Ball-Lang/ball/commit/b1c9f47da66fdf5c03d0bdd338c79e26a13a3da0))
* **cpp:** C++ self-host runtime fixes — string indexing, map creation ([744e511](https://github.com/Ball-Lang/ball/commit/744e51177aea5d3cf1a837001929d52ce26d9ed6))
* **cpp:** expand e2e to 97 programs (add 5 from 76-100 batch) ([ce69586](https://github.com/Ball-Lang/ball/commit/ce695868855b6334cd798aeae7bec454e55701e4))
* **cpp:** split engine_rt into parallel TUs and add Ninja preset ([b7ec388](https://github.com/Ball-Lang/ball/commit/b7ec388c00945ac3537116d6a4fb5a9c5ab44aab))
* **dart-engine:** 100/135 conformance — labeled continue, OOP, collections ([dcf1609](https://github.com/Ball-Lang/ball/commit/dcf16092f0be4737f7e48f2f9bd5238a87f60519))
* **dart-engine:** 121/135 conformance — OOP, collections, type coercion ([eac781c](https://github.com/Ball-Lang/ball/commit/eac781c8fe5b684efd1989c0aca465533db03538))
* **dart-engine:** 135/135 conformance — ALL tests pass ([8f26f38](https://github.com/Ball-Lang/ball/commit/8f26f38171baf8f6ff14b651701593dfd83d3dc7))
* encoder routes collection methods to std_collections module ([4b0a29d](https://github.com/Ball-Lang/ball/commit/4b0a29d403dbcf30f8e9dfeae55a77a832969d4d))
* **encoder:** add part file resolution for self-host encoding ([00cec8f](https://github.com/Ball-Lang/ball/commit/00cec8f1c3e696fbcd7dfcd386d0908372a2bc5e))
* **encoder:** canonicalize Dart operator names in Ball IR ([218f5b0](https://github.com/Ball-Lang/ball/commit/218f5b06dacb91a9494cee84553dd51cb08fe190))
* **encoder:** inline part files + merge extension-on-class into target class ([fd0907b](https://github.com/Ball-Lang/ball/commit/fd0907bd95dea29d548e5bb49e21f61bc6c40e63))
* **encoder:** route protobuf API calls to ball_proto module ([75d2cfe](https://github.com/Ball-Lang/ball/commit/75d2cfe2fddddffce798a12907acd854ef1a75df))
* **engine,test:** add 203_closure_in_loop fixture + typed_list dispatch ([54f99d1](https://github.com/Ball-Lang/ball/commit/54f99d19022b7ec210981ce94e8caf46d12c2938))
* **engine:** implement full pattern semantics in switch expressions ([8d89f8c](https://github.com/Ball-Lang/ball/commit/8d89f8c07360164db930862a76e90219b0087e36))
* **engine:** Wave 7 security hardening + sandbox mode ([e2a15df](https://github.com/Ball-Lang/ball/commit/e2a15df68ed616a8632d5cd2ea8a1e6f9a57d6f5))
* expand conformance to 80 programs + encoder coverage + CI gate ([1ccbc76](https://github.com/Ball-Lang/ball/commit/1ccbc76c4b8a07a0873361ff024dc954c1701275))
* mock registry tests + registry_url passthrough + C++ e2e expansion ([429244a](https://github.com/Ball-Lang/ball/commit/429244a9ea51f89020b31db8cafe3fa3966dddc6))
* Phase A — ball_protobuf wire primitives (15 functions) ([db5f918](https://github.com/Ball-Lang/ball/commit/db5f918308857986e684e9c2359bd2b4cca5b0e4))
* Phase B — ball_protobuf field encoding (26 functions) ([13d72b5](https://github.com/Ball-Lang/ball/commit/13d72b52eff3bef8efa8257dbee99fab6a4909f5))
* Phase C — ball_protobuf message marshal/unmarshal (12 functions) ([52ad674](https://github.com/Ball-Lang/ball/commit/52ad674b09df23f24c04cb40469428b1dd74e84f))
* Phases D+E+F — Proto3 JSON, well-known types, edition support ([e6335b1](https://github.com/Ball-Lang/ball/commit/e6335b156202e09b66089cb5af8bbc84c90fc19b))
* Phases G+H — gRPC framing + conformance suite plugin ([a0bf6b0](https://github.com/Ball-Lang/ball/commit/a0bf6b04fe7e14b65de39a53dcbf3b6c8ffe2fce))
* **playground:** static web playground for Ball programs ([b5f5f66](https://github.com/Ball-Lang/ball/commit/b5f5f6653a46da3357b6d8b8cc7e0d89cf1afa6f))
* **proto:** add Pattern message with 12 universal pattern kinds ([5c88627](https://github.com/Ball-Lang/ball/commit/5c88627a10418c658b0565d5793666a3f2ef1aca))
* **proto:** add TypeRef message and FunctionCall.type_args ([90c44f3](https://github.com/Ball-Lang/ball/commit/90c44f3852bc73adcfea42593a501dbdd39a8f37))
* **protobuf-gen:** cross-file refs, per-call Any resolver, extensions (Phase 3) ([9a842e1](https://github.com/Ball-Lang/ball/commit/9a842e18f7e2c0d507a5212aa777f9d7fe8a22ec))
* **protobuf-gen:** foundation — ball_protobuf_gen pkg, plugin, Dart message codegen ([fdd9ee5](https://github.com/Ball-Lang/ball/commit/fdd9ee50bfe19acd98f89a150ed3a4dc4ea973a1))
* **protobuf-gen:** Phase 4 — gRPC + Connect services (ball_rpc + 2 plugins) ([a6bff27](https://github.com/Ball-Lang/ball/commit/a6bff27909cf9081ece3dc8b8050366a463736ae))
* **protobuf:** broaden upstream conformance to proto2/proto3 + fix codec bugs ([b96a9dc](https://github.com/Ball-Lang/ball/commit/b96a9dc78625e40bca4de37a8ba2a71f8efe1fe0))
* **protobuf:** complete Editions Phases 0/2/3 — resolution, legacy, binary ([92124f6](https://github.com/Ball-Lang/ball/commit/92124f62c3d8077d2f87eb226975e93b86239bea))
* **protobuf:** descriptor bridge + registry-driven conformance program (upstream Editions) ([acac65e](https://github.com/Ball-Lang/ball/commit/acac65eb6ee7ce19298b3e9f351fa08774683eb4))
* **protobuf:** editions feature-resolution core (Phase 0-2) — protoc-grounded ([5327780](https://github.com/Ball-Lang/ball/commit/53277801b77a4ba601a4ba979591658268b5b93f))
* **protobuf:** Editions Phase 4 — thread features through JSON codec + UTF-8 ([68c7231](https://github.com/Ball-Lang/ball/commit/68c7231d16e511784c02efb322803c41d3025c0e))
* **protobuf:** Editions Phase 5 conformance harness + Phase 3 review fixes ([b3ea6d6](https://github.com/Ball-Lang/ball/commit/b3ea6d6d089529d7c2f635537db0510c75b64f19))
* **protobuf:** Editions Phase 6a — repackage ball_protobuf as facade Module ([7aa46c6](https://github.com/Ball-Lang/ball/commit/7aa46c619bab594ea4c34ef53b2a56b24c2b0c44))
* **protobuf:** full upstream conformance — implement all remaining features ([4015fb0](https://github.com/Ball-Lang/ball/commit/4015fb0517b011b3b27537052d236ae6319b63e0))
* **protobuf:** thread resolved features through binary marshal (Phase 3) ([2a36e63](https://github.com/Ball-Lang/ball/commit/2a36e632253322dcef626aeff55a7b405f5a0da5))
* replace hand-written TS engine with compiled (self-hosted) engine ([98c4304](https://github.com/Ball-Lang/ball/commit/98c4304658c484d0666423e9fe2442905137f671))
* round-trip tests + package management integration test ([93b4329](https://github.com/Ball-Lang/ball/commit/93b432957d18ff46e1d38c731788808fcfcd0a01))
* **self-host:** 135/135 TS conformance — full self-hosting achieved ([f41ea4b](https://github.com/Ball-Lang/ball/commit/f41ea4b84642fbce730835c55e6a7c062fbf9148))
* **self-host:** 177/177 TS conformance — all tests pass ([0564033](https://github.com/Ball-Lang/ball/commit/05640330bd9586a4324ecc4a132d0e83c896fb7a))
* **self-host:** Dart roundtrip parity 26 → 156 pass (90.7%) ([81f4322](https://github.com/Ball-Lang/ball/commit/81f43229405c4a8ce1c2b5720b8b3f962bc273a7))
* **self-host:** more TS portability foundations ([e165f8b](https://github.com/Ball-Lang/ball/commit/e165f8bdb68ad7fe2e1e023393bc92db76923d75))
* **self-host:** permissive _stdPrint key probing + TS roadmap ([62abf10](https://github.com/Ball-Lang/ball/commit/62abf1092beccd5518dbfe58523cbb419a91357a))
* **self-host:** Phase 1 — round-trip engine.dart Dart → Ball → Dart ([75afc77](https://github.com/Ball-Lang/ball/commit/75afc772dfcc444acb65300349512074ca460245))
* **self-host:** Phase 1 complete — parity test passes 10/10 conformance ([002ac2f](https://github.com/Ball-Lang/ball/commit/002ac2f67d8e6e7f59480f42e99bf080545107e4))
* **self-host:** Phase 3 status-check — engine.dart emits to C++ via existing cpp compiler ([4b257c9](https://github.com/Ball-Lang/ball/commit/4b257c98337be8931285280d3f9387f252993f8e))
* static termination analysis — infinite loops, recursion, dead code ([4b94e11](https://github.com/Ball-Lang/ball/commit/4b94e11917efed2517d1214ac907a5a02d222086))
* **ts-compiler:** 104/135 compiled engine — OOP + string fixes ([e5a49cd](https://github.com/Ball-Lang/ball/commit/e5a49cde27f949d6c86397db205d9e43a90c0984))
* **ts-compiler:** 113/135 compiled engine — switch, double, collections ([7616f2e](https://github.com/Ball-Lang/ball/commit/7616f2ed108eb03fd402b2a578990e173bed29b0))
* **ts-compiler:** 124/135 compiled engine — labeled loops, typed catch, OOP ([d41c41d](https://github.com/Ball-Lang/ball/commit/d41c41d9fcd4a0774f19b7634c391de8256f9c79))
* **ts-compiler:** 135/135 compiled engine — ALL CONFORMANCE PASS ([7389bbf](https://github.com/Ball-Lang/ball/commit/7389bbfad4eb0cab1481b7d09c6ab9c04f4a0ab0))
* **ts-compiler:** 65/80 compiled engine conformance ([98d5315](https://github.com/Ball-Lang/ball/commit/98d53157078fc532cb44f504469ea9c0c9475833))
* **ts-compiler:** 93/135 compiled engine conformance ([e44bfe4](https://github.com/Ball-Lang/ball/commit/e44bfe44865014e6e4efbf32cf5d76fb178524de))
* **ts-compiler:** 95/135 compiled engine — BallDouble + type fixes ([31069e6](https://github.com/Ball-Lang/ball/commit/31069e66c3cb15e1643a9af694e670f6d1024dda))
* **ts-compiler:** Phase 2.0 — structural emitter via ts-morph Node helper ([8969b37](https://github.com/Ball-Lang/ball/commit/8969b3762fa655aa2508d622b711b63c1648d918))
* **ts-compiler:** Phase 2.1 — buildEmitPlan + compileStructural path ([fc77e4e](https://github.com/Ball-Lang/ball/commit/fc77e4ed0a6b573fc95d6d7ef5e1d506f8fef05f))
* **ts-compiler:** Phase 2.2 — class emission with this.field, method calls, new ([140fd3c](https://github.com/Ball-Lang/ball/commit/140fd3ce106dc5238e0d4042d8344f38141019ea))
* **ts-compiler:** Phase 2.3 — native async/await + TS-side await/yield/yield* cases ([e806dd0](https://github.com/Ball-Lang/ball/commit/e806dd0fea1502423d122656c68ce08b043be53c))
* **ts-compiler:** Phase 2.4 — typedefs, typed collection literals, Array/Map polyfills ([2fbb15d](https://github.com/Ball-Lang/ball/commit/2fbb15d8fb2bd642c5cf2ad3131dc8db33898103))
* **ts-compiler:** Phase 2.4 partial — generics, this literal, null-aware calls ([2fca4d7](https://github.com/Ball-Lang/ball/commit/2fca4d749e8686b9033983e706020e93caa51b7e))
* **ts-compiler:** Phase 2.6 milestone — engine.dart parses as valid TS ([65a2c8d](https://github.com/Ball-Lang/ball/commit/65a2c8d128f85a90605b677ab583a062518ab611))
* **ts-compiler:** Phase 2.7a — inheritance + exceptions round-trip end-to-end ([e983980](https://github.com/Ball-Lang/ball/commit/e983980e5a3dca3e73a2bb11ca3bef22d8e12bc7))
* **ts-compiler:** Phase 2.7b — 3 conformance programs pass through compiled engine! ([e56a991](https://github.com/Ball-Lang/ball/commit/e56a9912a8a6737d65e9ff9bb89849cb94967620))
* **ts-compiler:** Phase 2.7b — Dart runtime API polyfills + builtin ctors ([3370525](https://github.com/Ball-Lang/ball/commit/337052506a50d8c679ac93dad909bb7cb6d4d24a))
* **ts-compiler:** Phase 2.7b — field_2 → field proto alias; 8/10 conformance pass ([848c5cf](https://github.com/Ball-Lang/ball/commit/848c5cf4fb876ec1f4dc50a3f9da745e7f5806fb))
* **ts-compiler:** Phase 2.7b — is/is_not generic stripping, field_2 alias; 9/10 conformance pass ([6bac65d](https://github.com/Ball-Lang/ball/commit/6bac65d0b8a8906d4a7d88c4031639a7f893a733))
* **ts-compiler:** Phase 2.7b — map_create entries, field init from raw Dart types, Map.entries getter ([67e3cf1](https://github.com/Ball-Lang/ball/commit/67e3cf11eb0918d119f9b69f3560ccd7085bfda2))
* **ts-compiler:** Phase 2.7b — named-param destructuring in constructors; 5/10 conformance pass ([916a880](https://github.com/Ball-Lang/ball/commit/916a88028c53908263d9b3979301087816f06e36))
* **ts-compiler:** Phase 2.7b — null equality, switch-as-return, method binding, Object polyfills ([fe45782](https://github.com/Ball-Lang/ball/commit/fe4578231b4300294cb5c72d52390727469a9c38))
* **ts-compiler:** Phase 2.7b — switch-as-if/else, Set.contains, nullable defaults, isControlFlow empty module ([63a0e90](https://github.com/Ball-Lang/ball/commit/63a0e9051ab268e8aaac21feb7fd5a3156fac408))
* **ts-compiler:** Phase 2.7b — top-level vars, object polyfills, StdModuleHandler wiring ([fcacaec](https://github.com/Ball-Lang/ball/commit/fcacaec7ea897f1928c7a8ec0a9ee2eb2b715e94))
* **ts-compiler:** Phase 2.7b COMPLETE — 10/10 conformance pass through compiled engine! ([a919e86](https://github.com/Ball-Lang/ball/commit/a919e8607c0200ece2bcf9e407f9918bcc223819))
* **ts-compiler:** Phase 2.7b progress — protobuf + Struct shims for compiled engine ([c5acbeb](https://github.com/Ball-Lang/ball/commit/c5acbeb312730c51bb2e0378d5e671731ca7c3c8))
* **ts-compiler:** Phase 2.8 — structural compile passes 37/37 fixtures end-to-end ([24ac3e7](https://github.com/Ball-Lang/ball/commit/24ac3e7f629aaa0f41000f280694c8b9647d6357))
* **ts-compiler:** Phase 2.9a — @ball-lang/compiler package scaffold ([c28dec2](https://github.com/Ball-Lang/ball/commit/c28dec20bb4a3c9185a425394dac88eb22d25051))
* **ts-compiler:** Phase 2.9b-d — full feature parity with Dart-side compiler ([43fe67a](https://github.com/Ball-Lang/ball/commit/43fe67a0c4cdb1ae8a01755818e0707ea2e42aa0))
* **ts-compiler:** Phase 2.9e — delete ts_compiler.dart implementation; Dart wraps @ball-lang/compiler ([1c3a698](https://github.com/Ball-Lang/ball/commit/1c3a6981258d164df42cb14bbc045bd7bdf7dcb7))
* **ts-compiler:** Phase 2.9e — delete ts_compiler.dart implementation; Dart wraps @ball-lang/compiler ([8a66c3e](https://github.com/Ball-Lang/ball/commit/8a66c3e71ebe7b42c16914ecece13e0a3c891d0a))
* **ts-compiler:** Phase 5 — in-place list mutation + typed_data shims + library mode ([0dbf80b](https://github.com/Ball-Lang/ball/commit/0dbf80b634f4170610869a8c85c206f876adbfcb))
* **ts-compiler:** records — positional tuples, named maps, pattern destructuring ([b63067b](https://github.com/Ball-Lang/ball/commit/b63067b9d5361aeca2a912bd6d82c4ca1b442a1c))
* **ts-compiler:** switch expressions — integer / or-pattern / when-guard / wildcard ([5d5afd3](https://github.com/Ball-Lang/ball/commit/5d5afd30101aab95e3a53e0cba30682707821c0a))
* **ts-engine:** 125/140 conformance — full OOP support ([8fdb6c6](https://github.com/Ball-Lang/ball/commit/8fdb6c664f03ed9155eac7814ccc2b9086768315))
* **ts-engine:** 140/140 conformance — all tests pass ([9dfc2ed](https://github.com/Ball-Lang/ball/commit/9dfc2ed6bbf01ba9d831c51abef115d13ac53080))
* **ts-engine:** 85/85 conformance — full collection method dispatch ([9370710](https://github.com/Ball-Lang/ball/commit/93707102152cb86bc43be6843331a2e5663bfd14))
* **ts-engine:** add encoder-generated conformance tests (37 tests) ([e921135](https://github.com/Ball-Lang/ball/commit/e921135228d8afece3d88245978d3b0848a477e3))
* **ts-shared:** add @ball-lang/shared package with protobuf-es bindings ([1056024](https://github.com/Ball-Lang/ball/commit/10560242668753d532855fff905e17589c1f1ca9))
* **ts/self-host:** start dropping the engine wrapper, lay polyfills ([b4287e7](https://github.com/Ball-Lang/ball/commit/b4287e77311e138b073e34e09d15ff1ceecb6d89))
* **ts/wrapper:** list_filled and list_generate accept Dart field names ([2967b54](https://github.com/Ball-Lang/ball/commit/2967b5449fdc43e951bcf757ae09a1e2da0b0519))
* **ts:** 55/55 compiled engine conformance + 60/60 hand-written engine ([7cbdc82](https://github.com/Ball-Lang/ball/commit/7cbdc826516760f3de2b16942b9f0bbd501124c7))
* **ts:** add @ball-lang/encoder — TypeScript → Ball IR ([08f6a84](https://github.com/Ball-Lang/ball/commit/08f6a84eb1ef22decba3dfac8f57153dfa668041))
* **ts:** cross 90% conformance — 198/216 (91.7%) ([a970c5f](https://github.com/Ball-Lang/ball/commit/a970c5f23e55e8db5c6e0bb5108e35dbc81f60de))
* **ts:** regenerate compiled_engine from current IR (zero-wrapper milestone) ([e813f3d](https://github.com/Ball-Lang/ball/commit/e813f3d9f20e8dfedf752864728aeef63925c1bf))
* Workstream A+C — `ball resolve` works + 103/103 pub packages round-trip ([9872b42](https://github.com/Ball-Lang/ball/commit/9872b42c014635f9c043db3a03d8942cb8e5bbac))


### Performance Improvements

* **ci:** cache the C++/protobuf build (ccache + Ninja) + Dart pub + npm ([39206fc](https://github.com/Ball-Lang/ball/commit/39206fc35442c92b8b920d8ac2496a62a4954057))
* **cpp:** borrow Program by const ref instead of deep-copying it ([74057db](https://github.com/Ball-Lang/ball/commit/74057db9fe8d2e8e938ac5431b466a9f037dd988))
* **cpp:** compile out engine debug-trace blocks in release ([0026b74](https://github.com/Ball-Lang/ball/commit/0026b74cb223dfe397b413e5f959ebe3b086d06f))
* **cpp:** single-walk Scope::set and reference lookup in native engine ([2c205c8](https://github.com/Ball-Lang/ball/commit/2c205c85052c873583ca0f8223a88d0dbc7f10ac))
* **dart:** wave 3 dispatch caches and protobuf program-size check ([8ed124d](https://github.com/Ball-Lang/ball/commit/8ed124db2ee0d4af338edd25647e15899c758d28))
* **ts:** skip Object.prototype probe in whichXxx engine discriminators ([88b5a87](https://github.com/Ball-Lang/ball/commit/88b5a870be1397c95c02a55ab6a108d2858cf7a1))


### Reverts

* **cpp:** restore for/while expression-context stub — 778a93d broke the build ([7dbac0a](https://github.com/Ball-Lang/ball/commit/7dbac0a0ca22253691ddc2ab99d3baad009e4534))
* remove Pattern messages + Reference.is_cascade_target ([1a9e8d2](https://github.com/Ball-Lang/ball/commit/1a9e8d2710fec0cf250ac59014077e3b321772a2))
* **ts:** roll back the drop-the-wrapper push to restore 194/220 ([2c67f94](https://github.com/Ball-Lang/ball/commit/2c67f941dd547d58d0239e51396dea11892ef1ba))


### BREAKING CHANGES

* dart_std and cpp_std modules no longer exist.
All base functions route through universal std module.

## dart_std elimination
- Encoder: removed _dartStdFunctions, _buildDartStdModule, module routing
- All 12 dart_std functions now in std (cascade, null_aware_access, etc.)
- Syntax expansions: null_aware_access/call → Block+std.if+std.equals
- Cascade → Block+LetBinding(__cascade_self__)+sections
- Clean break: zero dart_std references in engine, compiler, TS, generated code

## cpp_std elimination
- C++ encoder: inlined 10 normalizer safe projections directly
- Deleted normalizer.cpp/h, cpp_std.cpp/h
- Removed all engine/compiler cpp_std dispatch

## __type_args__ migration
- Engine reads MessageCreation.metadata.type_args (structured TypeRef)
- Encoder no longer produces legacy __type_args__ field
- Compiler reads metadata first with _metadataTypeArgToStr helper
- _typeRefValueToString preserves nested generics (List<int> not just List)

## TS conformance: 3 → 0 failures
- Added __ball_is_type runtime helper for generic type checking (List<T>, Map<K,V>)
- Added __ball_with_type_args for reified generics on compiled class instances
- Fixed nullable emitIsCheck (int? now correctly matches null)
- Fixed emitIsCheck to use constructor.name for TS-compiled class instances
- Added MessageCreation.metadata to TS compiler types

## ts_std elimination
- TS encoder: all ts_std calls → std (same pattern as dart_std)
- 107/107 encoder tests pass

## Code quality (from review)
- Extracted _buildNullGuard common pattern (no duplication)
- Fresh protobuf objects per use (_refExpr/_nullExpr, no aliasing)
- Optimized null_aware for Reference targets (skip Block+LetBinding)
- Extracted _extractMetadataTypeArgs DRY helper in engine
- Reset _tempVarCounter in encode()
- Fixed ensureMetadata() for const constructors

## Documentation
- Updated 20+ files: CLAUDE.md, README.md, AGENTS.md, rules, skills, docs
- Updated METADATA_SPEC.md with MessageCreation.metadata + naming conventions
- Updated DUNDER_AUDIT.md status
- Updated ELIMINATE_LANG_STD_PLAN.md status

## Conformance results
- engine: 228/228, dart-compiled: 228/228, ts-compiled: 228/228, dart-roundtrip: 228/228
- Baseline: 3 → 0 failures
- TS engine: 270/270, Dart engine: 663/663, TS compiler: 270/270

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
* pre-1.0 schema + on-disk format changes.

Schema / type system
- Remove the legacy `Module.types` (bare DescriptorProto) field and the
  `_meta_<Name>` function hack. `typeDefs[]` (TypeDefinition = descriptor +
  metadata) is now the single type-declaration path. Migrated all std builders
  (Dart + C++), encoder, readers; regenerated bindings + all fixtures.

Self-describing ball files (google.protobuf.Any envelope)
- Every `.ball.json`/`.ball.bin` is now a serialized google.protobuf.Any
  ({"@type":".../ball.v1.Program"|Module}), so readers never guess Program vs
  Module. Implemented via runtime WKT Any (no proto import; schema stays clean):
  ball_file.dart / ball_file.ts / ball_file.h helpers; all loaders/writers
  routed through them; all fixtures, examples, std.json, ball_proto,
  ball_protobuf, engine.ball.json/.pb wrapped.

Fixes
- ts/compiler: static-method calls emitted as `this.<static>()` (invalid JS);
  LinkedHashMap/HashMap/SplayTreeMap not recognized as map constructions;
  `is Map` wrongly matching BallDouble. compiled_engine.ts regenerated.
- engine: field access threw "field not found" for present-but-null fields
  (engine_eval.dart); now returns the value. Fixes comprehensive/wordcount.
- C++: RangeError BallException on out-of-range list index.

Cleanup
- Untrack committed C++ build artifacts (cpp/build2, cpp/build3; ~4.3k files),
  free 781MB stale agent worktrees, delete .sisyphus/, stale status docs,
  scratch logs, one-off tools.

Examples
- Re-encoded from Dart sources for accuracy; comprehensive's 5 residual _meta_
  retired into proper typeDefs.

Versioning
- Unify all Dart + TS packages to 0.3.0.

.claude config
- New `new-ball-language` skill + `ball-lang-bootstrapper` agent + new-language
  & ts rules; fixed agent frontmatter (kebab names, comma-separated tools);
  deduped CLAUDE.md/AGENTS.md; corrected protobuf-bootstrapping strategy and
  reference tables.

Verified: Dart engine +268, self_host +225, compiler +88, encoder +116,
shared +411, analyze 0 errors; TS engine 269/0, compiler 269/0; C++ self-host
conformance 211/227 (10 architectural failures unchanged).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
