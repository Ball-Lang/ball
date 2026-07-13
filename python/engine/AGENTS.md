<!-- Parent: ../AGENTS.md -->

# `python/engine` — self-hosted Python Ball engine (epic #445 Phase 4)

Runs Ball programs by the **self-host** route (SKILL.md Phase 4, Option B), the
same approach as the TS/C++/Rust/C#/Go targets: the reference engine is itself a
Ball program (`dart/self_host/engine.ball.json`), compiled through
`python/compiler` in **library mode** into a generated `compiled_engine.py`, and
driven by a thin native wrapper.

## Status: 312 / 320 conformance fixtures at Dart-identical output

`Results: 312 passed, 8 failed, 320 total (4 skipped carve-outs)` — the whole
`tests/conformance` corpus. The 4 skipped fixtures are the same golden-less
resource-limit / sandbox carve-outs the Rust/C#/Go runners skip
(`196_timeout`, `197_memory_limit`, `201_input_validation`, `202_sandbox_mode`).
The 8 residuals are root-caused in **Known residuals** below.

`compiled_engine.py` is a GENERATED, gitignored (~690 KB) build artifact absent
from a fresh checkout — `pytest`/`compileall` on the checked-in sources never
need it; only the conformance runner (which regenerates it first) does.

## Layout

| File | Role |
|------|------|
| `ball_engine/loader.py` | Build the canonical proto3-JSON view of a target `Program` the compiled engine reads via the `ball_proto` access patterns. Uses the generated protobuf binding (`ball.v1`) to materialise proto3 defaults, then post-processes: int64 strings -> int, doubleValue -> float, bytesValue -> `list[int]`, and every `metadata` re-expanded to the raw `google.protobuf.Struct` shape (`{fields:{key:{stringValue:…}}}`). The Python sibling of `go/engine/loader.go`. |
| `ball_engine/driver.py` | Construct the compiled `BallEngine` (16-arg constructor: program view, stdout callback, permissive limits, a `StdModuleHandler`) and call the compiled instance `run`. Runs on a worker thread with a large C stack + lifted recursion limit (the engine is a deep tree-walker-on-tree-walker). |
| `ball_engine/regen.py` | `python -m ball_engine.regen` — reads `engine.ball.json`, compiles via `ball_compiler.compile_library`, writes `compiled_engine.py`. |
| `ball_engine/__main__.py` | `python -m ball_engine <program.ball.json>` — runs one program, prints its stdout. Forces UTF-8 IO. The killable subprocess the conformance runner spawns. |
| `conformance/runner.py` | Whole-corpus sweep. Prints `Results: N passed, M failed, T total (K skipped carve-outs)` + a `FAILING [name] status detail` line per failure. |

## Regenerate + run

```bash
# From dart/, regenerate the self-host source if absent (gitignored):
cd dart && dart run compiler/tool/gen_engine_json.dart

# Regenerate compiled_engine.py:
cd python/engine && python -m ball_engine.regen

# Run the whole conformance corpus (needs the protobuf binding + ballrt on path):
cd python/engine && python -m conformance.runner
#   -> prints the CI-parseable `Results:` line.
# BALL_FIXTURE=<name> runs a single fixture with a full diff;
# BALL_TIMEOUT_S=<s> sets the per-fixture kill budget; BALL_WORKERS=<n> parallelism.
```

The runner and `__main__` bootstrap `python/runtime` (ballrt) and
`python/shared/gen` (protobuf binding) onto `sys.path`, so they run from a plain
checkout.

## Per-fixture timeout — subprocess, not cooperative (contrast with Go)

Each fixture runs as its own `python -m ball_engine` **subprocess** with a
per-fixture wall-clock timeout (`subprocess.run(timeout=…)`). A runaway (infinite
loop / unbounded recursion) is simply **killed** — a Python process is trivially
killable, which sidesteps the goroutine-leak problem the Go runner has to work
around with a cooperative execution-timeout guard (Go cannot kill a goroutine, so
its runner leaks the goroutine and risks a fatal stack overflow; see
`go/engine/AGENTS.md`). The runner also feeds the compiled engine's cooperative
`timeoutMs` (a hair under the kill budget) so a flat-stack runaway self-aborts
cleanly with `Execution timeout exceeded` before the hard kill. Fixtures run in
parallel (subprocess.run releases the GIL while waiting).

## Generated file — NEVER edit

`ball_engine/compiled_engine.py` — the self-hosted engine, compiled from
`dart/self_host/engine.ball.json`. Regenerate, never hand-patch. To change engine
behaviour, fix `python/compiler` (a fix + regen) or `python/runtime` (no regen)
or the `dart/self_host/` source.

## Fixing engine behaviour

A divergence from Dart is either in the compiler's emitted code (a
`python/compiler` fix + regen) or in a runtime helper the emitted code calls (a
`python/runtime` fix, no regen). The parity grind's root-cause clusters (all
fixed) are worth knowing:

- **`getfield` key-vs-getter** (biggest): the loaded proto view has literal fields
  named `values` (`ListValue.values`), `keys`, `entries` — an actual dict key must
  win over the Dart Map getter, or param extraction reads the map's values getter
  and every variable comes up "Undefined". Plus the `field_2`->`field` /
  `descriptor_`->`descriptor` protoc-dart renamed-getter aliases.
- **Named constructor arguments**: a messageCreation's *named* field
  (`_FlowSignal('return', value: x)`) maps to a Python keyword argument, not a
  positional slot — otherwise every interpreted-program return value is silently
  dropped (all early-return/recursion fixtures).
- **`toString`/`runtimeType`/`hashCode`**: universally routed through
  `ballrt.call_method` (the receiver may be a builtin at run time even though a
  user class overrides it); `value.runtimeType` returns the Dart type name.
- **`map_put_if_absent`** invokes its ifAbsent callback (Dart `putIfAbsent`);
  **map comprehensions** (`{for..if.. k:v}`) build imperatively; a **side-effecting
  field assign** captures its value in a temp (never re-evaluates `list_push`);
  synthetic `__type_args__`/`__const__` fields are dropped from constructor args.

## Known residuals (8 fixtures)

- **`107_method_override_super` / `165_oop_virtual_dispatch` / `177_oop_diamond`**
  — interpreted-program `super.method()` dispatch enters an infinite
  `main` ↔ `Base.name` method-resolution loop (traced; the exact cause in the
  engine's `__super__`-object construction / `__type__` propagation as it
  interacts with the runtime `BallObject`/`getfield`/`index_get` is not yet
  isolated). The only OOP-super failures; single-inheritance without `super`
  (e.g. `102_inheritance`) passes.
- **`258_logical_and_pattern`** — a switch pattern that binds a variable
  (`Undefined variable "n"`): the interpreted pattern-destructuring bind path.
- **`275_enc_try_catch`** — `int.parse` on bad input throws a Ball
  `FormatException` string, but the interpreted `on FormatException catch` type
  match does not recognise a bare string as that type (needs a typed exception
  value).
- **`199_malicious_input_patterns` / `255_string_surrogate_astral`** — index
  out of range on adversarial / astral-surrogate string inputs (UTF-16 index
  bounds).
- **`300_enc_catch_stack`** — a second-line difference in caught-error stack
  reporting (`stack_trace_of` returns an empty trace).
