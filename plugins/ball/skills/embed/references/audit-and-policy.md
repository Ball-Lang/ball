# Audit & capability policy — what `ball audit` proves, and what it doesn't

Grounded in the Ball repo. The audit is the static, pre-execution half of the embed pattern. Read `embedding-per-target.md` for the run-time (engine sandbox) half.

## Why capability analysis is provably complete (and its one blind spot)

Every side effect in Ball flows through a named base function in a known module (CLAUDE.md invariant #4). `analyzeCapabilities` walks every function body's expression tree and classifies each call via a **static lookup table** keyed `"module.function"` (`dart/shared/lib/capability_table.dart`). It is not a heuristic name scanner — it is closed over the language's only side-effect channel. The proto doc comment on `BallCapabilityReport` states this: *"provably complete — not heuristic."*

**The blind spot:** the table only knows the built-in base functions. A call to a *user-defined non-base* function is treated as pure and its callees walked recursively. But a program that **declares its own `isBase` module** — structurally identical to how `std_fs.file_read` is declared, just with an unrecognized name — is invisible: the report says pure / no risk, and `--deny` passes it. This is real (verified by testing an `evil.steal_everything` module), not theoretical. **Mitigation:** you must add your own check that walks `program.modules[]` and rejects any `isBase` function whose module name is outside your allowlist. The engine's fail-closed behavior (an unregistered module handler throws `BallRuntimeError` at the call site) is the actual boundary; the audit is a fast pre-filter.

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

### `network` is a vacuous category today

`network` exists in the enum and risk table, but **zero base functions map to it** — there is no `std_net`/socket module in the codebase. `--deny network` denies nothing because nothing can trigger it. Do not tell users the audit protects them from network access. Network I/O can only ever enter via a custom `BallModuleHandler` *you* write — which is exactly the seam to gate, and which the audit cannot see anyway (blind spot above).

## `checkPolicy` / `--deny` and the `--exit-code` gotcha

`checkPolicy(report, deny: {…})` returns human-readable violation strings for every call site whose capability category is in `deny`; empty list = pass.

The CLI exit-code behavior is **not** at parity across targets — pin to one and read its actual semantics:

- **Dart CLI** (`dart/cli/lib/src/runner.dart`): `ball audit prog.ball.json --deny fs,process` alone **prints violations to stderr but exits 0**. `throw _CliExit(1)` only fires when `--exit-code` is also passed. **`--exit-code` is mandatory for any CI/embedding gate** — deny alone is advisory. Full flag set: `--deny <csv>`, `--output <path>`, `--reachable-only`, `--exit-code`, `--check-termination`/`--no-check-termination` (on by default).
- **TS CLI** (`ts/cli`): a hand-ported analyzer; **always exits 1 on any deny violation** — there is no `--exit-code` flag (nor any termination flags). Flags: `--reachable-only`, `--deny <csv>`, `--output <path>`, `--json`. No termination analysis is wired into TS `audit` at all.
- **Rust / C++ / C#**: **no `audit` command** exists (Rust's command enum lacks it; the C++ self-host codegen explicitly drops `auditReport`; C# has only `CliInfo`). Audit on Dart or TS.

### Report emission asymmetry (Dart)

- No `--output`: text report to stdout.
- With `--output <path>`: the **capability report only** is written as proto3-JSON to the file; stdout gets nothing but a stderr confirmation.
- **Termination warnings are always text on stdout**, never in the `--output` JSON (they are not proto-serializable). An embedder parsing the JSON file will not see termination results — read them from stdout, or call `analyzeTermination`/`hasErrors` directly if embedding the Dart package.

## `--reachable-only` — a real trade-off

`reachableOnly: true` does a DFS from `entryModule`/`entryFunction` and analyzes only transitively-called functions, excluding dead code from the report. This cuts noise but means a capability in an unreached function is not reported. For a strict pre-filter that catches even latent capability declarations, prefer `reachableOnly: false` (audit everything) and let the engine allowlist handle run-time enforcement.

## Termination analysis — heuristic, not a halting proof

`analyzeTermination` (`termination_analyzer.dart`, **Dart only**) flags four *shapes*: `infinite_loop` (loops with no mutated condition/reachable exit), `unbounded_recursion` (recursion cycles lacking an `if`-guarded base case), `unreachable_code` (statements after a terminating `return`/`throw`), `orphaned_label`. Only `severity == 'error'` sets `hasErrors`, which is what `--exit-code` gates on.

Unlike capability analysis, **nothing claims termination analysis is complete or sound.** It matches textbook-shaped risk patterns: it can neither prove a program halts nor prove it doesn't. A program can still infinite-loop or stack-overflow without any warning (e.g. recursion bounded by a condition it doesn't recognize as a base case), and can trip a warning while being perfectly safe. Treat it as "catches common obviously-unsafe shapes," and rely on the engine's `timeoutMs`/`maxRecursionDepth`/`maxExpressionDepth` as the actual run-time backstop against nontermination.

## Two layers, restated

| | Static audit (`ball audit` / `analyzeCapabilities`) | Run-time engine (`sandbox` + `subset` + limits) |
|---|---|---|
| When | Before execution | During execution |
| Sees | Only known base functions in `capability_table.dart` | Every call, including into your custom modules |
| Catches | Declared use of `std_fs`/`std_memory`/… even in unreached branches (`reachableOnly: false`) | Unknown modules (fail-closed), timeouts, memory, sandbox-blocked fs |
| Blind to | Custom / unknown `isBase` modules (reports pure) | Nothing it's wired to enforce — but `sandbox` alone misses `std_memory`/`std_concurrency` |

Neither is sufficient alone. Audit fast and reject the honest-mistake and obvious-attack cases; enforce the boundary at run time with a minimal engine, a `StdModuleHandler.subset`, only your vetted modules registered, and every limit set explicitly.
