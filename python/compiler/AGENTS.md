<!-- Parent: ../AGENTS.md -->

# Ball -> Python compiler (`ball_compiler`)

Emits a Python module (string emission, like the C++/Rust/Go/C# compilers) from
a Ball `Program`. The emitted module imports `ballrt` (the sibling runtime, see
`../runtime/AGENTS.md`) and nothing else.

## Layout

| File | Role |
|------|------|
| `ball_compiler/loader.py` | Load `.ball.json` into the raw proto3-JSON dict view (strips a `google.protobuf.Any` `@type` envelope). |
| `ball_compiler/compiler.py` | The `Compiler` class: classification, 7 expression node types, base-function dispatch, type/class emission, control-flow lowering. |
| `ball_compiler/__main__.py` | `ballpyc` CLI: `python -m ball_compiler <program.ball.json> [-o out.py]`. |
| `conformance/runner.py` | The **compile leg**: sweeps the whole fixture corpus (compile -> run the emitted `.py` in a subprocess -> byte-diff the golden) and prints the CI `Results:` line. The compiler analog of the engine leg. |
| `tests/` | pytest: runtime semantics, emitted-shape checks, fail-loud, and the golden-exact conformance gate (a curated *subset* — the corpus-wide number comes from `conformance/runner.py`). |

## Build & Test

```bash
# No build step; pure Python (>=3.11). Dev dep is pytest only.
cd python/compiler && python -m pip install -r requirements-dev.txt   # once
python -m pytest -q                                                   # unit + e2e conformance
python -m compileall ../runtime/ballrt ball_compiler                  # syntax gate

# Compile leg: the whole corpus through the compiler (~9s). Prints the Results: line.
python -m conformance.runner
BALL_FIXTURE=203_closure_in_loop python -m conformance.runner         # one fixture, full diff

# Compile a program and run it (runtime on PYTHONPATH):
python -m ball_compiler ../../tests/conformance/44_for_loop_basic.ball.json -o /tmp/out.py
PYTHONPATH=../runtime python /tmp/out.py
```

Windows note: emitted code and the CLI use only ASCII in generated comments;
run with `PYTHONIOENCODING=utf-8` when piping to a cp1252 console, since programs
may print non-ASCII (`ballpyc -o file` writes UTF-8 regardless).

## Design (the load-bearing decisions)

- **Real Python classes.** A `typeDefs[]` class becomes a Python `class` with
  `__init__` (constructor `this.`-params assign fields; declared fields default
  to `None`) and its methods as `def name(self, _input=None)`. Field access is
  attribute access; a method call (`call` whose input carries a `self` field) is
  `receiver.method(args)` — Python's own dispatch. This is why instances are
  ordinary objects, not a runtime message map. Dart getters/setters
  (`metadata.is_getter`/`is_setter`) emit as `@property` / `@name.setter`, so
  the `getfield`/`setfield` (getattr/setattr) paths invoke them transparently;
  a `toString` override also emits `__str__` so `print`/`to_str` (`str(obj)`)
  dispatch to it.

- **Two emission contexts (Python has no statement-expressions).** `run(expr,
  dest)` emits Python *statements* sending a result to a destination
  (`return`/assign a name/discard) — the device for "a block is an expression":
  blocks, `if`, and loops lower here to native statements, hoisting into a temp
  when a value is needed. `value(expr)` returns a Python *expression* string,
  hoisting any statement-bearing sub-expression into preceding statements + a
  temp. This is the same statement/expression split the C# compiler uses,
  adapted to Python's expression-only `lambda`.

- **Lazy control flow (invariant #4).** `if`/`for`/`while`/`for_in` compile to
  native Python control flow; branches/bodies are only emitted inside the taken
  arm. A C-style `for` lowers to `while True:` with the condition re-checked each
  iteration (so a hoisted condition re-evaluates). `&&`/`||` emit native Python
  `and`/`or` (short-circuit).

- **Flow signals are exceptions.** `return`/`break`/`continue`/`throw` compile to
  `ballrt` helper *calls* that raise (`ret`/`brk`/`cont`/`throw`) — valid Python
  expressions usable in any position. Function bodies wrap in `try/except
  BallReturn`; loop bodies trap `BallBreak`/`BallContinue`, and a trapped
  `continue` falls through so a C-`for` update still runs (Dart semantics).

- **Fail loud (issue #55).** An unsupported base function, an unresolvable
  reference, an unknown call target, or an unsupported pattern is a
  `CompileError` — never silently-wrong code. A silently-wrong output is a bug,
  not a gap.

## Status (Phases 2 + 4)

The compiler passes **52 tests** and — via **`compile_library` mode** (the
Ball -> Python analog of Go's `CompileLibrary`) — compiles the whole self-hosted
engine (`dart/self_host/engine.ball.json`), which runs the conformance corpus at
**Dart parity** (`Results: 320 passed, 0 failed`; see `../engine/AGENTS.md`).
Coverage spans arithmetic (Dart-exact `~/`, non-negative `%`, int/double, 64-bit
wrap), comparison/logic (short-circuit), strings, control flow, recursion,
closures, and OOP (constructors incl. **named + optional params**, methods,
`@property` getters/setters, `toString`, inheritance, top-level `const`s).

That list describes what the *engine* program exercises. It is **not** whole-corpus
coverage: the compile leg below shows `super`, static methods, factory/named
constructors, mixins, enum-value references, switch patterns, generators and
labeled break are all still open on the fixture corpus.

### Measured against the whole corpus (compile leg)

`python -m conformance.runner` sweeps all 320 executable fixtures through the
compiler. Measured, not asserted:

```
Results: 238 passed, 82 failed, 320 total (4 skipped carve-outs)
```

The 52 pytest cases are a curated *proof set*; this is the honest corpus number.
A fixture the compiler cannot emit counts as a **failure**, not a skip — only the
4 golden-less resource-limit/sandbox carve-outs are skipped. The 82 break down as
**55 `compile-error`** (loud, correct behaviour for a scope gap), **20 `error`**
(emitted Python that crashes at runtime — a real bug: the compiler emitted code it
should have refused), and **7 `fail`** — exit 0, wrong answer.

**Those 7 violate issue #55** and are the priority: `203_closure_in_loop` /
`229_closure_loop_var_semantics` (a C-style-`for` loop var is captured by Python's
late-binding closure, so every closure sees the final value: prints `12 12 12`,
golden `10 11 12` — the per-iteration snapshot the compiler does for `for-in` is
missing for C-`for`), plus `146`, `150`, `167`, `180`, `181`. Do not describe this
compiler as "no silent-wrong output" until they are fixed.

Load-bearing engine-mode decisions (all needed to reach parity): implicit-`self`
method calls, **named messageCreation fields → Python keyword args** (else return
values are dropped), the proto oneof-case `arm` enums + `__no_init__` sentinel,
`is`/`as` + Dart-SDK method routing through `ballrt`, and **per-iteration for-in
closure capture** (loop variables snapshotted as default args, since Python
shares a loop variable where Dart binds a fresh one each iteration). A rarely-
reached builtin static / stub-module call is a loud runtime raise (not a compile
error) so the library still compiles.
