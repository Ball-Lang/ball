<!-- Parent: ../AGENTS.md -->

# cpp/shared

## Purpose
The `ball_shared` CMake library — common types, runtime helpers, and generated protobuf bindings used by every C++ Ball tool (compiler, encoder, test harness, self-hosted engine).

## Key Files
| File | Description |
|------|-------------|
| `include/ball_shared.h` | Umbrella header: `BallValue`/`BallList`/`BallMap`/`BallFunction` type aliases, std module builders, pulls in `ball_emit_runtime.h` and generated protos |
| `include/ball_emit_runtime.h` | Runtime helpers (exception type, `ball_to_string`, `std_time` helpers) embedded verbatim into every compiler-emitted program — single source of truth for both interpreter and emitted code |
| `include/ball_file.h` | Header-only `ball::LoadProgram` / `LoadModule` / `DecodeProgram`; reads `.ball.json` / `.ball.bin` / `.ball.pb` `google.protobuf.Any` envelopes |
| `include/ball_ir.h` | Protobuf-free IR (`ball::ir` namespace) loaded via nlohmann/json; supports both camelCase and snake_case field names on read, and serializes back to proto3-JSON (camelCase, canonical) via `toJson`/`programToJsonString` |
| `include/ball_dyn.h` | Dynamic value helpers used by the self-hosted engine harness |
| `include/ball_ordered_map.h` / `ball_ordered_map_impl.h` | Ordered-map interface and implementation |
| `src/ball_shared.cpp` | `ball_shared` implementation (std module builders) |
| `ball_protobuf_rt.h` | **Generated — regenerate, don't hand-edit.** Ball's own `ball_protobuf` runtime, compiled Ball→C++ in `--library` mode (header-only, self-contained: only `<std>` headers, NO libprotobuf/abseil/nlohmann). Regenerate via `dart/compiler/tool/compile_ball_protobuf_cpp.dart`, or directly: `ball_cpp_compile dart/shared/ball_protobuf.json --library --ns ball_protobuf --out cpp/shared/ball_protobuf_rt.h`. |
| `ball_protobuf_rt_smoke.cpp` | Hand-written smoke driver: `#include`s `ball_protobuf_rt.h` and round-trips real values through `encodeVarint`/`decodeVarint`, `encodeZigZag64`/`decodeZigZag`, `encodeFixed32`/`decodeFixed32`, AND a full descriptor-driven `marshal`→`unmarshal` round-trip on a nested message (int32 + string + sub-message). Built only behind `-DBALL_BUILD_PROTOBUF_RT=ON` (the #18 canary — see below). |
| `gen/ball/v1/ball.pb.h` | **Generated — NEVER edit.** Regenerate via `buf generate`. |
| `gen/ball/v1/ball.pb.cc` | **Generated — NEVER edit.** |

## For AI Agents
- `BallMap` is `std::map<std::string, BallValue>` (ORDERED). **Never** substitute `std::unordered_map` — field insertion order is observable.
- `ball_emit_runtime.h` is slurped at CMake configure time into a `_embed.h` constant that the compiler splices into emitted programs. Edit it in-place; do not copy or inline its content elsewhere.
- Use `ball::LoadProgram(path)` / `LoadModule(path)` from `ball_file.h` — never parse a `.ball.json` directly into a `Program` proto; the `@type` envelope must be stripped first (the loader does this).
- `ball_ir.h` exists to avoid a libprotobuf dependency in lightweight tools. The self-hosted engine uses `BallDyn` (from `ball_dyn.h`), not `ball::ir`.
- `gen/` is checked in as a fallback when buf CLI is not on PATH. Regenerate with `buf generate --template cpp/buf.gen.cpp.yaml -o cpp/shared/gen proto/` from repo root.
- Reference `.claude/rules/cpp.md` for full type system details and `CLAUDE.md` for buf regeneration workflow.

## #18/#25 — dropping Google protobuf (status)
Goal: replace the FetchContent Google protobuf (v34.1, ~90% of C++ build time,
abseil-mutex deadlock #25) with Ball's own runtime + nlohmann/json for Ball-IR
loading.

**Landed:**
- `include/ball_ir.h` — protobuf-free IR + proto3-JSON loader (nlohmann only).
  `test_ball_ir` (CTest `ball_ir_loader`) parses the WHOLE conformance corpus
  through it with zero libprotobuf. This is the real replacement for JSON IR
  loading.
  - **Write direction (Phase 2a, #18):** `toJson`/`programToJsonString` mirror
    every `parseX` — the serializer the encoder migration will need (ball_ir.h
    was previously parse-only). Proven via a struct→JSON→re-parse round-trip
    against the whole conformance corpus (informational tally in
    `test_ball_ir`'s output, not gating `ball_ir_loader`'s pass/fail — see the
    "not byte-perfect" note below): 315/321 fixtures match exactly. The 6 that
    don't are a genuine representational limit, not a bug: `ball::ir`'s plain
    (non-`std::optional`) struct fields can't distinguish "the source omitted
    this field" from "the source wrote it at its own zero value" once parsed,
    and the real corpus is occasionally inconsistent about which shape the
    SAME field uses across otherwise-identical call sites (e.g. some
    `MessageCreation.typeName` are explicit `""`, others of the identical
    shape omit the key). Closing the gap fully needs presence-tracking added
    to `ball::ir`'s types — left for a future pass; two narrow, documented
    normalizations (`normalizeMessageCreationTypeName`,
    `normalizeEmptyModulePlaceholders` in `test_ball_ir.cpp`) already close
    the majority of these without touching the serializer's otherwise-correct
    default-omission behavior.
  - **`@type` envelope handling fixed:** `parseProgram`'s Any-envelope
    handling used to be a dead no-op (`root = &j` in both branches of an
    `if`). It turned out to be harmless-by-accident (a non-well-known
    message's Any JSON form merges fields alongside `@type` at the same
    level, so nothing needs unwrapping — verified: all 321 corpus fixtures
    use exactly this shape), but now also validates the envelope names
    `ball.v1.Program` and fails loud on a mismatch (e.g. a Module file handed
    to the wrong loader) instead of silently parsing a garbage/empty Program.
  - **`Module.typeAliases` was silently unparsed:** `parseModule` never read
    the `typeAliases`/`type_aliases` field at all (no `parseTypeAlias`
    existed). Fixed; one corpus fixture (`85_closure_counter.ball.json`)
    actually uses it.
- `ball_protobuf_rt.h` (+ `ball_protobuf_rt_smoke.cpp`) builds behind
  `-DBALL_BUILD_PROTOBUF_RT=ON` as the standalone, dependency-free proof target
  `ball_protobuf_rt_smoke` (CTest `protobuf_rt_smoke`). CI enables the flag on
  Linux so the Ball-compiled runtime is guarded against silent rot. The smoke
  driver actually **calls** the compiled codecs (varint/zigzag/fixed32
  round-trips), not just compiles them, and links nothing else — proving the
  runtime stands alone AND works.
  - Note: the file checked in before this fix was generated (June 2026, commit
    `98e5664`) predates the C++ compiler's `--library` mode (added a few days
    later in `29e3d4b`), so it silently fell back to a Program-wrapping path
    that dead-code-eliminated all 213 `ball_protobuf` functions down to an
    empty `main()` — the "canary" compiled but proved nothing. Regenerating
    with the now-available `--library` mode produces the real ~9k-line header
    with all functions present; verified via a manual varint round-trip
    (`encodeVarint(buf, 300)` → `decodeVarint` → `{value: 300, bytesRead: 2}`)
    before wiring it into the smoke target.

**Wire-codec portability fix (source) — regenerated and verified:**
- `dart/ball_protobuf/lib/` used `buffer.addAll(data)` to append multi-byte
  payloads (`wire_bytes.dart` `encodeBytes`, `marshal.dart` `encodeGroupField` /
  `_writeScalarForced`, `field_fixed.dart` float/double). `addAll` encodes to the
  NON-mutating `list_concat`, which returns a NEW list; callers that thread a
  buffer through and rely on in-place mutation (`marshal` discards the return of
  `encodeBytes`/`encodeTag`) silently DROP the appended bytes on the C++/TS
  targets — so every string/bytes/packed/nested-message field mis-encoded (the
  length prefix is written by the per-byte `encodeVarint`, but the payload is
  lost). Native Dart tests never caught it (Dart's real `addAll` is in-place);
  see `.claude/rules/dart.md`'s `addAll` trap. **Fixed at source** by appending
  per-item (`for (final b in data) buffer.add(b);` → in-place `list_push`)
  in PR #331; `ball_protobuf.json` regenerated (freshness-gated).
- **`cpp/shared/ball_protobuf_rt.h` has been regenerated** from that fixed
  source (WSL g++ 14.2 build at the realigned FetchContent v34.1 — the #333
  gencode/runtime skew is resolved on main, so local WSL builds work again).
  The regenerated header marshals the canary message BYTE-PERFECTLY
  (`08 2A 12 02 68 69 1A 02 08 07` for `{a: 42, s: 'hi', sub: {b: 7}}`).
- **PR #331's two "rt defects" were both C++ COMPILER bugs — root-caused and
  fixed** (regenerating alone did NOT clear them; both fixes live in
  `cpp/compiler/src/compiler.cpp` and the header is regenerated with them):
  1. **Named→positional argument mis-slotting** (`marshalField` throw):
     `compile_call` emitted a user call's `messageCreation` fields in
     APPEARANCE order. A call that skips a middle optional named parameter
     (`marshalField(..., explicitPresence:, delimited:, messageDescriptor:)`
     omits `repeated:`) shifted every later argument one slot left, so
     `messageDescriptor` landed in `delimited` and the real one defaulted to
     null → singular `TYPE_MESSAGE` marshal threw. Fixed by
     `compile_call_arguments`: maps `argN`/named fields onto the callee's
     declared parameter order (sanitized-name function index +
     `metadata.params`), filling skipped optional slots with the same
     `cpp_param_default` the emitted signature declares; falls back to
     appearance order whenever the callee/params are unknown. Provably inert
     for the conformance corpus and the self-host engine (neither contains any
     `is_named` param — verified by grep before landing).
  2. **"`unmarshal` mis-tracks offset" was really a switch-statement
     miscompilation** (NOT header staleness as #331 hypothesized): a
     bare-expression case body (e.g. `case 'int32': value =
     decodeAsInt32(rawVarint);`) in a STATEMENT-position switch inside a
     non-void function was emitted as `return ball_assign(...)` — silently
     exiting the function with the assigned scalar instead of falling through
     to the `return {'value': …, 'bytesRead': …}` map, so the caller read
     `bytesRead` as 0 and re-read the tag byte as a LEN length ("declared
     length 18 at offset 2"). Fixed in the statement-form switch's
     `emit_case_body`: a bare-expression case body's value is DISCARDED
     (statement semantics, matching the Dart engine); only the explicit
     `/* return */` marker (Dart `return X;`) exits. The void-function branch
     had already been fixed this way (self-host engine #19) — the non-void
     branch kept the old wrap. No committed snapshot contains a
     statement-form switch, so snapshot goldens are unaffected.
  Both defects are now guarded by the descriptor-driven
  `marshal`→`unmarshal` round-trip in `ball_protobuf_rt_smoke.cpp` (CTest
  `protobuf_rt_smoke`, CI-enabled on Linux).

**Stage 3 — binary-path cutover (LANDED, behind a default-OFF option):**
`.ball.pb`/`.ball.bin` loading can now route through Ball's OWN compiled
protobuf runtime instead of google's `Any`/`Program` parser, gated by the
default-OFF CMake option `BALL_USE_BALL_PROTOBUF` (`cmake -S cpp -B build
-DBALL_USE_BALL_PROTOBUF=ON`). The default build is byte-for-byte unchanged —
google stays the sole binary decoder unless you opt in.
- **Runtime descriptor** (`cpp/shared/ball_program_descriptor.h`, GENERATED):
  `dart/ball_protobuf/tool/gen_program_descriptor_cpp.dart` runs the existing
  `descriptor_bridge.dart` `buildRegistry` over ball.proto's `FileDescriptorSet`
  (via `buf build`), prunes to the reachable `ball.v1.*` messages, and emits a
  `BallDyn` descriptor the `ball_protobuf_rt.h` codecs consume. Two design keys:
  (1) **opaque passthrough** — every `google.protobuf.*` field (the `Struct
  metadata` bags, `TypeDefinition.descriptor`/`Module.enums`
  `DescriptorProto`/`EnumDescriptorProto`) is emitted as a `TYPE_BYTES` field; a
  message and a bytes field are byte-identical on the wire, so the payload
  round-trips VERBATIM and no descriptor.proto/struct.proto closure (nor its
  proto2 presence / closed-enum / WKT-JSON fidelity) is needed; (2) **recursion
  via shared lists** — `ball.v1.Expression` is deeply self-recursive, expressed
  by the `shared_ptr`-backed `BallList` (`BallListRef`): copying a message's
  descriptor `BallDyn` into a field's `messageDescriptor` shares the SAME
  underlying vector, so a two-phase build (empty list per FQN, then fill) mirrors
  the Dart registry's shared-reference cycles. Regenerate with
  `dart run dart/ball_protobuf/tool/gen_program_descriptor_cpp.dart`.
- **`google.protobuf.Any` envelope decode + payload round-trip**
  (`ball_rt_decode.cpp`): `ball::rt::DecodeAnyPayload` unmarshals the Any
  (`type_url` #1 / `value` #2) AND its Program/Module payload with the runtime
  descriptors, then RE-MARSHALS to bare wire bytes. All `ball_protobuf`
  global-`BallDyn` usage is confined to this ONE TU; the public seam
  (`ball_rt_decode.h`) is pure `std::string`, so `ball_file.h`'s google
  `ball::v1::` types and ball_protobuf's `BallDyn` never meet in one TU (they
  each define a `BallDyn`). `ball_file.h::DecodeBallFileBinary` gains a
  `#ifdef BALL_USE_BALL_PROTOBUF` branch that calls it, then hands the
  re-marshaled bytes to google's `ParseFromString` (a Stage-4 bridge — google
  parses bytes it did not itself serialize; Stage 4 replaces that final
  materialization with `ball::ir`).
- **Byte-equivalence harness** (`cpp/test/test_ball_rt_equivalence.cpp`, CTest
  `ball_rt_equivalence`, built only when the option is ON): loads EVERY
  `tests/conformance/*.ball.json` through both decoders (google JSON→Program as
  ground truth, then google `Any`-serialize → ball_protobuf binary decode) and
  asserts `MessageDifferencer::Equals`. Prints `Results: N passed, M failed, T
  total` and fails on any mismatch — **324/324 pass** (WSL g++ 14.2, Release).
  It needs the same `absl::SetMutexDeadlockDetectionMode(kIgnore)` workaround
  as `test_e2e.cpp` (#25's v34.1 false positive — heavy google-side use trips
  it). CI proof: a Linux-only `ci.yml` step (`#18 Stage 3 — …byte-equivalence`)
  configures a SEPARATE `cpp/build-rt` with the option ON, reusing the
  ccache-warmed protobuf, so the default job's build stays google-only.
- **The harness immediately caught a REAL runtime bug** (a third instance of
  the `addAll` trap, sibling of PR #331's marshal-side fix):
  `dart/ball_protobuf/lib/unmarshal.dart` accumulated repeated wire occurrences
  through an ALIAS of the list stored in the message
  (`existing.addAll(keptValues)`, and the same for the `$unknown` byte
  capture). `addAll` encodes to the NON-mutating `list_concat` whose rebound
  result only updates the local — on compiled targets every repeated element
  after the first was silently dropped (each decoded module kept `functions[0]`
  only). Dart's in-place `addAll` masked it; the smoke canary only had singular
  fields. **Fixed at source** with per-item `.add` loops (in-place
  `list_push`); `ball_protobuf.{json,bin}` and `ball_protobuf_rt.h`
  regenerated. Rule of thumb: `x.addAll(y)` is safe only when `x` is a local
  whose REBOUND value is subsequently read (e.g. `marshal`'s returned
  `buffer`); through an alias it loses data — see `.claude/rules/dart.md`.

**Deferred — Stage 4 (drop google entirely):**
- The compiler (`compiler/`) and encoder (`encoder/`) still consume the
  generated `ball::v1::` protobuf types throughout their ~600 KB emission code
  (accessor calls like `.functions()`, `.has_body()`). Migrating them to the
  `ball::ir` field-access shape (and swapping `main.cpp`'s `ball_file.h`
  `DecodeProgram` for `ball::ir::parseProgramString`, plus dropping the
  ball_protobuf→google `ParseFromString` bridge in the Stage-3 binary path for a
  direct map→IR handoff) is the remaining work. Only after that can
  `target_link_libraries(ball_shared … protobuf::libprotobuf)` and the
  FetchContent block above be removed (closing #25's abseil deadlock).

## Dependencies
- Internal: generated protos in `gen/`.
- External: protobuf (`google/protobuf`), nlohmann/json (for `ball_ir.h`).
