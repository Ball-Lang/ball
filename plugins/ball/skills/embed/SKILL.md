---
name: embed
description: This skill should be used when a developer wants to safely execute dynamically-delivered code inside their own app — "server sending dynamic instructions to a client", "server-driven logic or UI without risky remote code execution", "audit an untrusted program before running it", "embed the Ball engine", "sandbox a downloaded program", "run partner-supplied programs", or invokes /ball:embed. Covers the receive → audit → reject-or-execute pattern and exposing only a vetted native API surface to untrusted Ball programs.
---

# Ball Embed — safe embedded execution of dynamically-delivered programs

Ball turns "download code and run it" from an arbitrary-code-execution problem into a bounded, auditable one. A Ball program is a Protocol Buffer message, not text: there is no `eval`, no FFI in the language, and **every** side effect flows through a named base function in a known module (`std`, `std_io`, `std_fs`, `std_memory`, `std_concurrency`, `std_collections`, `std_convert`, `std_time` — CLAUDE.md invariant #4). That closed side-effect channel is what makes static audit *provably complete* and what lets you hand a program only the capabilities you choose.

This skill teaches the embedding pattern and its non-negotiable security invariants. It is grounded in the Ball repo; where a target's safety knobs are missing or immature, it says so instead of pretending parity.

## The core pattern: receive → audit → reject-or-execute → vetted modules

```
untrusted bytes
  │
  ├─ 1. size-gate RAW bytes (before parsing)
  ├─ 2. decode to Program/Module   (transport: .ball.bin or .ball.json)
  ├─ 3. AUDIT the SAME bytes you will execute
  │        • capability policy (deny fs/process/memory/concurrency/…)
  │        • your OWN module-name allowlist (audit can't see custom modules)
  │        • termination check (Dart only; heuristic, not a halting proof)
  ├─ 4. REJECT on any violation  ── or ──▶ EXECUTE on a locked-down engine
  │                                          • sandbox: true
  │                                          • ALL resource limits set explicitly
  │                                          • StdModuleHandler.subset({…}) allowlist
  │                                          • ONLY your vetted app modules registered
  └─ output
```

The Dart `ball audit` CLI verb (`dart/cli/lib/src/runner.dart:462`) is the reference implementation of steps 1–4; its own `run` path (`runner.dart:311`) is the minimal 3-line embedding it guards. **The audit and the engine sandbox are two different layers** — audit is a static pre-filter, the engine's `sandbox`/module-allowlist is run-time enforcement. You need both; neither substitutes for the other.

## Security invariants (non-negotiable checklist)

- [ ] **Audit the exact bytes you execute.** Decode once, audit that object, execute that object. Never audit one payload and run another (TOCTOU).
- [ ] **Deny-by-default module surface.** Never register `std_fs`/`std_io`/`std_memory`/`std_concurrency` handlers for untrusted input. Register `StdModuleHandler.subset({…})` — an allowlist of only the pure/UI functions your program needs — plus your own vetted app modules and nothing else.
- [ ] **`sandbox: true` is not sufficient alone.** It blocks only `std_fs.*` + `std_io.exit`/`panic`/`env_get` (verified: `engine_std.dart` `_checkSandbox` call sites). It does **not** block `std_memory` or `std_concurrency`. Combine it with the `subset` allowlist above.
- [ ] **The audit cannot see custom or unknown modules.** `analyzeCapabilities`/`ball audit` only classifies base functions listed in `capability_table.dart`. A program declaring its own `isBase` module (an attacker's, or your own `ui` module) is reported as **pure / no risk**. Add your own check that rejects any `isBase` function in a module name outside your allowlist. The real hard boundary is the engine failing closed on an unregistered module handler — the audit is a fast pre-filter, not the boundary.
- [ ] **Set every resource limit explicitly.** Defaults are tuned for trusted source, not sandboxing (TS defaults: `maxModules`/`maxExpressionDepth` = 1,000,000; `maxRecursionDepth` = 100,000). Set `timeoutMs`, `maxMemoryBytes`, `maxModules`, `maxExpressionDepth`, `maxRecursionDepth`, `maxProgramSizeBytes` yourself, low.
- [ ] **Size-gate raw bytes before parsing.** `maxProgramSizeBytes` is checked inside the engine after decode; cap the raw payload at the transport layer first.
- [ ] **Metadata is untrusted cosmetic data.** The engine never branches on `metadata` (CLAUDE.md invariant #2), so you never need to strip it for execution safety — but it carries attacker-controlled strings. Never render it into UI/HTML/logs unescaped, and never branch privileged app logic on it.
- [ ] **A dedicated engine instance per untrusted run.** Never reuse an engine that has privileged first-party handlers (analytics, storage, navigation) to run server-pushed programs.
- [ ] **Authenticity is your job, not Ball's.** Ball does not sign or authenticate payloads. Sandboxing limits what a program *does*, not whether it is the one your server sent — verify a signature/hash before the engine, and treat structurally-valid ≠ safe *business logic*.

## The extensibility seam: expose ONLY a vetted native surface

Native capabilities (UI primitives, a `db.query`, a `nav.push`) enter an engine exclusively through a `BallModuleHandler` you write (`dart/engine/lib/engine_types.dart:403`). That is the same mechanism you must never hand carelessly to untrusted code — and exactly how you give a dynamic-UI program a safe, minimal API:

```dart
class UiModuleHandler extends BallModuleHandler {
  @override bool handles(String module) => module == 'ui';
  @override Object? call(String fn, Object? input, BallCallable engine) => switch (fn) {
    'text'   => renderText(input),
    'button' => renderButton(input),
    _        => throw BallRuntimeError('Unknown ui function: "$fn"'),  // fail closed
  };
}
```

Only plain data crosses the boundary. Event handlers are safest as `{module, function}` **name pairs** re-invoked later via `BallEngine.callFunction(...)` — a tap re-enters the same already-audited program — rather than live Ball closures held across the boundary.

## The three scenarios

- **Server sends dynamic instructions.** Author/encode the program at CI time, gate it with `ball audit --deny … --exit-code` (see references — deny alone exits 0 on the Dart CLI), ship the `.ball.bin`/`.ball.json` behind your authenticated API. The client re-audits and executes locked-down. Ball is not needed at request-serving runtime — only to produce and vet the blob.
- **Client audits at runtime, then executes.** On Dart, call `analyzeCapabilities`/`checkPolicy`/`analyzeTermination` from `ball_base` in-process before constructing the engine. On TS there is no exported in-process capability library — shell out to the `ball audit` CLI subprocess or do your own module-allowlist walk. Then execute on the locked-down engine.
- **Dynamic native UI.** Deliver a `Program` (server dictates control flow) or a library `Module` (client provides its own driver loop) whose logic uses pure `std` plus a custom `ui` module of bodyless `isBase` functions. Register only your `UiModuleHandler` (plus a `std` subset); a `default: throw` inside it is a hard allowlist. This gives truly native dynamic UI with no arbitrary code execution.

## Per-target honest status (read the reference before you pick one)

| Target | Embeddable for untrusted input? |
|---|---|
| **Dart** (`ball_engine` + `ball_base`, pub.dev) | **Yes — reference target.** Full sandbox + all limits + `moduleHandlers` + in-process audit library. |
| **TypeScript** (`@ball-lang/engine`, npm) | **Mostly.** Sandbox + limits + `StdModuleHandler.subset`. Gaps: no public custom-module registration, no in-process audit library (CLI subprocess only). |
| **Rust** (`ball-engine`, crates.io) | **Trusted only.** Runs at Dart parity, but the public crate exposes no sandbox/limit/custom-module knobs yet. |
| **C++** (`engine_rt`, vendored) | **Trusted only.** No package; vendor + regenerate + `#include`. No demonstrated sandbox path. |
| **C#** | **No.** Engine does not execute to golden output yet (`SelfHostPendingException`). Encoder + value model only. |

**Read `references/embedding-per-target.md`** for verified, copy-ready snippets per target (constructor surfaces, exact defaults, and every gap above with its evidence). **Read `references/audit-and-policy.md`** for capability categories, the `--deny`/`--exit-code` semantics (which differ between Dart and TS), what termination analysis does and does not prove, and why `network` is a vacuous category today.

## Dangerous assumptions (grounded in real evaluation failures)

| Assumption | Reality |
|---|---|
| "`sandbox: true` blocks everything dangerous." | It blocks fs + `exit`/`panic`/`env_get` only. `std_memory` and `std_concurrency` run freely under it — allowlist them out. |
| "`ball audit` passing means the program is safe." | Audit is blind to custom/unknown `isBase` modules and reports them as pure. Add your own module-name allowlist; rely on the engine's fail-closed-on-unknown-handler as the boundary. |
| "The engine defaults are safe for untrusted input." | Defaults target trusted source and are very permissive (esp. TS: 1,000,000 module/depth caps). Set every limit yourself. |
| "`ball audit --deny fs,network` fails the build on a violation." | On the Dart CLI, `--deny` alone prints and exits **0**; you must add `--exit-code`. The TS CLI always exits 1. They are not at parity. |
| "`--deny network` protects me from network access." | No base function maps to `network` today — the guarantee is vacuous. Network can only ever enter via a custom module *you* write, so gate that seam. |
| "Structurally valid / audited ⇒ correct." | Audit and sandbox stop host compromise and runaway compute, not a wrong *decision* ("approve every refund"). Business logic still needs its own review and a server-side kill switch. |
