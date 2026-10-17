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

- **A `try`'s clause list is a DISPATCH CHAIN (issue #724).** `run_catch_clauses`
  walks `catches` in source order and emits
  `if`/`elif ballrt.catch_matches(_ex.value, "<Type>")` for each typed
  `on T catch`, the first untyped `catch (e)` as the unconditional `else`, and —
  when every clause is typed and none matches — a trailing `else: raise _ex`, so
  the ORIGINAL value reaches an enclosing `try` (the reference engine's
  `if (!caught) rethrow`). Compiling `catches[0]` as an unconditional catch-all
  was silently-wrong output, and the `python-engine` row cannot see it: that row
  runs the self-hosted ENGINE, whose own catch dispatch is Ball code. The guards
  are `tests/test_catch_clause_dispatch.py` and the
  `464_typed_catch_clause_dispatch` / `473_caught_user_thrown_builtin_error`
  entries in `tests/test_conformance.py`.

- **Fail loud (issue #55).** An unsupported base function, an unresolvable
  reference, an unknown call target, or an unsupported pattern is a
  `CompileError` — never silently-wrong code. A silently-wrong output is a bug,
  not a gap.

- **Every hardcoded dispatch name must be DECLARED (issue #743).** Base
  functions are implemented here by name (`fn == "sink_write"`, `fn in table_2`),
  and until #743 nothing compared those names against the canonical builders. So
  the `str_1` table grew a `string_from_char_codes` (plural) arm that no
  `dart/shared/lib/std*.dart` builder declares, no encoder in the repo emits and
  the Dart reference engine does not dispatch — unreachable in both directions,
  and therefore invisible to this suite, to the conformance corpus and to
  `check_encoder_completeness.dart` alike. It is the #505 class, and it was
  DELETED rather than declared: the only real thing with that spelling is Dart's
  SDK static `String.fromCharCodes`, which `_BUILTIN_STATIC` already serves (a
  Dart-SDK surface, not a `std` base-function surface — the two must not be
  conflated). `tests/test_declared_base_functions.py` is the guard, the Python
  sibling of `dart/shared/test/std_routed_declarations_test.dart` (#505) and
  `cpp/test/check_declared_base_functions.py` (#607): it AST-parses this file,
  derives the dispatcher set from the source, and fails on any name neither
  declared in `tests/conformance/std_coverage.json` for a module that dispatcher
  serves nor a still-live entry in the frozen, ratchet-only
  `tests/declared_base_functions_known_gaps.txt`. A new undeclared name can never
  be added to that file — it exists only to freeze the six pre-existing,
  cross-target spellings (`for_each`, `parenthesized`, `null_aware_index`, …),
  and it can only shrink.

## Status (Phases 2 + 4)

The compiler passes **95 tests** and — via **`compile_library` mode** (the
Ball -> Python analog of Go's `CompileLibrary`) — compiles the whole self-hosted
engine (`dart/self_host/engine.ball.json`), which runs the conformance corpus at
**Dart parity** (`Results: 330 passed, 0 failed`; see `../engine/AGENTS.md`).
Coverage spans arithmetic (Dart-exact `~/`, non-negative `%`, int/double, 64-bit
wrap), comparison/logic (short-circuit), strings, control flow, recursion,
closures, and OOP (constructors incl. **named + optional params**, methods,
`@property` getters/setters, `toString`, inheritance, top-level `const`s).

That list describes what the *engine* program exercises. It is **not** whole-corpus
coverage: the compile leg below shows `super`, static methods, factory
constructors, mixins, enum-value references, switch patterns, generators and
a **labeled LOOP's** break/continue (`outer: for (...) { break outer; }`) are all
still open on the fixture corpus (`run_labeled`'s `_labeled_body_is_loop` guard
fails loud on that shape rather than guessing — see its docstring). A labeled
**plain** block/statement — no loop of its own, just catching a break that names
it — IS supported (issue #824 follow-up): it is the shape `python/encoder`'s
`_encode_switch_case_body` synthesizes when a switch case's unlabeled `break`
needs to be told apart from a bare `continue` that must still reach whatever
loop actually encloses the switch (a `continue` can never legally target a
non-loop label, so the trap `run_labeled` compiles never needs to catch one).
The named-constructor gap
(`Class.name(args)` -> a spurious `unresolved reference 'Countdown'`) was **fixed**
in [#527](https://github.com/Ball-Lang/ball/issues/527): `value_call`'s dispatch was
already correct, but it eagerly compiled the raw `self` field through
`reference()`'s fail-loud path before checking whether the class-static branch —
which never uses that value — would fire, so `compile()` raised `CompileError` over
otherwise-correct generated code. The receiver expression is now compiled **lazily**,
only inside the branches that use it, and `_lower_init` lowers a plain string literal
so a constructor's `metadata.initializers` survive a constructor that also has a body.
Fixtures `436_recursive_ctor_named` and `438_ctor_initializer_list_with_body` are in
`tests/test_conformance.py`'s golden-exact `PROVEN` list, which runs on every PR.

### Measured against the whole corpus (compile leg)

`python -m conformance.runner` sweeps every executable fixture through the
compiler, and (since #823/#824) prints a dedicated
`SILENTLY-WRONG (status=fail, N): <names>` line naming every `fail`-status
fixture — grep that line for the live, honest roster rather than trusting this
prose, which goes stale the moment a fixture moves. Measured, not asserted
(and re-measured with #724, then with #824/#892):

```
Results: 276 passed, 88 failed, 364 total (4 skipped carve-outs)
```

The pytest cases are a curated *proof set*; this is the honest corpus number, and
`PYTHON_COMPILER_FLOOR` in `conformance-matrix.yml` is where it is enforced.
A fixture the compiler cannot emit counts as a **failure**, not a skip — only the
4 golden-less resource-limit/sandbox carve-outs are skipped. The failures break
down as **`compile-error`** (loud, correct behaviour for a scope gap), **`error`**
(emitted Python that crashes at runtime — a real bug: the compiler emitted code it
should have refused), and **`fail`** — exit 0, wrong answer.

**A `fail`-status fixture violates issue #55** and is the priority.
`PYTHON_SILENTLY_WRONG_KNOWN` in `conformance-matrix.yml`'s `python-compiler` job
is the CLOSED SET of the ones still open — exact set equality, in both
directions, so neither a fix landing without updating that list nor a NEW
silently-wrong fixture appearing can hide inside the aggregate
`PYTHON_COMPILER_FLOOR` ratchet (which folds `compile-error`/`error`/`fail`
together, so a fixture moving FROM one of the first two INTO `fail` leaves
`passed`/`failed` both unchanged — issue #824's own finding). #824 closed 5 of
the original 8 — `112_named_constructors` (a named constructor's initializer
list reading an INDEXED expression off its own parameter, `coords[0]`, matched
none of `_lower_init`'s recognised shapes and silently defaulted to `None`),
`150_state_machine` (a `switch` inside a loop: its `if`/`elif` lowering has no
native break-scope of its own, so each case's unconditional `std.break` ->
`ballrt.brk("")` escaped straight into the ENCLOSING LOOP's own break trap and
ended the whole loop after the first character — every other target compiles
`std.switch` to a host-native `switch`, where a bare `break` already means
"end the switch" for free), `167_generics_reified`/`180_generic_list_ops`/
`181_generic_map_ops` (`ballrt.is_type` stripped a generic type ARGUMENT
entirely and matched on the bare base type alone, so `[1,2,3] is List<String>`
and `Box<int>(...) is Box<String>` both answered `true`; `is_type` now checks
every List/Map/Set element/entry recursively and a user object's own reified
`__type_args__` tag, mirroring the reference engine's `_typeMatches`) — all
five are now in `tests/test_conformance.py`'s `PROVEN` list.

The SAME PR that measured 276 additionally closed three more (#892's own set):
`432_shadowed_getter_setter_write` and `470_setter_beside_final_field` (a
subclass's own PLAIN field must shadow BOTH an ancestor's explicit getter and
setter; Python's attribute protocol always prefers a data descriptor found
anywhere in the instance's MRO over the subclass's own `__dict__` entry, so
`self.x = 5` in the subclass's `__init__` silently ran the ancestor's SCALING
setter instead of storing a plain field — `_shadow_backed_fields` now
synthesizes a trivial `@property`/`@x.setter` pair in the subclass itself over
a private backing attribute, mirroring `_setter_backed_fields`'s answer to the
sibling one-namespace collision, #695/#680's C++ precedent) and
`479_user_member_named_like_collection_accessor` (`ballrt.getfield`'s
`"runtimeType"` shortcut fired unconditionally, even on a receiver class that
declares its own `@override Type get runtimeType => ...`; it now defers to that
override first — the Python runtime's own instance of #787's family).

**Two remain, named in `PYTHON_SILENTLY_WRONG_KNOWN`:** `203_closure_in_loop` /
`229_closure_loop_var_semantics` (a C-style-`for` loop var is captured by Python's
late-binding closure, so every closure sees the final value: prints `12 12 12`,
golden `10 11 12` — the per-iteration snapshot the compiler does for `for-in` is
missing for C-`for`). Do not describe this compiler as "no silent-wrong
output" until `PYTHON_SILENTLY_WRONG_KNOWN` is empty. Tracking issue for
these 2: [#892](https://github.com/Ball-Lang/ball/issues/892).
`146_nested_try_catch_types` was on this list until #724: it printed the FIRST
catch clause's body whatever was thrown.

Load-bearing engine-mode decisions (all needed to reach parity): implicit-`self`
method calls, **named messageCreation fields → Python keyword args** (else return
values are dropped), the proto oneof-case `arm` enums + `__no_init__` sentinel,
`is`/`as` + Dart-SDK method routing through `ballrt`, and **per-iteration for-in
closure capture** (loop variables snapshotted as default args, since Python
shares a loop variable where Dart binds a fresh one each iteration). A rarely-
reached builtin static / stub-module call is a loud runtime raise (not a compile
error) so the library still compiles.
