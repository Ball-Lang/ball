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
| `tests/` | pytest: runtime semantics, emitted-shape checks, fail-loud, and the golden-exact conformance gate. |

## Build & Test

```bash
# No build step; pure Python (>=3.11). Dev dep is pytest only.
cd python/compiler && python -m pip install -r requirements-dev.txt   # once
python -m pytest -q                                                   # unit + e2e conformance
python -m compileall ../runtime/ballrt ball_compiler                  # syntax gate

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
  ordinary objects, not a runtime message map.

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

## Status (Phase 2)

Compiler + runtime only (no encoder/engine/CLI-beyond-compile, no CI — later
phases). **179 of the `tests/conformance/*.ball.json` fixtures compile and run
golden-exact**, covering arithmetic (Dart-exact `~/`, non-negative `%`,
int/double distinction, `toString`), comparison/logic (short-circuit),
strings, control flow (if/for/while/do-while/for-in, break/continue with
C-`for` update semantics, switch with const/or/wildcard patterns), recursion,
closures, and classes. `tests/test_conformance.py` gates a curated proven
subset.

Known gaps (fail loud or documented, deferred to a later hardening pass): getters
/ setters, `toString`/`operator` overrides, `super`/mixins/factory & named
constructors, enum/static members, map/set literals and most `std_collections`
map ops, type/relational/destructuring switch patterns, and 64-bit integer wrap
(Python ints are arbitrary-precision).
