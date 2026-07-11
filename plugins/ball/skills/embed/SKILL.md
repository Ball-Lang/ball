---
name: embed
description: This skill should be used when a developer wants to safely execute dynamically-delivered code inside their own app — "server sending dynamic instructions to a client", "server-driven logic or UI without risky remote code execution", "audit an untrusted program before running it", "embed the Ball engine", "sandbox a downloaded program", "run partner-supplied programs", or invokes /ball:embed. Covers the receive → audit → reject-or-execute pattern and exposing only a vetted native API surface to untrusted Ball programs.
---

# Ball Embed — safe embedded execution of dynamically-delivered programs

Ball turns "download code and run it" from an arbitrary-code-execution problem into a bounded, auditable one. A Ball program is a Protocol Buffer message, not text: there is no `eval`, no FFI in the language, and **every** side effect flows through a named base function in a known module (`std`, `std_io`, `std_fs`, `std_memory`, `std_concurrency`, `std_collections`, `std_convert`, `std_time` — CLAUDE.md invariant #4). That closed side-effect channel is what makes static audit *provably complete* and what lets you hand a program only the capabilities you choose.

This skill teaches the embedding pattern and its non-negotiable security invariants. It is grounded in the Ball repo; where a target's safety knobs are missing or immature, it says so instead of pretending parity. Read `references/embedding-per-target.md` and `references/audit-and-policy.md` for the copy-ready, verified code — the invariants below are only safe when you use that code, not a paraphrase of it.

## The core pattern: receive → audit → reject-or-execute → vetted modules

```
untrusted bytes
  │
  ├─ 0. SIZE-GATE the raw received bytes   (byte length, BEFORE any decode)
  ├─ 1. decode ONCE to a Program/Module    (transport: .ball.bin or .ball.json)
  ├─ 2. AUDIT that same decoded object
  │        • capability policy (deny fs/process/memory/concurrency/…)
  │        • your OWN isBase-module allowlist   (audit can't see custom modules)
  │        • reject any non-empty module_imports; never pass a `resolver`
  │        • termination check (Dart only; heuristic, not a halting proof)
  ├─ 3. REJECT on any violation ── or ──▶ EXECUTE that SAME object, locked down
  │                                          • try/catch the CONSTRUCTOR *and* run()
  │                                          • sandbox: true + every resource limit set
  │                                          • Dart: StdModuleHandler.subset({…}) allowlist
  │                                          • ONLY your vetted app modules registered
  └─ output   (run() return value / callFunction return / injected stdout)
```

The Dart `ball audit` CLI verb (`dart/cli/lib/src/runner.dart:462`) is the reference implementation of the audit half; its own `run` path (`runner.dart:311`) is the minimal 3-line embedding it guards. **The audit and the engine sandbox are two different layers** — audit is a static pre-filter, the engine's `sandbox`/module-allowlist is run-time enforcement. You need both; neither substitutes for the other.

## Security invariants (non-negotiable checklist)

- [ ] **Audit the exact bytes you execute.** Decode once, audit that object, execute that object. Never audit one payload and run another (TOCTOU). If you must shell out to a file-based `ball audit` (the only option on TS), write the received bytes to a temp file and load *that same file* into the engine — see the TS recipe in the reference.
- [ ] **Reject remote and embedded imports.** The engine takes an optional `ModuleResolver? resolver` (`engine.dart:201/222`) and a program's modules can carry `module_imports[]` with `http`/`git`/`registry`/`inline` sources (`ball.proto:148-162`) — a built-in code-import vector that needs no custom module. `analyzeCapabilities` does **not** walk import metadata, so a passing audit says nothing about them. For untrusted input: **never pass a `resolver`, and reject any program whose modules have non-empty `module_imports`** (inline embeds un-audited code; http/git/registry fetch remote code). Runnable check is in the reference.
- [ ] **Deny-by-default module surface — but only Dart enforces it at run time.** On Dart, register `StdModuleHandler.subset({…})` (an allowlist of only the pure/UI functions you need) plus your own vetted modules, and never register `std_fs`/`std_memory`/`std_concurrency` handlers. **On TS you cannot do this:** `new BallEngine(...)` always constructs a fresh, full `StdModuleHandler` (`ts/engine/src/index.ts:83,114`) with no injection point, so every implemented `std_*` function stays reachable at run time. The audit + your own allowlist walk is the *only* gate on TS — treat it as such.
- [ ] **`sandbox: true` is not sufficient alone.** It blocks only `std_fs.*` + `std_io.exit`/`panic`/`env_get` (verified: `engine_std.dart` `_checkSandbox` call sites). It does **not** block `std_concurrency.*` (implemented — `thread_spawn`/`mutex_*`/`atomic_*` at `engine_std.dart:1506-1536` — and runs freely under sandbox). `std_memory.*` currently throws `Unknown std function` in the Dart engine (unimplemented on this branch — a coverage gap, **not** a deliberate block; do not rely on it). Deny `memory`/`concurrency` at audit time *and* (on Dart) keep them out of your `subset`.
- [ ] **The audit cannot see custom or unknown modules.** `analyzeCapabilities`/`ball audit` only classifies base functions listed in `capability_table.dart`. A program declaring its own `isBase` module (an attacker's, or your own `ui` module) is reported as **pure / no risk**. You MUST add your own walk over `program.modules[]` that rejects any `isBase` function whose module name is outside a strict, explicit allowlist — allowlist the *specific* module names you register, not "any `std*`-looking name." The engine failing closed on an unregistered module handler is the real boundary — but that backstop evaporates the moment you register an over-broad handler (`handles(_) => true`), so never write one.
- [ ] **Set every resource limit explicitly, and try/catch the constructor.** Defaults target trusted source (TS: `maxModules`/`maxExpressionDepth` = 1,000,000; `maxRecursionDepth` = 100,000). Set `timeoutMs`, `maxMemoryBytes`, `maxModules`, `maxExpressionDepth`, `maxRecursionDepth`, `maxProgramSizeBytes` yourself, low. `maxProgramSizeBytes`/`maxModules` are validated in the **constructor** (`_validateProgramLimits`, `engine.dart:229/247`) and throw synchronously — wrap the `BallEngine(...)` construction, not just `run()`, or an oversized payload crashes your process instead of being rejected.
- [ ] **Size-gate raw bytes before decoding.** Gate the *received byte count* (e.g. the `Uint8List`/`Buffer` length, or `utf8.encode(json).length`), not a decoded string's `.length` — a string's length counts UTF-16 code units, so a payload of multi-byte characters can be ~3× its real wire size and slip a length check while the expensive UTF-8 decode has already run. `maxProgramSizeBytes` fires only *after* decode, so it is a second layer, not the first.
- [ ] **Metadata is untrusted cosmetic data.** The engine never branches on `metadata` (CLAUDE.md invariant #2), so you never need to strip it for execution safety — but it carries attacker-controlled strings. Never render it into UI/HTML/logs unescaped, and never branch privileged app logic on it.
- [ ] **A dedicated engine instance per untrusted run.** Never reuse an engine that has privileged first-party handlers (analytics, storage, navigation) to run server-pushed programs.
- [ ] **Authenticity is your job, not Ball's.** Ball does not sign or authenticate payloads. Sandboxing limits what a program *does*, not whether it is the one your server sent — verify a signature/hash before the engine, and treat structurally-valid ≠ safe *business logic*.

## The extensibility seam: expose ONLY a vetted native surface

Native capabilities (UI primitives, a `db.query`, a `nav.push`) enter an engine exclusively through a `BallModuleHandler` you write (`dart/engine/lib/engine_types.dart:403`). That is the same mechanism you must never hand carelessly to untrusted code — and exactly how you give a dynamic-UI program a safe, minimal API:

```dart
class UiModuleHandler extends BallModuleHandler {
  @override bool handles(String module) => module == 'ui';   // NEVER `=> true`
  @override Object? call(String fn, Object? input, BallCallable engine) => switch (fn) {
    'text'   => renderText(input),
    'button' => renderButton(input),
    _        => throw BallRuntimeError('Unknown ui function: "$fn"'),  // fail closed
  };
}
```

Only plain data crosses the boundary. Event handlers are safest as `{module, function}` **name pairs** re-invoked later — a tap re-enters the same already-audited program — rather than live Ball closures held across the boundary.

### Passing data in and getting a decision out

Two verified I/O channels (Dart; the TS/Rust wrappers capture stdout as a `string[]` return):

- **`run()`** → `Future<Object?>` returns the **entry function's** return value (a Ball value: `Map`/`List`/scalar). Program `std.print` output is delivered via the injected `stdout` callback, *not* `run()`'s return. The constructor's `args` is `List<String>?` — CLI-argv-shaped, not a channel for structured business context.
- **`callFunction(String module, String function, Object? input)`** → `Future<Object?>` (`engine.dart:244`) invokes a named function with a structured `input` and returns its result. This is the channel for a rules engine: pass your context (`{'cartTotal': 42.0, 'tier': 'gold'}`) as `input`, read the structured decision back from the return value. Re-invoking event handlers by name pair uses the same method.

## The three scenarios

- **Server sends dynamic instructions.** Author the program from real source with a Ball **encoder** (`ball encode <source> -o prog.ball.bin`, or the `ball_encoder`/`@ball-lang/encoder` package) — do not hand-write proto3-JSON. Gate it at CI time with `ball audit --deny … --exit-code` (see references — deny alone exits 0 on the Dart CLI), then ship the `.ball.bin`/`.ball.json` behind your authenticated API. The client re-audits and executes locked-down. Ball is not needed at request-serving runtime — only to produce and vet the blob.
- **Client audits at runtime, then executes.** On Dart, call `analyzeCapabilities`/`checkPolicy`/`analyzeTermination` from `ball_base` in-process before constructing the engine. On TS there is no exported in-process capability library (`@ball-lang/cli`'s package `exports` genuinely block importing its `capability_analyzer.js`) — do your own module-allowlist walk in-process, and/or shell out to the `ball audit` CLI subprocess (`node_modules/.bin/ball`, or `npx ball` — it is not on `PATH` after a plain install). Then execute on the locked-down engine.
- **Dynamic native UI.** Deliver either a `Program` (server dictates control flow) or a library `Module` (a set of vetted, entry-point-free UI functions). **A bare `Module` is not directly runnable — `BallEngine` takes a `Program`.** Audit a `Module` with `analyzeModuleCapabilities(module, imports: …)` (not `analyzeCapabilities`, which is typed to `Program`), then wrap it into a `Program` (set `modules`, `entryModule`, `entryFunction`) to execute — see the reference for both snippets. Register only your `UiModuleHandler` (plus, on Dart, a `std` subset); a `default: throw` inside it is a hard allowlist. This gives truly native dynamic UI with no arbitrary code execution.

## Per-target honest status (read the reference before you pick one)

| Target | Embeddable for untrusted input? |
|---|---|
| **Dart** (`ball_engine` + `ball_base`, pub.dev) | **Yes — reference target.** Full sandbox + all limits + `moduleHandlers` (runtime std allowlist) + in-process audit library. Caveat: `ball_engine` pulls `dart:io` (via `ball_resolver`) and **does not compile for Flutter/Dart web** — engine embedding is mobile/desktop/server only; `ball_base`'s audit library *does* support web, so a web client can audit but must run the program elsewhere. |
| **TypeScript** (`@ball-lang/engine`, npm) | **Partial — audit-gated only.** Sandbox + resource limits work, but you **cannot restrict the std surface or add custom modules at run time** (constructor hard-codes a full `StdModuleHandler`). Safety rests entirely on your pre-execution audit/allowlist walk + rejecting `module_imports`. No in-process audit library (CLI subprocess or your own walk). No custom-native-`ui`-module story yet. |
| **Rust** (`ball-engine`) | **Trusted only, and not on crates.io.** Runs at Dart parity, but the public API exposes no sandbox/limit/custom-module knobs. **Do not `cargo add ball-engine` — that name on crates.io is an unrelated 2D physics engine.** Vendor via a git dependency on `Ball-Lang/ball` (see reference). |
| **C++** (`engine_rt`, vendored) | **Trusted only.** No package; vendor + regenerate + `#include`. No demonstrated sandbox path. |
| **C#** | **No.** Engine does not execute to golden output yet (`SelfHostPendingException`). Encoder + value model only. |

**Read `references/embedding-per-target.md`** for verified, copy-ready snippets per target (constructor surfaces, exact defaults, the full receive→audit→reject→execute flow, and every gap above with its evidence). **Read `references/audit-and-policy.md`** for capability categories, the `--deny`/`--exit-code` semantics (which differ between Dart and TS), what termination analysis does and does not prove, and why `network` is a vacuous category today.

## Dangerous assumptions (grounded in real evaluation failures)

| Assumption | Reality |
|---|---|
| "`sandbox: true` blocks everything dangerous." | It blocks fs + `exit`/`panic`/`env_get` only. `std_concurrency.*` is implemented and runs freely under it — deny it at audit time and (Dart) keep it out of your `subset`. `std_memory.*` happens to throw `Unknown std function` on the current Dart engine, but that is an unimplemented coverage gap, not a guarantee — audit-deny `memory` regardless. |
| "`StdModuleHandler.subset({…})` locks down the TS engine too." | No. `new BallEngine(...)` in TS always builds a full, unrestricted handler and offers no way to inject a subset — the exported `subset()` you construct is never wired in. Runtime std restriction is a **Dart-only** control. |
| "`ball audit` passing means the program is safe." | Audit is blind to custom/unknown `isBase` modules (reports them pure) and to `module_imports`. Add your own module-name allowlist walk and reject non-empty imports; rely on the engine's fail-closed-on-unknown-handler as the boundary — and never register a `handles(_) => true` handler that defeats it. |
| "The engine defaults are safe for untrusted input." | Defaults target trusted source and are very permissive (esp. TS: 1,000,000 module/depth caps). Set every limit yourself, and wrap the **constructor** in try/catch — size/module limits throw there, not from `run()`. |
| "`cargo add ball-engine` installs the Ball engine." | It installs someone else's 2D physics crate (crates.io `ball-engine` v0.1.1, `github.com/parth2152012/ball-engine`). No Ball Rust crate is published; use a git dependency and verify provenance before adding it. |
| "`ball audit --deny fs,network` fails the build on a violation." | On the Dart CLI, `--deny` alone prints and exits **0**; you must add `--exit-code`. The TS CLI always exits 1. They are not at parity. |
| "`--deny network` protects me from network access." | No base function maps to `network` today — the guarantee is vacuous. Network can only ever enter via a custom module *you* write (or an unrejected remote `module_import`), so gate those seams. |
| "Denying `io` is harmless / narrow." | `std.print` maps to the `io` capability — deny `io` and a legitimate `print`-only program is rejected. Choose deny sets deliberately; a too-broad deny is a silent availability bug, a too-narrow one a security hole. |
| "Structurally valid / audited ⇒ correct." | Audit and sandbox stop host compromise and runaway compute, not a wrong *decision* ("approve every refund"). Business logic still needs its own review and a server-side kill switch. |
