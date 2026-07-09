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
| `ball_protobuf_rt_smoke.cpp` | Hand-written smoke driver: `#include`s `ball_protobuf_rt.h` and round-trips real values through `encodeVarint`/`decodeVarint`, `encodeZigZag64`/`decodeZigZag`, and `encodeFixed32`/`decodeFixed32`. Built only behind `-DBALL_BUILD_PROTOBUF_RT=ON` (the #18 canary — see below). |
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

**Wire-codec portability fix (source) — regen still pending:**
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
  per-item (`for (final b in data) buffer.add(b);` → in-place `list_push`),
  proven byte-exact against the compiled runtime with a standalone g++ harness,
  and the 587-test native `ball_protobuf` suite still passes. `ball_protobuf.json`
  is regenerated (freshness-gated).
- **`cpp/shared/ball_protobuf_rt.h` is NOT yet regenerated** (it is a generated
  artifact produced by the built `ball_cpp_compile`; unlike `ball_protobuf.json`
  it has no CI freshness gate). Regenerating it locally is currently blocked:
  building the C++ compiler pulls protobuf via FetchContent, and BOTH the pinned
  `v34.1` (its runtime is incompatible with the checked-in `cpp/shared/gen`
  gencode, which now carries a `PROTOBUF_VERSION == 7035001` / 35.1 guard — a
  pre-existing skew that only bites when `buf` is off PATH so the stale gen
  fallback is used) and `v35.1` (its `repeated_ptr_field.h` will not compile with
  g++ 14.2 — `ABSL_ATTRIBUTE_VIEW`/`RepeatedPtrIterator` template conflict) fail
  to build. **TODO:** regenerate on a toolchain that can build the compiler
  (`cd dart/compiler && dart run tool/compile_ball_protobuf_cpp.dart`, or
  `ball_cpp_compile dart/shared/ball_protobuf.json --library --ns ball_protobuf
  --out cpp/shared/ball_protobuf_rt.h`) so the fix reaches the C++ runtime.
- **Two further defects the current `ball_protobuf_rt.h` still exhibits** (found
  while building a descriptor-driven canary; both need the regen above and/or a
  compiler fix — the `-DBALL_BUILD_PROTOBUF_RT=ON` canary only covers
  varint/zigzag/fixed32 primitives, so it does NOT catch either):
  1. **Singular `TYPE_MESSAGE` marshaling is broken by named-arg lowering.**
     `marshal.dart` calls `marshalField(buffer, fieldNumber, type, value,
     explicitPresence: …, delimited: …, messageDescriptor: msgDescriptor)` —
     omitting the earlier optional `repeated:`. The C++ compiler lowered the
     named args into consecutive positional slots (`repeated`, `explicitPresence`,
     `delimited`) instead of by declared-parameter position, so `messageDescriptor`
     lands in the `delimited` slot and the real `messageDescriptor` defaults to
     null → `marshalField` throws "TYPE_MESSAGE field N received a Map but no
     messageDescriptor". Repeated-message fields go through a different path
     (`marshal(item, msgDescriptor)` directly) and are unaffected. This is a
     compiler codegen bug (named→positional arg alignment must fill skipped
     optionals with defaults); scalar fields happen to work because the
     mis-slotted values are all falsy.
  2. **`unmarshal` mis-tracks offset** in the committed header: a byte-exact
     marshal output (verified) fails to round-trip — `unmarshal` reads a field
     tag but does not advance past the field VALUE, re-reading the value byte as
     the next tag. Native Dart `unmarshal` passes, so this is header
     staleness/miscompilation, not a source bug; regenerating the header should
     clear it (re-verify with a descriptor-driven round-trip canary afterward).

**Deferred (full cutover):**
- The compiler (`compiler/`) and encoder (`encoder/`) still consume the
  generated `ball::v1::` protobuf types throughout their ~600 KB emission code
  (accessor calls like `.functions()`, `.has_body()`). Migrating them to the
  `ball::ir` field-access shape (and swapping `main.cpp`'s `ball_file.h`
  `DecodeProgram` for `ball::ir::parseProgramString`) is the remaining work.
  Only after that can `target_link_libraries(ball_shared … protobuf::libprotobuf)`
  and the FetchContent block above be removed. The binary `.ball.pb`/`.ball.bin`
  path (Google `Any` wire decode in `ball_file.h`) also needs a protobuf-free
  replacement (candidate: `ball_protobuf_rt.h`'s wire codecs) before the pin
  drops.

## Dependencies
- Internal: generated protos in `gen/`.
- External: protobuf (`google/protobuf`), nlohmann/json (for `ball_ir.h`).
