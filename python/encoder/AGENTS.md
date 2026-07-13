<!-- Parent: ../AGENTS.md -->

# Python -> Ball encoder (`ball_encoder`)

Parses Python source with the standard library `ast` (no third-party parser) and
walks the tree, emitting a Ball `Program` as the **raw proto3-JSON dict view**
the Ball -> Python compiler (`../compiler`) consumes directly. It is the inverse
of that compiler and the Python sibling of `go/encoder` / `rust/encoder`.

## Layout

| File | Role |
|------|------|
| `ball_encoder/builders.py` | Low-level constructors for the 7 Expression node types + statements, producing proto3-JSON dicts (camelCase keys). The Python analog of `go/encoder/builders.go`. |
| `ball_encoder/encoder.py` | The `_Encoder` class + `encode(source) -> dict`: AST walk, one-input packing, base-module accumulation, fail-loud. |
| `ball_encoder/__main__.py` | `ballpyenc` CLI: `python -m ball_encoder <src.py> [-o out.ball.json]` — writes `@type`-enveloped proto3 JSON. |
| `tests/` | pytest: structural encoder tests, fail-loud cases, and the round-trip suite (`testdata/*.py`). |

## Build & Test

```bash
# No build step; pure Python (>=3.11). Dev dep is pytest only.
cd python/encoder && python -m pip install -r requirements-dev.txt   # once
python -m pytest -q                                                  # structural + round-trip
python -m compileall ball_encoder tests                             # syntax gate

# Encode a Python file, then compile+run the result (the full four-tool chain):
python -m ball_encoder tests/testdata/fizzbuzz.py -o /tmp/fb.ball.json
PYTHONPATH=../compiler python -m ball_compiler /tmp/fb.ball.json -o /tmp/fb.py
PYTHONPATH=../runtime  python /tmp/fb.py
```

The round-trip suite imports `../compiler` and `../runtime` off `sys.path`
(`tests/conftest.py`), so the encoder proves itself against the real Phase-2
compiler and runtime, no packaging step required.

Windows note: the CLI's error prefix and all diagnostics are ASCII; run with
`PYTHONIOENCODING=utf-8` when a source's own output contains non-ASCII.

## Design (the load-bearing decisions)

- **Output is the raw proto3-JSON dict, not the generated bindings.** The Phase-2
  compiler's loader walks a proto3-JSON `dict` (camelCase keys); the encoder
  produces exactly that, so the round-trip needs no protobuf runtime and
  `encode(src)` feeds straight into `compile_program(...)`. `int64` literals are
  emitted as JSON **strings** (the canonical proto3 form) and default scalars
  (`0`/`false`/`""`) are always written explicitly — the compiler distinguishes
  "int 0" from "unset (null)" purely by key presence.

- **No `python_std`, ever.** Every construct routes through the universal `std`
  (and `std_collections`) base module — operators -> `std.add`/`std.less_than`/…,
  control flow -> `std.if`/`std.for`/`std.while`/`std.for_in`, `print` ->
  `std.print`, indexing -> `std.index`. A conformant Ball engine that has never
  heard of Python still runs the result. `build_program` declares only the base
  functions actually referenced (walks the tree; sorted for determinism).

- **One input, one output (invariant #1).** A 0-parameter function takes no
  input; a 1-parameter function keeps its name (surfaced in `metadata.params`,
  which the compiler's prologue binds `p = _input`); a 2+-parameter call packs
  its arguments into one anonymous message keyed by the callee's real parameter
  names (recorded in a pre-pass), read back by the prologue as
  `p = ballrt.arg(_input, "p", "argN")`. `metadata.params` is the only load-
  bearing metadata; everything else is cosmetic (invariant #2).

- **Python scoping -> hoisted locals.** Python has no `let`/`=` split — a name is
  a function-scoped local the first assignment declares and later ones mutate.
  Ball's `LetBinding` is block-scoped and `std.assign` mutates, so each function
  is scanned for its assigned names, which are hoisted as `let <name> = null` at
  the top of the body; **every** assignment (first included) then compiles to
  `std.assign`, mutating the single function-scoped binding exactly as Python
  does. Parameters are excluded from the hoist set (the prologue owns them). This
  is what makes an accumulator inside a nested loop/if block mutate the outer
  variable correctly (`control_flow.py`).

- **Lazy control flow (invariant #4).** `if`/`while`/`for` encode to `std.if`/
  `std.while`/`std.for`(range)/`std.for_in`(iterable) with branch/body sub-
  expressions the compiler evaluates only when taken. Compound assignment (`+=`),
  `range()` counting, `and`/`or`, and chained comparisons desugar into `std`
  expression trees at encode time (no dedicated base function).

- **Fail loud (issue #55).** An unsupported construct records an error and
  `encode` raises `EncodeError` listing every site; it never emits a placeholder
  the caller could mistake for a faithful encoding. The round-trip is the proof
  of correctness: `native python == encode -> compile -> run`.

## Construct coverage

Supported: module-level scripts and `def main()`; free functions (0/1/2+ params)
and calls; nested `def`s + `lambda` (read-only closure capture); arithmetic /
bitwise / comparison / boolean-logic operators; `if`/`elif`/`else`; `while`;
`for` over `range(...)` (1-3 args, constant step — ascending or descending) and
over a list/iterable;
`break`/`continue`/`return`; list literals and indexing (`x[i]`); local
assignment (`=`, `+=`-family, `x: T = v`); `print` (0/1/N args, space-joined);
f-strings (plain `{expr}`); `len`/`str`/`int`/`float`/`abs`; the ternary
`a if c else b`.

Deferred (all fail loud): classes/`self`/methods (any `obj.method(...)` call),
decorators, `async`/`await`, `import`-qualified use, comprehensions, generators,
`with`/`try`/`raise`/`assert`, `in`/`not in`, slices, tuple/list unpacking and
multi-target parallel assignment, `*args`/`**kwargs`/keyword-only params and
keyword call args, dict/set/tuple literals, starred elements, f-string
conversions/format-specs.

## Known semantic boundaries (not bugs)

- **Boolean stringification.** `print(True)` yields Python `True`, but Ball's
  shared runtime stringifies booleans as Dart's `true`/`false` (the whole
  conformance corpus depends on this). Round-trip programs therefore avoid
  printing raw booleans. This is a deliberate cross-language semantic, not an
  encoder gap.
- **`//` on negatives.** Python `//` floors; Ball's `divide` truncates toward
  zero (Dart `~/`). Identical for non-negative operands; differs in sign only.
- **`%` on negatives.** Python `%` follows the divisor's sign; Ball's `modulo` is
  always non-negative (Dart). Identical for non-negative operands.
- **Reading a conditionally-unassigned local.** Because every local is hoisted to
  `null`, reading a name that Python would consider unbound on the taken path
  yields `null` where native Python raises `UnboundLocalError`. This only diverges
  for programs that are *already* erroneous in Python (a read before any
  assignment reaches it); a correct program assigns before it reads.
- **Loop-variable value after the loop.** The general case above, specialised to
  a `for` variable read after the loop (both leak, but not the same value): a
  `range` loop lowers to a C-style counter, so the variable holds the **terminal
  counter** that failed the test (e.g. `3` after `for i in range(3)`, vs Python's
  last yielded `2`); a `for_in` loop's variable is loop-scoped and does not
  escape, so it reads back as its hoisted `null`.

## Status (Phase 3)

Encoder complete for the surface above; **9 round-trip programs** verified three
ways (native Python == encode -> compile(`python/compiler`) -> run == golden):
`hello_world`, `arithmetic`, `control_flow`, `list_loop`, `fizzbuzz`,
`recursion`, `closures`, `strings`, `descending_range`. No engine/CLI-beyond-
encode and no CI wiring (later phases). Verify maturity against tests, not this
prose.
