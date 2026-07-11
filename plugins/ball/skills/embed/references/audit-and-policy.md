# Audit & capability policy — what `ball audit` proves, and what it doesn't

Grounded in the Ball repo. The audit is the static, pre-execution half of the embed pattern. Read `embedding-per-target.md` for the run-time (engine sandbox) half.

## Why capability analysis is provably complete (and its two blind spots)

Every side effect in Ball flows through a named base function in a known module (CLAUDE.md invariant #4). `analyzeCapabilities` walks every function body's expression tree and classifies each call via a **static lookup table** (`dart/shared/lib/capability_table.dart`): first by the exact `"module.function"` pair, and — since #402 — falling back to the call's globally-unique **bare function name** when that pair misses and the name is not a declared user function. It is not a heuristic name scanner — it is closed over the language's only side-effect channel. The proto doc comment on `BallCapabilityReport` states this: *"provably complete — not heuristic."*

**Call-site module spoofing is closed (#402).** A base call can be written with a lying `call.module` string — `{module: "harmless_looking_module", function: "mutex_create"}` — because the engine dispatches a base call by its function identity, not by that string. Before #402 this slipped past the `"module.function"` lookup and was filed as an ordinary user call (invisible to `--deny`) while still executing. The bare-name fallback now categorizes it as `concurrency` regardless of the spoofed module, on **both** the Dart audit and the compiled TS CLI (all 263 base functions have globally-unique bare names — 0 collisions, asserted). So audit-then-execute is sound against this class of spoofing — **but only in builds carrying #402.** Verified against published packages: `@ball-lang/cli@1.42.0` audits the spoof as "NO RISK — pure" (exit 0), `@ball-lang/cli@1.43.0` denies it "MEDIUM RISK · concurrency" (policy violation, exit 1). **Require `@ball-lang/cli`/`@ball-lang/engine` ≥ 1.43.0 on npm.** On pub.dev the current Dart release (`ball_base 0.3.0+3`, 2026-07-03) predates the 2026-07-11 #402 merge, so the on-device Dart audit does not yet catch it — pin a build whose CHANGELOG includes the #402 audit-identity fix (Dart's real boundary is its run-time module allowlist, not the audit, so this lag is far less dangerous there than on TS).

**Residual (deferred hardening).** The fallback deliberately skips a call whose name **is** a declared non-base user function, so an attacker can declare a same-named **decoy** user `mutex_create` and the audit will treat the call as that user function (not denied). Whether that becomes a real bypass depends on the engine's own dispatch-resolution order; the engine-side defense (fail-loud on cross-module bare-name base resolution) is left as separate hardening per #402. The robust answer is not audit alone: pair it with a **deny-by-default engine module allowlist** (Dart `moduleHandlers` — never register `std_io`/`std_fs`/`process`/`memory`/`concurrency`/net for untrusted programs). On TS, where no run-time allowlist exists, keep the input surface minimal and the audit mandatory.

Two things the audit still does **not** see (both are *declaration*-level, distinct from the call-site spoofing above):

1. **Custom / unknown `isBase` modules.** The table only knows the built-in base functions. A call to a *user-defined non-base* function is treated as pure and its callees walked recursively. But a program that **declares its own `isBase` module** — structurally identical to how `std_fs.file_read` is declared, just with an unrecognized name — is invisible: the report says pure / no risk, and `--deny` passes it. This is real (verified by auditing an `evil.exfiltrate` module — reported "NO RISK — pure computation only"), not theoretical.
2. **Declarative `module_imports`.** `analyzeCapabilities` walks call expressions in function bodies, **not** the `module_imports[]` on a `Module` (`ball.proto:148-162`, sources `http`/`git`/`registry`/`inline`). A program can pull in additional code declaratively and the capability report will not mention it. The engine's optional `ModuleResolver? resolver` is what would fetch `http`/`git`/`registry` sources on demand — leave it null for untrusted input, and reject non-empty imports outright.

**Mitigation (both blind spots), as runnable code — not a comment:**

```dart
// Strict, explicit allowlist of module NAMES you actually register + permit.
// Do NOT accept "any std*-looking name": an attacker can name a module `std_x`
// with isBase functions, and an unimplemented std_* (e.g. std_memory today) is
// not something you want reachable either. Allowlist the exact set, nothing else.
const allowedModules = {'std', 'std_collections', 'std_convert', 'ui'};

for (final m in program.modules) {
  if (m.moduleImports.isNotEmpty) {
    throw StateError('rejected: module "${m.name}" declares module_imports');
  }
  for (final f in m.functions) {
    if (f.isBase && !allowedModules.contains(m.name)) {
      throw StateError('rejected isBase "${m.name}.${f.name}" outside allowlist');
    }
  }
}
```

The engine's fail-closed behavior (an unregistered module handler throws `BallRuntimeError` at the call site) is the actual run-time boundary; the audit + this walk is the fast pre-filter. That backstop only holds while every handler's `handles()` is specific — a `handles(_) => true` handler swallows unknown modules and defeats it, so never write one. On TS, where the run-time std surface cannot be restricted at all (see `embedding-per-target.md`), this walk is the *primary* gate, not a supplement.

## The capability categories

The `Capability` enum (`capability_table.dart`) — these are the values `--deny` and `checkPolicy` accept. **They are categories, not module names.** `--deny std_fs` (a module name) silently matches nothing; the correct value is `fs`.

| Category | Risk | Example base functions |
|---|---|---|
| `pure` | none | all arithmetic/logic/string/`std_collections`/`std_convert` |
| `io` | low | `std.print`, `std_io.print_error`/`read_line`/`env_get`/`args_get` |
| `time` | low | `std_io.sleep_ms`/`timestamp_ms`, most `std_time.*` |
| `random` | low | `std_io.random_int`/`random_double` |
| `async` | low | `std.yield`/`yield_each`/`await`/`async` |
| `fs` | medium | every `std_fs.*` (file/dir read/write/delete/exists/list) |
| `concurrency` | medium | every `std_concurrency.*` (thread/mutex/atomic) |
| `process` | high | `std_io.exit`/`panic` |
| `memory` | high | every `std_memory.*` (alloc/free/read/write/ptr/stack) |
| `network` | high | **none — see below** |

For untrusted input, a typical hard deny is `fs,process,memory,concurrency` (and `io`/`time`/`random` if the program should be purely computational).

> **`std.print` is category `io`.** Denying `io` therefore rejects an otherwise-harmless `print`-only program — a real, silent policy bug seen in evaluation (deny set too broad → the legitimate program is refused). Pick deny sets deliberately: too broad is an availability bug, too narrow a security hole. If you want to *allow* console output but nothing else effectful, deny `fs,process,memory,concurrency,time,random` and leave `io` permitted.

### `network` is a vacuous category today

`network` exists in the enum and risk table, but **zero base functions map to it** — there is no `std_net`/socket module in the codebase. `--deny network` denies nothing because nothing can trigger it. Do not tell users the audit protects them from network access. Network I/O can only ever enter via a custom `BallModuleHandler` *you* write, or via an unrejected remote `module_import` — both blind spots above, neither visible to the capability report.

### Run-time reality vs the table (per-version caveat)

The table classifies what a program *declares*; whether the engine *implements* a category differs by target and version. On the current published Dart engine (`ball_engine 0.3.0+6`): `std_concurrency.*` is fully implemented and runs freely (even under `sandbox:true`), while `std_memory.*` has **no dispatch** and throws `Unknown std function`. Audit-deny both regardless — do not treat "std_memory happens to throw" as a security control; it is an implementation gap that a later version can close.

## `checkPolicy` / `--deny` and the `--exit-code` gotcha

`checkPolicy(report, deny: {…})` returns human-readable violation strings for every call site whose capability category is in `deny`; empty list = pass.

The CLI exit-code behavior is **not** at parity across targets — pin to one and read its actual semantics:

- **Dart CLI** (`dart/cli/lib/src/runner.dart`): `ball audit prog.ball.json --deny fs,process` alone **prints violations to stderr but exits 0**. `throw _CliExit(1)` only fires when `--exit-code` is also passed. **`--exit-code` is mandatory for any CI/embedding gate** — deny alone is advisory. Full flag set: `--deny <csv>`, `--output <path>`, `--reachable-only`, `--exit-code`, `--check-termination`/`--no-check-termination` (on by default).
- **TS CLI** (`ts/cli`): **self-hosted** since #362/#398 — compiled from the same `cli_core.dart` into `compiled_cli.ts`, not hand-ported (the old `capability_analyzer.ts`/`capability_table.ts` are deleted), so it shares the Dart audit's #402 spoofing fix **from `@ball-lang/cli` ≥ 1.43.0** (1.42.0 predates it and reports a spoofed concurrency call "NO RISK"). It **exits 1 directly on any deny violation** — there is no `--exit-code` flag (it isn't needed). Its default `ball audit <file>` report **does** now include termination analysis (byte-identical to the Dart CLI's default `auditReport`), but termination has no effect on the exit code — only `--deny` violations return 1. Flags: `--reachable-only`, `--deny <csv>`, `--output <path>`, `--json`. `ball audit` has **no stdin mode** — it reads a file path only (matters for the TOCTOU-safe subprocess recipe in `embedding-per-target.md`). Invoke it programmatically as `node <require.resolve('@ball-lang/cli')> audit …` — the **bare** specifier, because the package `exports` map is `"."`-only so the `@ball-lang/cli/dist/index.js` subpath throws `ERR_PACKAGE_PATH_NOT_EXPORTED` (verified); the bare form resolves the `"."` export to the same `dist/index.js` the `ball` bin targets. (The `node_modules/.bin/ball` shim throws `ENOENT` under `child_process` on Windows.)
- **Rust / C++ / C#**: **no `audit` command** exists (Rust's command enum lacks it; the C++ self-host codegen explicitly drops `auditReport`; C# has only `CliInfo`). Audit on Dart or TS.

### Report emission asymmetry (Dart)

- No `--output`: text report to stdout.
- With `--output <path>`: the **capability report only** is written as proto3-JSON to the file; stdout gets nothing but a stderr confirmation.
- **Termination warnings are always text on stdout**, never in the `--output` JSON (they are not proto-serializable). An embedder parsing the JSON file will not see termination results — read them from stdout, or call `analyzeTermination`/`hasErrors` directly if embedding the Dart package.

## `--reachable-only` — a real trade-off (prefer `false` for untrusted input)

`reachableOnly: true` does a DFS from `entryModule`/`entryFunction` and analyzes only transitively-called functions, excluding dead code from the report. This cuts noise but means a capability declared in a currently-unreached function is **not** reported — a gap for a strict pre-filter. **For untrusted input, use `reachableOnly: false`** (audit everything, including latent capability in unreached branches); the `runUntrusted` sample in `embedding-per-target.md` does exactly this. Reserve `reachableOnly: true` for trusted-source noise reduction, not for a security gate.

## Termination analysis — heuristic, not a halting proof

`analyzeTermination` (`termination_analyzer.dart`, **Dart only**) flags four *shapes*: `infinite_loop` (loops with no mutated condition/reachable exit), `unbounded_recursion` (recursion cycles lacking an `if`-guarded base case), `unreachable_code` (statements after a terminating `return`/`throw`), `orphaned_label`. Only `severity == 'error'` sets `hasErrors`, which is what `--exit-code` gates on.

Unlike capability analysis, **nothing claims termination analysis is complete or sound.** It matches textbook-shaped risk patterns: it can neither prove a program halts nor prove it doesn't. A program can still infinite-loop or stack-overflow without any warning (e.g. recursion bounded by a condition it doesn't recognize as a base case), and can trip a warning while being perfectly safe. Treat it as "catches common obviously-unsafe shapes," and rely on the engine's `timeoutMs`/`maxRecursionDepth`/`maxExpressionDepth` as the actual run-time backstop against nontermination.

## Two layers, restated

| | Static audit (`ball audit` / `analyzeCapabilities`) | Run-time engine (`sandbox` + `subset` + limits) |
|---|---|---|
| When | Before execution | During execution |
| Sees | Only known base functions in `capability_table.dart` | Every call, including into your custom modules |
| Catches | Declared use of `std_fs`/`std_memory`/… even in unreached branches (`reachableOnly: false`) | Unknown modules (fail-closed), timeouts, memory, sandbox-blocked fs |
| Blind to | Custom `isBase` modules and `module_imports` (reports pure) | `sandbox` alone misses `std_memory`/`std_concurrency`; **TS has no run-time std allowlist at all** |

Neither is sufficient alone. Audit fast and reject the honest-mistake and obvious-attack cases; enforce the boundary at run time with a minimal engine, a `StdModuleHandler.subset` (Dart), only your vetted modules registered, and every limit set explicitly. On TS the second column shrinks to `sandbox` + limits only — so the audit and your allowlist walk carry the weight.
