---
paths:
  - "python/**"
---

# Python-Specific Instructions

Python (epic #445) is a **complete pipeline** — compiler, encoder, self-hosted engine, and the
`ball` CLI (`run`/`compile`/`encode`/`check`, plus the self-hosted cli-core verbs
`info`/`validate`/`tree`/`version`, #570) are all in place and tested. The
self-hosted engine runs the whole conformance corpus at **Dart parity** (`Results: 363 passed,
0 failed, 363 total (4 skipped carve-outs)`; the 4 golden-less resource-limit/sandbox fixtures are
documented carve-outs). Always verify maturity against CI (`.github/workflows/ci.yml`'s `python`
job — compiler/encoder/CLI pytest + `compileall` plus the regenerate-then-run self-hosted engine
conformance sweep — and the `python-engine` row in `conformance-matrix.yml`) and `python/AGENTS.md`,
not stale prose.

## Build System

- Native `python` works **on Windows** in this dev environment — no WSL needed (like Go, unlike
  Rust/C++). CI pins `python-version: "3.13"` via `actions/setup-python`; every
  `python/*/pyproject.toml` declares `requires-python = ">=3.11"` (the floor). This is the same
  "manifest declares the floor, CI runs the latest line" split the go job uses.
- **Five isolated packages, no workspace manager** — `runtime`, `shared`, `compiler`, `encoder`,
  `engine`, `cli` each have their own `pyproject.toml` and no shared virtualenv. Each test suite's
  `tests/conftest.py` bootstraps its sibling sources onto `sys.path` (the repo's
  isolated-package convention), so run `pytest` **from each package's own dir**:

```bash
cd python/compiler && python -m pytest -q     # 95 tests
cd python/encoder  && python -m pytest -q     # 42 tests
cd python/cli      && python -m pytest -q     # all four verbs, in-process
# Syntax gate (the Python analog of `go build`/`go vet`):
python -m compileall python/runtime/ballrt python/compiler/ball_compiler \
  python/encoder/ball_encoder python/engine/ball_engine python/cli/ball_cli python/shared/gen
```

- **The engine loader needs the `protobuf` runtime (>= 5.29).** The compiler and encoder walk the
  raw proto3-JSON dict view and have **zero** third-party deps, but `python/engine`'s loader
  (`ball_engine/loader.py`) materialises proto3 defaults through the generated binding
  (`python/shared/gen`, package `ball.v1`), which imports `google.protobuf`. `pip install
  "protobuf>=5.29"` before regenerating/running the engine or its conformance sweep. `ballrt` itself
  stays stdlib-only, so a *compiled program* still runs offline.

## Package Structure

- `python/runtime` (package `ballrt`) — the zero-dependency runtime value model (native
  `int`/`float`/`str`/`bool`/`list`/`dict`, insertion-ordered `BallSet`, `BallValue`/`BallMap` base
  classes the self-hosted engine's `BallObject` extends) + Dart-exact base ops (`ops.py`) +
  `break`/`continue`/`return`/`throw` flow-signal **exceptions** (`flow.py`) + `ball_proto` access
  patterns (`proto.py`), Dart-SDK method dispatch (`methods.py`, via `call_method`),
  `std_collections`/set (`collections.py`), `std_convert` (`convert.py`), the is/as class registry +
  builtin statics (`selfhost.py`), typed Dart exceptions (`dart_errors.py`), and console output +
  the entry-point driver (`io.py`). **Zero external dependencies** (Python stdlib only). See
  `runtime/AGENTS.md`.
- `python/shared` (package `ball.v1`, under `gen/`) — generated Python protobuf bindings
  (`buf generate`, plugin `buf.build/protocolbuffers/python`); requires `google.protobuf`. Never
  hand-edit.
- `python/compiler` — Ball → Python. Emits Python source as strings (like the C++/Rust/Go compilers,
  not Dart's `code_builder`). Two modes: `compile` (a runnable script whose `if __name__ ==
  "__main__"` block calls `ballrt.run_entry(entry)`) and `compile_library` (a flat library of
  classes/dispatchers/free-functions — no entry driver — for the self-hosted engine). Base-function
  dispatch is `base_call`; `typeDefs[]` emission is `type_emit`. `ballpyc` (`python -m
  ball_compiler`) is the front-end.
- `python/encoder` — Python → Ball via the stdlib `ast`. Routes every construct through universal
  `std`/`std_collections` — **no `python_std` base module**, ever (the Rust/Go encoders' "no
  <lang>_std" invariant). `ballpyenc` (`python -m ball_encoder`) is the front-end. Test-only reliance
  on the compiler for the round-trip proof.
- `python/engine` — self-hosted engine wrapper (`loader.py`/`driver.py` + `ball_engine/__main__.py`)
  driving the generated, gitignored `ball_engine/compiled_engine.py`. `ball_engine/regen.py`
  regenerates it; `conformance/runner.py` is the whole-corpus sweep. See `python/engine/AGENTS.md`.
- `python/cli` (package `ball_cli`, `python -m ball_cli` / `ball`) — the `ball` CLI:
  `run`/`compile`/`encode`/`check` over engine/compiler/encoder plus the self-hosted cli-core verbs
  `info`/`validate`/`tree`/`version` (#570) (the Python sibling of `rust/cli`/`csharp/cli`/`go/cli`;
  no package-registry commands, no `audit`). All logic is in `ball_cli.run` so tests exercise every
  verb in-process. `run` needs the gitignored `compiled_engine.py` — an honest exit-1 + regenerate
  hint when absent, never a silent success. The cli-core verbs resolve the same way through
  `ball_cli/cli_core.py`: the generated `compiled_cli.py`, else `bootstrap_clicore.load_cli_core()`
  (compile-on-first-use into the `clicore` cache subdirectory), else the same honest exit-1 — Python
  has no build tag, so AVAILABILITY is the gate. `ball_cli/__main__.py` forces UTF-8 stdout/stderr
  so a cp1252 Windows console does not raise `UnicodeEncodeError` on non-ASCII `run` output. See
  `python/cli/AGENTS.md`.

## Key Patterns

### Compiler

- Every Ball expression compiles to a Python expression evaluating to a `ballrt` value (uniform).
  Python has no block/if/loop **expressions**, so statement-bearing constructs are wrapped as the
  compiler needs (native `if`/`for`/`while` control flow evaluated **lazily**, invariant #4).
- All 7 expression node types are handled; the reference name `"input"` is the function parameter
  (invariant #1). `return`/`break`/`continue`/`throw` are `ballrt` flow-signal **exceptions** (Python
  has no goto), caught by the emitted loop/function scaffolding.
- **Fail-loud (issue #55):** an unsupported base function / expression shape is a `CompileError`,
  never silent bad code.
- **`run_switch`'s empty-body/fall-through test is statement mode only.** Ball encodes `null` as a
  value-less `Literal` (`{"literal": {}}`) — exactly the shape `is_empty_switch_body` reads as
  "empty" — so applying it to a `switch_expr` (where nothing falls through and every arm carries a
  value) deletes every `=> null` arm and leaks its condition into the next one: compiles, exits 0,
  wrong answer. Gate it on the already-computed `expr_mode` (issue #470; same defect family as
  `rust/compiler`, same gate as `go/compiler/base_call.go:514-522`).

- **`std_collections.list_find` THROWS when nothing matches (#597).** It is Dart's
  `Iterable.firstWhere` WITHOUT `orElse` — what its own declaration in
  `dart/shared/lib/std_collections.dart` says ("Find first:
  list.firstWhere(callback)") and what the Dart reference engine does
  (`engine_std.dart`: `throw StateError('No element')`). Never a `null`/
  `undefined`/empty placeholder, and never an untyped throw: the thrown value
  must carry the type name `StateError` so the program's own `on StateError
  catch` sees it. `tests/conformance/463_list_find_no_match` is the cross-target
  guard; `python/runtime/ballrt/collections.py`'s `list_find` (a `StateError` payload carried by `BallThrow`) and the `463_list_find_no_match` entry in `python/compiler/tests/test_conformance.py` is this target's half. See `docs/TESTING_STRATEGY.md` §5b.

- **The declared text sink `std.sink_create` / `sink_write` / `sink_to_string`
  (#630).** A sink is a **`__type__`-tagged, REFERENCE-semantic value** carrying
  its accumulated text under `__buffer__` — never a bare host builder. Two
  properties are normative on every target and both fail SILENTLY when a target
  gets them wrong: `std.type_of(sink)` must answer `"Sink"` (a host builder
  answers its own type name, so a program branching on `type_of` takes a
  different arm per target), and an append performed inside a CALLEE must be
  visible to the caller (a by-value backing loses exactly that append — the
  shape of issue #300). `writeln` desugars to `sink_write` + `"\n"`,
  `writeCharCode` to `sink_write` + `string_from_char_code`, and
  `.length`/`.isEmpty`/`.isNotEmpty` to the existing string ops over
  `sink_to_string`, so three declarations are the whole abstraction. Guards:
  `tests/conformance/466_string_sink` (its `appendWord(out, 'c')` line is the
  reference-semantics leg) plus this target's own tag test — `python/compiler/tests/test_sink.py`, plus the `466_string_sink` entry in `python/compiler/tests/test_conformance.py`'s `PROVEN` list (compile + run + golden diff).
  Backing: `ballrt.sink_create`/`sink_write`/`sink_to_string` (`python/runtime/ballrt/sink.py`), over a plain `dict` — a reference, and the shape `ballrt.type_of` already reads a `__type__` tag from. An `io.StringIO` would answer `StringIO`.
- **Every Dart `StateError` site goes through `ballrt.flow.state_error` (#616).**
  `list_first`/`list_last`/`list_pop` and the `.first`/`.last` field getters used
  to let Python's NATIVE `IndexError` escape — not a `BallThrow` at all, so the
  compiled `try`'s `except ballrt.BallThrow` never saw it and the program died
  instead of catching; `methods.py`'s `_reduce`/`_first_where` threw a bare
  STRING (right text, no type). The payload is `selfhost.StateError`, whose
  `toString` already spells Dart's `Bad state: <message>`.
  `python/compiler/tests/test_runtime.py`'s
  `test_state_error_sites_are_typed_and_stringify_like_dart` is this target's
  half. See `docs/TESTING_STRATEGY.md` §5b.

- **A caught `TypeError` reads as Dart's own message, and the rendering table is
  CLOSED by a test (#641).** A failed cast pattern raises `TypeError`, and Dart
  spells it
  `type '<runtime type>' is not a subtype of type '<target>' in type cast` —
  naming the VALUE's type first, and with **no** `TypeError: ` prefix, because
  `_TypeError.toString()` IS its message (the odd one out of the four built-ins).
  Every target used to spell `type cast failed: not a <T>` and then render it a
  different way; the canonical form is real Dart's because
  `generate_conformance.dart` builds a golden by RUNNING the fixture's Dart
  source on the SDK. Python raises no `TypeError` (its compiler fails loud on a cast
  pattern), so `dart_errors.py` deliberately has no class for it — a future site
  must add one whose `toString` is the MESSAGE ALONE, never the base classes'
  generic `<Type>: <message>`. `python/compiler/tests/test_runtime.py` pins the
  three renderings this runtime does produce.
  `tests/conformance/467_caught_type_error_to_string` is the cross-target guard,
  and `tools/check_error_rendering_tables.py` (`Proto Checks`, every PR, with its
  own self-test) is the structural one: it asserts every Dart error name this
  runtime RAISES has an entry in this runtime's table and that every entry's
  prefix equals Dart's. Add a new built-in error here and to that contract in the
  same PR, or the checker fails.

- **A USER-thrown built-in error reads the same on every target, and the table
  is closed on the LITERAL-throw side too (#658).** #641's three checks are all
  keyed on what a runtime RAISES, and that left the commoner path unwatched: a
  program's own `throw StateError('boom')` is built by the COMPILER, not raised
  by any runtime, so nothing observed it. The consequences were target-specific
  and all silent — the Dart REFERENCE engine printed the bare ctor argument
  (`boom`, not `Bad state: boom`), and `ArgumentError`, which Dart spells
  `Invalid argument(s): <message>` and no runtime in the repo raises, was in NO
  target's rendering table at all. `LITERAL_THROWABLE` in
  `tools/check_error_rendering_tables.py` is the new structural half (every
  explicit table must cover `StateError`/`FormatException`/`RangeError`/
  `ArgumentError`, raised or not), and
  `tests/conformance/473_caught_user_thrown_builtin_error` is the observable one:
  untyped catch, typed `on T catch`, a non-matching typed clause that falls
  through, and `.message` read alongside `'$e'` — DIFFERENT strings, so storing
  the prefixed form passes one half and breaks the other.
  This target needed the most: only `StateError` had a `ballrt` factory, so
  `throw FormatException('bad')` compiled to an anonymous dict - it printed as
  `{arg0: bad}` and `.message` read `null`. `_BUILTIN_DART_ERROR_CTORS`
  (`python/compiler/ball_compiler/compiler.py`) maps all four to the real
  classes, and `ArgumentError.toString` now spells Dart's
  `Invalid argument(s)`. The class is ALSO the prerequisite for telling one
  built-in error from another, which #724 (below) then acts on.

- **A typed `on T catch` clause is a TYPE TEST, and the clause list is a
  dispatch chain (#724).** `run_try` used to compile `catches[0]` alone, as an
  unconditional catch-all with its `type` ignored, dropping every later clause —
  the Python instance of the defect #615 closed for Rust/C#/Go.
  `run_catch_clauses` (`python/compiler/ball_compiler/compiler.py`) now walks
  the list in SOURCE ORDER and emits `if`/`elif ballrt.catch_matches(_ex.value,
  "<Type>")`, with the first untyped `catch (e)` as the unconditional `else`
  fallback and, when every clause is typed and none matches, a trailing `else:
  raise _ex` so an enclosing `try` sees the ORIGINAL value (the reference
  engine's `if (!caught) rethrow`). The `ballrt.flow._caught` push/pop still
  wraps the whole chain, so `rethrow` works and unwinds on the re-raise path
  too. The matching RULE is `ballrt.catch_matches` /
  `ballrt.exception_type_name` (`python/runtime/ballrt/flow.py`), the sibling of
  Go's `ballrt.CatchMatches` and Rust's `ball_catch_matches`: a `__type__`-tagged
  map reports its tag, an exception object reports its class name, anything
  untagged reports `std.throw`'s own default `Exception`, and a module-qualified
  tag (`main:StateError`) also matches a clause naming the bare type. The
  `python-engine` row cannot see any of this — it runs the SELF-HOSTED engine,
  whose catch dispatch is Ball code (`_evalLazyTry`) — so the guards are
  `python/compiler/tests/test_catch_clause_dispatch.py` plus the
  `464_typed_catch_clause_dispatch` / `473_caught_user_thrown_builtin_error`
  entries in `test_conformance.py`'s `PROVEN` list, which COMPILE the fixtures
  through this compiler and diff their goldens.

- **A `final` field declared next to a same-named SETTER gets a synthesized property (#706).**
  That pair is legal Dart exactly because a plain `final` field contributes a getter and NOTHING
  else, so the declared setter is the only setter for the name (`collection`'s `ListSlice` is the
  real-world shape). Python has ONE namespace for a field and a property: a bare
  `@windowSize.setter` has no property object to decorate, so `emit_class` refused the program
  ("setter without matching getter"). Honest — never a silent wrong answer, unlike the Rust/Go/C#
  half of the same issue — but still a program this target could not run that every self-hosted
  engine runs fine. `_setter_backed_fields` is the lowering, and it is the C++ compiler's
  backing-member answer to the same one-namespace collision (#695, closed by #680): the field
  moves to `self._ball_backing_<name>` and a synthesized `@property` reads it, emitted BEFORE the
  member loop so the declared setter has a property to attach to. Every `__init__`/named-factory
  assignment routes through `_field_target`, because `self.windowSize = end` would run the
  declared setter — which for this shape throws. Scoped to `final` fields on purpose: a NON-final
  field contributes a setter of its own, so a same-named declared setter is a duplicate definition
  Dart rejects, and anything else with a setter and no getter keeps failing loud. Guards:
  `python/compiler/tests/test_final_field_setter.py` (including the negative control) and fixture
  `472_initializer_list_field_with_setter` in `test_conformance.py`'s `PROVEN` list.

- **Every hardcoded base-function dispatch name must be DECLARED, and a gate says so (#743).**
  Base functions are implemented here by name (`fn == "sink_write"`, `fn in table_2`,
  `str_1[fn]`), and nothing used to compare those names against the canonical builders. The `str_1`
  table grew a `string_from_char_codes` (PLURAL) arm that no `dart/shared/lib/std*.dart` builder
  declares, no encoder in the repo emits and the Dart reference engine does not dispatch —
  unreachable in both directions, so neither `python/compiler`'s suite nor the conformance corpus
  nor `check_encoder_completeness.dart` could ever see it, and #702's reverse closed set could not
  either (its three populations are the Dart engine's dispatch map, the capability table and the
  fixture corpus — a name only the Python compiler mentions is in none of them). It was DELETED,
  not declared: the only real thing with that spelling is Dart's SDK static
  `String.fromCharCodes`, which the compiler's `_BUILTIN_STATIC` table already serves. Never
  conflate the two surfaces — `_BUILTIN_STATIC` maps Dart-SDK statics (`int.tryParse`,
  `List.filled`, `String.fromCharCodes`) reached through `builtin_static`, while the `base_expr`
  tables implement DECLARED `std` base functions. `python/compiler/tests/test_declared_base_functions.py`
  is the guard (the Python sibling of #505's `std_routed_declarations_test.dart` and #607's
  `cpp/test/check_declared_base_functions.py`): it AST-parses `compiler.py`, derives the dispatcher
  set from the source, and fails on any name neither declared in
  `tests/conformance/std_coverage.json` for a module that dispatcher serves nor a still-live entry
  in the frozen, ratchet-only `declared_base_functions_known_gaps.txt`. That file is NOT a place to
  put a new name — it freezes the six measured, cross-target spellings (`for_each`,
  `parenthesized`, `null_aware_index`, `set_create`, the `*_than_or_equal` pair) and can only
  shrink.

### Encoder

- `encode(source)` parses Python with the stdlib `ast` and walks declarations → statements →
  expressions. **One input, one output** (invariant #1): a 0-param func takes no input; a 1-param
  func keeps its parameter name; a 2+-param call packs args into one anonymous message keyed by the
  callee's parameter names (read back by the compiler).
- **Fail-loud:** an unsupported construct raises `EncodeError`, never a placeholder. The round-trip
  test is the proof: Python → Ball → (compile with `python/compiler` + run) ≡ running the original
  Python natively.
- **A module-level variable is a DECLARATION, not a local of the synthesised `main` (#721).**
  `__version__ = "1.0"` is part of a module's public surface; folding it into `main` loses it while
  the encoder reports success (`packaging/__init__.py` lost all 8 of its `__dunder__`
  declarations that way). It is encoded as a 0-parameter function tagged
  `metadata.kind = "top_level_variable"` — the shape every Ball compiler already emits back as a
  module-level assignment. Lifting is only sound when it cannot REORDER an observable effect, so
  `_lifted_top_level_vars` requires all four of: one plain-name target; that name bound exactly once
  at module scope (a re-assigned/augmented/guard-rebound name is not one declaration); every
  module-level statement before it merely declaring (import, docstring, `def`/`class`, or another
  lifted assignment); and every name its initializer reads being a lifted variable or a `def`
  already seen above it, or the `ballrt` alias. Anything else keeps the old encoding, which is the
  right answer for a script. `python/encoder/tests/test_top_level_vars.py` pins each condition with
  its negative control. The compiler's matching half is the `top_var_names` branch in `value_call`:
  a top-level variable can hold a function, and `add10(5)` must apply it.

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++/Rust/C#/Go: compile
  `dart/self_host/engine.ball.json` through `python/compiler` (**library mode**) into
  `ball_engine/compiled_engine.py`.
- **Status: complete, runs at Dart parity** — `Results: 363 passed, 0 failed, 363 total (4 skipped
  carve-outs)`, matching Dart byte-for-byte.
- **Fix compiled-engine behavior in `python/compiler` (a fix + regen) or `python/runtime` (no
  regen) — NEVER hand-edit `compiled_engine.py`.** Common `python/runtime` families: `ball_proto`
  access patterns (`proto.py`), the Dart-SDK method surface (`methods.py`, via `call_method`),
  `std_collections`/set (`collections.py`), `std_convert` (`convert.py`), the is/as class registry
  (`selfhost.py`). The parity grind's root-cause clusters are catalogued in
  `python/engine/AGENTS.md`.
- **`call_method` dispatches a receiver's OWN method before the `has<Field>` presence heuristic.**
  The heuristic (`name` starts with `has` + a capital ⇒ a protobuf presence probe) used to run
  first, so Dart's real `RegExp.hasMatch(s)` became a presence probe for a field named `match` and
  silently answered `False` — every regex path in the compiled engine (`std.string_matches`, the
  engine's own `^arg\d+$` constructor-argument test) was dead in Python while every other target
  ran it. Pinned by `python/compiler/tests/test_runtime.py`.
- **Per-fixture timeout is a subprocess kill, not cooperative** (contrast Go): each fixture runs as
  its own killable `python -m ball_engine` subprocess with `subprocess.run(timeout=…)`, so a runaway
  is simply killed — a Python process is trivially killable, sidestepping the goroutine-leak problem
  the Go runner works around cooperatively.

## The bytes-not-text golden-harness rule

Conformance goldens (`tests/conformance/*.expected_output.txt`) must be read as **bytes**, then
decoded and normalised **only** for `\r\n` → `\n` — never through Python's text-mode universal
newlines. `Path.read_text()` (universal newlines) collapses *every* newline flavour, including a
semantic lone `\r` a fixture legitimately prints (Dart `'\r'`), to `\n`, which silently masks a real
divergence. The harness helper is therefore:

```python
def read_golden(path: Path) -> str:
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")
```

(see `python/compiler/tests/conftest.py`). The conformance runner
(`python/engine/conformance/runner.py`) applies the same `.replace("\r\n", "\n").rstrip("\n")`
normalisation to both actual stdout and the golden. This is the Python analog of Go's "gofmt CRLF
gotcha" rule — a Windows checkout stores goldens CRLF, but the semantics live in the LF-normalised
bytes, not in text-mode line mapping.

## Regenerate the Self-Hosted Engine

```bash
cd dart && dart run compiler/tool/gen_engine_json.dart   # writes dart/self_host/engine.ball.json
cd ../python/engine && python -m ball_engine.regen       # -> ball_engine/compiled_engine.py
python -m conformance.runner                             # prints the CI-parseable `Results:` line
```

`regen.py` reads `dart/self_host/engine.ball.json` (gitignored) and compiles it through
`ball_compiler.compile_library`. `BALL_FIXTURE=<name>` runs one fixture with a full diff;
`BALL_TIMEOUT_S=<s>` sets the per-fixture kill budget; `BALL_WORKERS=<n>` sets parallelism.

## Packaging: one `ball-lang` wheel (issue #496)

- The five isolated packages are the DEVELOPMENT shape; the REDISTRIBUTABLE shape is a single
  combining distribution, `python/pyproject.toml` (`name = "ball-lang"`), bundling
  `python/{runtime,compiler,encoder,engine,cli}` plus the generated `ball.v1` binding into one wheel
  with a `ball` console script. Never add per-package publishing — one wheel is the owner's decision.
- **Nothing generated ships**, enforced by `python/setup.py`'s `build_py` filter (setuptools has no
  declarative per-module exclusion, and `packages = ["ball_engine", …]` otherwise sweeps in the
  gitignored `compiled_engine.py` whenever the tree has been regenerated). Never delete that hook;
  `wheel_smoke.py` asserts the wheel carries the bundled `.gz` and not the generated module, and
  wipes `python/build/` first so a stale build tree cannot leak it. The wheel carries the engine's
  Ball SOURCE
  (`ball_engine/_selfhost/engine.ball.json.gz`, a gitignored build artifact of
  `python/engine/tool/bundle_selfhost.py`), and `ball_engine/bootstrap.py` compiles it into a
  per-user cache dir on the first `ball run` (~0.25 s; `BALL_CACHE_DIR` overrides the location).
  `driver.compiled_engine()` still prefers a regenerated `compiled_engine.py`, so the checkout and
  CI paths are unchanged.
- **`ball.v1` must survive `buf generate proto`.** It is a PEP 420 implicit-namespace directory with
  no `__init__.py`; the combining pyproject lists `ball` / `ball.v1` explicitly with a `package-dir`
  mapping. **Never add an `__init__.py` under `python/shared/gen/`** — the next regen deletes it.
- The gate is `python python/tool/wheel_smoke.py` (PR-gated in ci.yml's `python` job): build the
  wheel, install it into a venv OUTSIDE the repo with no `PYTHONPATH`, and run `--version` / `check`
  / `compile` / `encode` / `run`, comparing `run`'s stdout to a conformance golden as BYTES. An
  in-tree venv would let `ball_cli.paths` find the checkout and mask a packaging defect.
- `ball --version` is a FLAG *and* `ball version` is a VERB, both on purpose (#570) — the same
  split Rust has (clap's built-in `--version` alongside a `version` subcommand). The flag prints the
  installed toolchain banner; the verb prints the PORTABLE `ball <version>` line `cli_core`
  computes. The flag is matched in `cli.py` before the subcommand table, so they never collide.
- The wheel ships the cli-core's Ball SOURCE too (`ball_cli/_clicore/cli_core.ball.json.gz`, from
  `python/cli/tool/bundle_cli_core.py`), never the generated `compiled_cli.py`;
  `ball_cli/bootstrap_clicore.py` compiles it into the `clicore` subdirectory of the shared cache
  root on first use. `python/setup.py`'s `build_py` filter excludes BOTH generated modules, and
  `wheel_smoke.py` asserts each artifact carries the source and not the generated module.
- Release: `.github/workflows/publish-pypi.yml`, tag-gated on `python-pypi/vX.Y.Z`, PyPI Trusted
  Publishing (OIDC, no token fallback). See `docs/RELEASE.md` and `python/AGENTS.md § Publishing`.

## Generated Files — NEVER Edit

- `python/shared/gen/**` — protobuf bindings (`buf generate proto`, plugin
  `buf.build/protocolbuffers/python`, root `buf.gen.yaml`).
- `python/engine/ball_engine/compiled_engine.py` — gitignored (~690 KB), regenerated via `python -m
  ball_engine.regen`. Absent from a fresh checkout; the pytest/compileall gates never need it (only
  the conformance runner, which regenerates it first, does).
- `python/engine/ball_engine/_selfhost/engine.ball.json.gz` — gitignored, written by
  `python/engine/tool/bundle_selfhost.py` from the (also gitignored)
  `dart/self_host/engine.ball.json`. Only the wheel build needs it.

## Testing

- **Third-party coverage study, Tier A (#493).** `tools/coverage-study/rq1_study_py.py`
  runs real pinned packages through `ball_encoder.encode` ->
  `ball_compiler.compile_library` -> `ball_encoder.encode`, diffs the declaration
  inventory with the **stdlib `ast` directly** (never `ball_encoder`'s own walk) and
  checks a second-generation fixpoint. Current measurement **0/70 clean**; 2 files
  encode, compile back, re-encode and keep every declaration, and the wall is stage
  5 — the compiler's `_input=None` prologue has no encoder inverse, so generation 2
  grows an `_input_N = _input` line (the top-level-class gap keeps the other 68 from
  encoding at all). **The denominator is decided from each file's SOURCE at stage 0**
  (`has_scorable_material`): a file leaves it only when it has neither a top-level
  declaration nor any top-level code — three of `pyparsing`'s `__init__.py` markers
  are zero-byte. Deciding that after the pipeline is issue #721: it made `scored` a
  function of the encoder, and #646 moved the row 73 -> 70 with no file changed. A
  file that HAS declarations and comes back with none is a scored FAILURE, never a
  skip. `python tools/coverage-study/test/
  rq1_study_py_self_test.py` (the harness's own self-test) IS gated on every PR in
  the `python` job, and both files are in the `compileall` syntax gate; the RUN is
  the `python-tier-a` job in `coverage-study.yml`, which has **no
  `pull_request:` trigger** (its row is floored by ratchet in that workflow's
  `publish` job). Methodology: `tests/conformance/COVERAGE_STUDY.md`.

- `python -m pytest -q` from each of `python/compiler`, `python/encoder`, `python/cli` runs the
  compiler golden-exact conformance + runtime unit tests, the encoder structural + round-trip tests,
  and the CLI's in-process verb tests (including `run`'s honest-failure path when
  `compiled_engine.py` is absent — so run the CLI suite **before** regenerating the engine, as CI
  does, to actually exercise it).
- Prefer extending the compiler/encoder tests or `tests/conformance/*.ball.json` over Python-only
  unit tests, per the repo-wide "prefer conformance tests" rule.
- `python/engine/conformance/runner.py` is the committed `tests/conformance/*.ball.json` runner — the
  `python-engine` sweep is what CI gates on; quote its `Results:` line, not a hand-maintained count.
- `python/engine/conformance/roundtrip.py` (`python -m conformance.roundtrip`, or
  `python -m python.engine.conformance.roundtrip` from the repo root) is a measurement
  sweep (#452 item 3): Ball → Python → Ball → the **Dart** reference engine → golden diff. Needs
  `dart` on PATH (or `BALL_DART`), not the compiled engine. **A timed-out fixture's whole process
  TREE is killed (#791)** — `dart run` forks the Dart VM, so `subprocess.run(timeout=…)`, which
  kills only the immediate process, left one orphaned VM per timed-out fixture in the runner;
  `_run_dart` spawns with `start_new_session=True` and `_kill_process_tree` calls `os.killpg`
  (`taskkill /T /F /PID` on Windows), with `tests/test_roundtrip_process_tree.py` as the negative
  control. It measured a flat **0/321** from the
  day it shipped until #642 — the encoder refused the compiler's own output outright: the
  `try:`/`except ballrt.BallReturn` wrapper the compiler put around EVERY function body (`ast`'s
  `Try` is an unsupported statement here), and every `ballrt.*` base-call helper. The compiler now
  emits that wrapper only when the body can actually raise (`compiler.py::emit_body`, a
  conservative textual test for `ballrt.ret(`), and `ball_encoder/ballrt_calls.py` is the inverse
  surface for the helpers; `tests/test_compiler_output.py` is the fast guard on both halves.
  **The inverse surface is closed against drift (#690).** `HELPERS` is the table (one `std` call
  over expression arguments); the shapes that are NOT that live beside it as named constants and
  are handled in `encode_ballrt_call` — `PASSTHROUGH` (`truthy`/`iterate`), `FIELD_GET`
  (`getfield` → a `fieldAccess` NODE, not a call), `FIELD_SET`/`INDEX_SET` (→ `std.assign` over the
  matching l-value), `TYPE_OPS` (`is_type`/`as_type` → `std.is`/`std.as` with the type NAME as a
  string field), `LABEL_OPS` (`brk`/`cont` → `std.break`/`std.continue`; an EMPTY label means no
  `label` field at all) and `RETHROW` (input-less `std.rethrow`).
  **Three modules are NAMESPACED, not flat** (`ballrt.col.*` → `std_collections`,
  `ballrt.cvt.*` → `std_convert`, `ballrt.proto.*` → `ball_proto`). `encode_call` reads the
  two-level receiver and routes to `encode_ballrt_namespaced_call`; the helper is always spelled
  like the base function, so `COLLECTION_HELPERS`/`CONVERT_HELPERS`/`PROTO_HELPERS` record only the
  input FIELD per positional argument, closed by `tests/test_ballrt_namespaced.py` against each
  module's own Ball declaration (`dart/shared/lib/std_collections.dart`/`std_convert.dart`,
  `dart/shared/ball_proto.json`) — membership AND field names, because the compiler accepts several
  spellings per field and `list_find` declares `callback`, not `value`. `set_create` is the one
  namespaced shape that leaves its module (it is `std.set_create {elements}`, what `dart/encoder`
  emits and the reference engine runs; a literal `None` argument is the compiler's own "no
  elements" token, so it reads back INPUT-LESS).
  **`.add` on a SET routes through `std_collections.list_push`** (the syntactic Dart encoder cannot
  see the receiver type, #68), so `ballrt.col.list_push` needs a `BallSet` arm like
  `list_concat` already had; without it a compiled program died with Python's native
  `AttributeError`, which no compiled `try` can catch. Nothing else could see it — the
  `python-engine` row runs the self-hosted engine (its set handling is compiled Ball) and the
  `python-roundtrip` row runs on the DART engine — so the set fixtures are in
  `python/compiler/tests/test_conformance.py`'s `PROVEN` list, the only leg that compiles a
  conformance fixture to Python and runs it.
  **The STATEMENT lowerings are shaped, not named.** A compiled Python `try:` is one of FOUR
  things and only one is a Ball `std.try`: the loop-body `except ballrt.BallBreak`/`BallContinue`
  trap, the `except ballrt.BallReturn` function-body wrapper, that wrapper's value-less
  constructor form, and `run_try`'s `except ballrt.BallThrow` + `ballrt.flow._caught` push/pop.
  `encoder.encode_try`/`encode_while` recognise them; `ballrt_calls.py` holds only the class names
  they match on (`FLOW_BREAK`/`FLOW_CONTINUE`/`FLOW_RETURN`/`FLOW_THROW`, `FLOW_MODULE` +
  `CAUGHT_STACK`, `STACK_TRACE_OF`, `CATCH_MATCHES`), closed against `python/runtime` by its own
  test. Since #724 the `std.try` shape's handler may hold a typed DISPATCH CHAIN
  (`if`/`elif ballrt.catch_matches(_ex.value, "<Type>")`, the untyped clause as `else`, a trailing
  `raise _ex` when every clause is typed): `_encode_catch` reads it back as the whole multi-clause
  `catches` list, and the `raise` arm encodes to NO clause — it is `std.try`'s own propagate, and an
  extra untyped clause there would turn a program that propagates into one that swallows. A compiler
  change that alters this shape without its inverse does not fail loudly on the `python` job; it
  shows up as a DROP on the ratcheted `python-roundtrip` row, so land the pair together.
  **Never inline a loop trap on sight.** The compiler's C-style `for` is `while True:` + exit guard
  + trap + UPDATE, and `except ballrt.BallContinue` falls *through* to UPDATE, so the whole
  `while True:` shape reads back as `std.for {condition, update, body}` (no UPDATE → `std.while`;
  trap-first with the guard last → `std.do_while`). Inlining it into a `std.while` whose body ends
  with UPDATE makes a loop that never advances — it **hangs** instead of raising, which is why the
  round-trip tests for this family run under a hard wall-clock bound and why a trap that is not its
  block's last statement fails loud. `tests/test_ballrt_inverse.py` derives the required set from `dart/shared/std.json`
  (every `UnaryInput` base function) crossed with `python/runtime`'s public helpers, so a new
  same-spelled unary base function fails on the day it lands instead of becoming another
  `unsupported runtime helper` on a measurement row nobody reads.
  **The FIELD NAMES are closed against std.json's `typeDefs` too.** Every engine reads a base
  call's input message BY NAME, so a name the function's `inputType` does not declare yields a
  program the REFERENCE engine mis-runs: `dart/engine`'s `_extractBinaryArgs` reads `left`/`right`
  STRICTLY and throws otherwise, and `math_clamp` mapped to `("value", "lower", "upper")` silently
  answered the lower bound (`15.clamp(0, 10)` → 0). Seven entries were wrong this way while every
  Python-side round-trip test passed, because `python/compiler` accepts several spellings per field
  (`a('lower', 'lowerLimit', 'min', 'low')`) — re-running the table's output on Python checks it
  against the one reader that cannot tell the difference, which is why the guard reads the
  DECLARATION instead. A helper lives in exactly one
  half, and one with no exact inverse still fails loud — never guessed at. Its CI
  home is the `python-roundtrip` row in `conformance-matrix.yml`, which **is a PR gate since #619**
  and **floored + ratcheted since #642**: harness health PLUS `passed >= 1` PLUS
  `passed >= PYTHON_ROUNDTRIP_FLOOR`, enforced by `tools/ci/roundtrip_floor.sh`. Still NOT a parity
  gate — but a flat zero is red, and the floor only rises. **Raise it in the SAME PR as the fix
  that earned it**; the job prints the exact new value.
