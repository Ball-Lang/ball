---
paths:
  - "rust/**"
---

# Rust-Specific Instructions

Rust is a **full pipeline** — compiler, encoder, self-hosted engine, and CLI are all in place
and tested. The self-hosted engine runs the whole conformance corpus at **Dart parity**
(`Results: 363 passed, 0 failed, 363 total`; the 4 golden-less resource-limit/sandbox fixtures
are carve-outs skipped like the Dart runner — #39/#300 closed, #40/#41 landed). Always verify
maturity against CI (`.github/workflows/ci.yml`'s `rust` job — build/test/fmt/clippy plus the
self-host run-acceptance and full conformance sweep) and `rust/AGENTS.md`, not stale prose.

## Build System

- `cargo` is not on native Windows in this dev environment — run all `cargo` commands via WSL,
  e.g. `wsl.exe -e bash -lc "cd /mnt/d/packages/ball/rust && cargo build --workspace"`.
- `rust-toolchain.toml` (`rust/rust-toolchain.toml`) pins `channel = "stable"` with `rustfmt` +
  `clippy` components — a bare `cargo` inside `rust/` auto-selects it via `rustup`.
- Cargo workspace root is `rust/Cargo.toml` (`resolver = "3"`), members:
  `shared`, `compiler`, `encoder`, `macro-expand`, `engine`, `engine/tool`, `cli`, `cli/tool`,
  `tools/rq1-study`. Shared
  version/edition/license/dependency versions live in `[workspace.package]` /
  `[workspace.dependencies]` — member crates reference them with `{ workspace = true }`, never a
  repeated version string.

```bash
cd rust
cargo build --workspace
cargo test --workspace
cargo fmt --check && cargo clippy --workspace
```

## Package Structure

- `ball-lang-shared` (`rust/shared/`) — protobuf bindings (`prost`/`prost-reflect`, generated into
  `rust/shared/gen/`) + runtime value model (`BallValue`/`BallList`/`BallMap`/`BallFunction`/
  `BallMessage`, `rust/shared/src/value.rs`) + std/std_collections/std_io/std_memory module
  builders + `runtime::*` base-op helpers consumed by the compiler.
- `ball-lang-compiler` (`rust/compiler/`) — Ball → Rust compiler. `compile_expression` handles all 7
  expression node types; `base_call.rs` is the base-function dispatch table (delegates to
  `ball_lang_shared::runtime`); `lvalue.rs` handles assignment/mutation; `type_emit.rs` handles
  `typeDefs[]` → struct/trait/enum + multi-module output.
- `ball-lang-encoder` (`rust/encoder/`) — Rust → Ball via `syn` 2.x (`features = ["full",
  "extra-traits", "visit", "visit-mut"]`). Routes every construct through universal
  `std`/`std_collections`
  — **no `rust_std` base module**, ever.
- `ball-lang-macro-expand` (`rust/macro-expand/`) — `macro_rules!` expansion (#629). Quarantines
  `ra_ap_mbe` + `ra_ap_tt`/`ra_ap_span`/`ra_ap_intern` (all `=0.0.351`) + salsa + `serde_json`
  behind `MacroTable`/`MacroError`/`Expansion`/`Route`, so `ball-lang-encoder` names no `ra_ap_*`
  type. PUBLISHED, not `publish = false` — `cargo publish --workspace` refuses a
  `publish = false` dependency of a published crate.
- `ball-lang-engine` (`rust/engine/`) — self-hosted engine wrapper (`loader.rs`/`scope.rs`/
  `ball_proto.rs`) + generated, gitignored `src/compiled_engine.rs`. See
  `rust/engine/AGENTS.md` for the full self-host gap list; the compiled-engine driver is behind
  the off-by-default `self_host` cargo feature.
- `ball-engine-regen` (`rust/engine/tool/`) — `cargo run -p ball-engine-regen` regenerates
  `compiled_engine.rs` from `dart/self_host/engine.ball.json`.
- `ball-lang-cli` (`rust/cli/`) — the `ball` CLI (#41/#304): `run`/`compile`/`encode`/`check`
  plus the cli-core verbs. `encode` takes `--lib` (library mode, #491) and `--crate` (walk a whole
  crate's `mod` graph, #491).

## Key Patterns

### Compiler

- `Compiler::compile` / `compile_library` (library mode has no runnable entry point — used for
  the self-host regen tool) emit Rust source **as strings**, closest in spirit to the C++
  compiler's string-concatenation approach (not Dart's `code_builder`/TS's `ts-morph`).
- Every compiled expression evaluates to a `ball_lang_shared::BallValue` — there are no "void"
  expressions; side-effecting calls like `print` compile to `{ ...; BallValue::Null }` so every
  expression position (block tail, `if`/`else` arms, function bodies) stays type-uniform.
- `Block` compiles to a **native Rust block expression** (Rust blocks are already
  tail-expression-valued) — unlike C++'s immediately-invoked lambda pattern for blocks.
- Control flow (`if`/`and`/`or`/`for`/`for_in`/`while`/`do_while`) compiles to native Rust
  control flow, never a function call — lazy evaluation per invariant #4.
- **`switch` vs. `switch_expr` are two different lowerings, and the difference is load-bearing.**
  `base_call.rs` dispatches the two literal call names to `compile_switch(call, is_expr)`, and
  `is_expr` must be threaded all the way through `parse_switch_cases`:
  - The fall-through/empty-body heuristic (`is_empty_switch_body`) is **statement mode only**. Ball
    encodes `null` as a value-less `Literal` — the exact shape that heuristic reads as "empty" — so
    in expression mode it would delete every `=> null` arm and leak its condition (issue #470; it
    silently ate the self-hosted engine's own `Literal_Value.notSet` arm). Mirrors
    `go/compiler/base_call.go:514-522`.
  - A defaultless switch **expression** that matches nothing throws
    `Non-exhaustive switch expression` via `ball_throw` (issue #467, aligning with Go/C#/Dart); a
    statement `switch` still legally falls through to `BallValue::Null`. That throw is only safe
    *because* the arm-dropping fix landed first — restoring it alone regresses the self-host sweep
    320 → 315.
- Arithmetic semantics must match the Dart reference engine, not "whatever Rust's operator
  does": `modulo` is Euclidean (sign of divisor, via `ball_lang_shared::runtime`), int ops use
  wrapping arithmetic (Dart's fixed-width 64-bit `int`, no overflow panics), `equals`/
  `not_equals` promote `Int`/`Double` cross-type.
- **Reference-semantic collections (Dart parity, #298/#39/#300).** `BallValue::List` and
  `BallValue::Message` share their backing (`Arc<Mutex<Vec>>` / `Arc<Mutex<Map>>`,
  `rust/shared/src/value.rs`), so a `.clone()`-on-read *aliases* — a `list.add(x)` /
  `this.field = y` through any clone is observed by the caller, exactly like Dart's reference
  types. Only `Map` stays value-semantic. **Copy points must snapshot**, matching Dart: a list
  *literal* `[…]` emits `BallValue::List(BallList::from(vec![…]))` (fresh backing), and
  `toList()`/`List.from`/spread/`Set` + the `+` concat operator go through `as_list()` (a
  snapshot `Vec`) — never `.extend()` on a shared list, which would mutate an operand. A
  `list[i] = x` / `obj.field = x` write can't borrow `&mut` through the `Mutex`, so it routes
  through `ball_index_get`+`ball_index_set` / `ball_field_get`+`ball_field_set` read-modify-write
  (`lvalue.rs::emit_mutation`).
- Documented scope gaps live in `rust/compiler/src/lib.rs`'s module doc comment (a handful of
  base functions, constructors/methods with a real mutating body, class-hierarchy/`is`/`as`
  subtyping, multi-parameter lambdas) — read it before assuming something is a bug vs. a known,
  documented boundary.

- **A constructor's INITIALIZER LIST is applied even when the constructor is BODYLESS (#706).**
  `unnamed_constructor_fn` (was `body_constructor_fn`) resolves a class's unnamed constructor when
  it carries a body **or** a `metadata.initializers` field entry, and `compile_message_creation`
  invokes the associated fn for either. Only the associated fn runs `constructor_self_init`, which
  is the single place an initializer list is read; the inline field map beside it knows
  `metadata.params` and nothing else. So `FixedSlice(this.source, int end) : windowSize = end;`
  used to build an instance carrying the plain parameter `end` as a bogus field and no
  `windowSize` at all, and `slice.windowSize` answered `null` — a SILENT wrong answer, not a build
  failure. `compile_constructor_with_body` takes `Option<&Expression>` now: a constructor with only
  an initializer list emits no body IIFE and no write-back, because its whole effect is already in
  `self_init`. Guard: `rust/compiler/tests/final_field_setter.rs`, over fixture
  `472_initializer_list_field_with_setter`. The same one-boolean gap was live on Go and C#; the
  fixture's own comment records why the shape looked like a setter problem and is not one.

- **`std_collections.list_find` THROWS when nothing matches (#597).** It is Dart's
  `Iterable.firstWhere` WITHOUT `orElse` — what its own declaration in
  `dart/shared/lib/std_collections.dart` says ("Find first:
  list.firstWhere(callback)") and what the Dart reference engine does
  (`engine_std.dart`: `throw StateError('No element')`). Never a `null`/
  `undefined`/empty placeholder, and never an untyped throw: the thrown value
  must carry the type name `StateError` so the program's own `on StateError
  catch` sees it. `tests/conformance/463_list_find_no_match` is the cross-target
  guard; `rust/shared/src/runtime.rs`'s `list_find_no_match_throws_a_typed_state_error` (`ball_list_find` uses `ball_throw_typed`, like its `.first`/`list_reduce` neighbours — a bare `panic!(&str)` is recoverable only by an UNTYPED catch) is this target's half. See `docs/TESTING_STRATEGY.md` §5b.

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
  reference-semantics leg) plus this target's own tag test — `rust/shared/src/runtime.rs`'s `sink_is_a_tagged_reference_value` and `rust/compiler/tests/string_sink.rs`.
  Backing: `ball_sink_create`/`ball_sink_write`/`ball_sink_to_string` in `rust/shared/src/runtime.rs`, over a `BallValue::Map` — an `Arc<Mutex<IndexMap>>`, so the callee's append is shared. A bare `String` field would make `ball_type_of` answer `String` and lose every cross-call append, exactly as the by-value `Vec<BallValue>` clone did in #300.

- **`.first`/`.last`/`.single` raise a TYPED `StateError` too (#616).** They used
  to `panic!(&str)` with a message no other target produced — recoverable only by
  an untyped catch, so a program's own `on StateError catch` around an empty
  `.first` never saw it. And `ball_throw_typed`'s payload now renders as Dart's
  own `StateError.toString()` (`value.rs`'s `dart_error_to_string`, a CLOSED
  table over the type names `ball_throw_typed` is called with), so `to_string(e)`
  in a catch body reads `Bad state: No element` rather than the raw map form.
  `rust/shared/src/runtime.rs`'s
  `empty_first_last_and_single_throw_a_typed_dart_state_error` is this target's
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
  source on the SDK. `ball_cast_assert` takes the subject (`&BallValue`) now, and
  `value.rs`'s `dart_error_to_string` renders `TypeError` with an EMPTY prefix.
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
  This target needed TWO fixes. `ball_normalize_thrown` already aliased `arg0`
  (#615), but `write_entries` rendered a `BallValue::Message` from its field
  entries alone - a message carries its tag out of band in `type_name`, so the
  table never saw it - and `dart_error_to_string` did no module-prefix
  stripping, unlike every sibling. Both are closed in
  `rust/shared/src/value.rs`, with
  `a_user_thrown_builtin_error_renders_like_dart` beside them.

- **`try` dispatches EVERY catch clause, in source order (#615).** `compile_try`
  emits an `if`/`else if` chain over the recovered payload: an `on <Type> catch`
  clause runs only when `ball_catch_matches(&__err, "<Type>")` accepts the thrown
  value's type tag (a `BallValue::Message`'s `type_name` or a `BallValue::Map`'s
  `__type__`, matched by FULL `main:StateError` or BARE `StateError` spelling,
  like `_evalLazyTry` in the reference engine), the first untyped `catch (e)` is
  the `else`, and a clause list where every typed clause misses runs `finally`
  then `ball_throw(__err)` so an enclosing `try` sees the original value. Before
  #615 only `catches.first()` was compiled — as an unconditional catch-all — so
  `throw StateError(...)` ran an `on ArgumentError catch` body: silently wrong
  output, never an error. `ball_throw` also mirrors `std.throw`'s
  `arg0` -> `message` rename, so a caught `e.message` reads the constructor
  argument instead of null. `_ball_rethrow_err` still binds the ORIGINALLY caught
  value, once, before any clause binds its own variable. Guards:
  `tests/conformance/464_typed_catch_clause_dispatch` +
  `146_nested_try_catch_types` (cross-target),
  `rust/compiler/tests/catch_clause_dispatch.rs` and `runtime.rs`'s
  `catch_matches_*`/`throw_aliases_arg0_as_message`. Those are what gate the
  SHAPE: the `rust-compiler` matrix row is a PR gate since #619, but it is a
  RATCHET on a passing count, and 146's failure sat inside its floor from day
  one.

### Encoder

- `encode(&str) -> Program` parses with `syn` and walks items → fns → statements → expressions.
- **Invariant, not optional: no `rust_std` base module.** Every Rust construct (operators,
  control flow, iterator-chain sugar, `?`, `if let`) expands into a tree of `std`/
  `std_collections` calls — mirrors the Dart encoder's cascade/null-aware-access/spread
  expansion. A conformant engine that has never heard of Rust must still run the result.
  See `rust/encoder/src/lib.rs`'s module doc comment.
- Std modules are accumulated from actual usage (`collect_used_functions`) — encoded programs
  declare only the base functions the source actually calls (`std` itself is always present,
  even empty), mirroring `dart/encoder/lib/encoder.dart`'s `_buildStdModule`.
- The "one input" convention (invariant #1) for N-parameter Rust fns/closures: 0 params → no
  input; 1 param → kept as a plain `reference(name)` driven by `metadata.params` (compiler's
  `param_alias_prologue` turns it into a real local binding); 2+ params → packed into one
  anonymous `MessageCreation`, each param read via `field_access(reference("input"), name)`.
- **An immediately-invoked zero-argument closure inlines ONLY when its body cannot exit early
  (#687).** `(|| … )()` is the shape `rust/compiler` wraps each of its three FUNCTION bodies in —
  the entry `fn main()` (`compile_entry_main`, because `main` returns `()`), a method with
  instance-field write-back, and a body-carrying constructor (both `type_emit.rs`) — and #646's
  `as_zero_arg_closure` inlines it into the Ball `block` its body already is, which is what makes
  those re-encodable. It is **not** the lowering of a value-position Ball `block`: `compile_block`
  emits a native Rust block, since Rust blocks are already tail-expression-valued (C++ and Go do
  need an IIFE there, and route `return` through runtime flow signals because of it). Inlining is
  unsound the moment the body can exit early, because that is the one way the two constructs
  differ — a Rust `return` inside the closure leaves the CLOSURE, a Ball `return` inside a `block`
  leaves the enclosing FUNCTION — so the ordinary early-exit idiom
  `let x = (|| { if …{ return a; } b })();` would encode to a well-formed Program with a different
  answer. When the body *can* exit early the faithful Ball is `std.invoke` over a `lambda`, which
  is what `dart/encoder`'s `FunctionExpressionInvocation` arm emits and what `compile_lambda`
  turns back into a closure whose `return` leaves the closure again. The early-exit set is derived
  from what this encoder emits a `std.return` for — `return` and `?` (`encode_try_operator`);
  `break`/`continue` cannot cross a closure boundary in Rust at all — and the scan
  (`closure_body_exits_early`) is a `syn::visit::Visit` that stops at every frame owning its own
  `return`: a nested closure, a nested item, an `async` block, a `try` block. Run-proved, not
  shape-asserted: `compile_reencode_roundtrip.rs::an_immediately_invoked_closures_return_stays_inside_the_closure`
  builds and runs the compiled output against what `rustc` prints for the source, because a
  re-bound `return` produces a perfectly well-formed Ball tree.
- Documented gaps (see `rust/encoder/src/lib.rs` / `types.rs` / `methods.rs`): data-carrying enum
  variants, **signature-only** receiver-less `trait` associated functions (a *default-bodied* one
  encodes — see below; the guard keys on the missing BODY, not the missing receiver), a
  `receiver.method(args)` whose method is declared in another file (`methods.rs`' own panic — the
  largest remaining bucket), an `impl` whose **self type** is a TUPLE or an ARRAY
  (`impl<I> Trait for (I::Item,)`, `impl Trait for [T; M]` — `types.rs::type_short_name`; a
  REFERENCE self type is CLOSED by #767, which looks through `&T`/`&mut T` to the referent
  because Ball has no reference-vs-value distinction, and that halved the bucket 8 -> 4 of the 77
  scored Tier A files), destructuring patterns (`let Pair(a, b) = p;`), a *reference* to a skipped module-scope
  `const`/`static`/`type` alias (the declaration itself is skipped — see below),
  unmapped macros (the `assert!` family; `write!`/`writeln!` are CLOSED by #630 — see the
  `write!`/`writeln!` bullet further down this section). Each is
  pinned by a `#[should_panic]` characterization test in `rust/encoder/tests/documented_gaps.rs`
  (#491) — flip it to a positive assertion in the same PR that closes the gap. **Count the OPEN
  pins with `grep -c '^#\[should_panic' rust/encoder/tests/documented_gaps.rs`, never from
  prose** — 11 on 2026-09-21, after #767 added two (`.finish()`, a PERMANENT carve-out rather
  than a backlog item, and the ARRAY half of the `impl` self-type boundary, which had no pin at
  all beside the tuple half). THREE of the rest are #632 siblings, and #712 changed *which* three: the
  compiled method dispatcher's `ball_message_type_name` scrutinee (#718's unmapped-helper family),
  the spliced MAP literal's `ball_map_create` tail — mapped since #692, but only over a LITERAL
  pair list, so the comprehension's local accumulator is still refused by SHAPE — plus `matches!`,
  which is no longer a #712 instance at all, since the compiler stopped emitting it, but the
  encoder's permanent boundary for hand-written Rust). Everything else in that file is a flipped, positive assertion.
  Anchor the pattern at the line start so it counts ATTRIBUTES: the unanchored `grep -c
  should_panic` this line used to prescribe also matches the PROSE mentions in that file's doc
  comments, and answered 13 against 6 open attributes when #626 caught it. A tally in a rule file goes stale the moment a slice lands
  — this line once read "Five are flipped" while eight were. **A pin is owed the moment a gate exists, not the moment
  it closes** — the 24-file cross-file METHOD-call bucket went three merged #491 PRs with a live
  gate and no test observing it before `cross_file_method_call_is_a_documented_gap` pinned it. It
  is CLOSED now by the crate-aware `encode_crate` (below), and that test is flipped positive.
- **Tuple + unit structs (#491).** All three `struct` shapes encode to the same class-shaped
  `TypeDefinition`; only the field names differ. A tuple element is declared under its
  **positional index as a decimal string** (`"0"`, `"1"`) — the very name
  `types.rs::member_name` has always produced for the matching `p.0` *read*, and an opaque map key
  to the compiler (`is_positional_arg_name` matches only `arg<digits>`). A unit struct declares
  zero fields. **Declaration alone would be a regression**, so two `lib.rs` interceptions ship with
  it: `encode_call` turns `Pair(3, 4)` into a `message_creation` *before* its same-file-function
  branch (the two are the same syntax), and `encode_path_expr` turns a bare `Marker` into an
  empty-field `message_creation` *before* its `reference(name)` fallback — but *after*
  `is_current_multi_param`, so a same-named parameter still wins; that name-only bias is inherited
  from the `.fuse()`/`.is_empty()` precedent and deliberately not widened. Proof:
  `rust/encoder/tests/tuple_and_unit_structs.rs` (encode → compile → `cargo build` → run).
  **Closing this category did NOT move the Tier A aggregate** — measured before *and* after:
  `Results: 0 passed, 110 failed, 110 total`; all 14 files simply land on their next gap (7 on
  `write!`). See `rust/AGENTS.md`'s histogram; never let a green `documented_gaps.rs` be read as a
  moved floor. *Destructuring* a tuple struct remains a separate, still-open pattern gap.
- **Tuple EXPRESSIONS and reference `impl` self types (#767).** `(a, b)` lowers to `std.record` —
  the universal base function `dart/shared/std.json` declares for a positional record — with
  components named `"0"`/`"1"`, and `()` to the Ball NULL literal (Rust's "no value", not an empty
  record). The names are **Rust's own member spelling, not Dart's `$1`/`$2`**, and deliberately
  so: `encode_field` already renders a `t.0` read that way and `encode_item_struct` declares a
  tuple STRUCT's fields the same way, while `p.0` on a tuple struct is syntactically
  indistinguishable from `t.0` on a tuple — so `$1` would have forced re-spelling the tuple-struct
  fields too. It stays portable because every target treats a component name that is neither `$N`
  nor `argN` as an opaque key on BOTH the `record` build side and the `field_access` read side.
  Separately, `types.rs::type_short_name` now looks through `&T`/`&mut T`/`&'a T` to the referent:
  Ball has no reference-vs-value distinction (`encode_expr` has always encoded `&x` as `x`), so
  `impl Trait for &Counter` names the same Ball class as `impl Trait for Counter` — nothing is
  guessed from a name. The consequence to keep in mind is that an inherent `impl Counter { fn f }`
  and an `impl Trait for &Counter { fn f }` in one file now collide on one owner, exactly as
  `impl Counter` and `impl Trait for Counter` always have. A TUPLE or ARRAY self type still fails
  loud. Proofs: `rust/encoder/tests/tuple_expressions.rs` and
  `rust/encoder/tests/impl_for_reference_self_type.rs` (both encode → compile → `cargo build` →
  run). **Measured yield:** stage-1 `encoded` **7/77 -> 9/77**, `compiled back` 7 -> 9, histogram
  exactly conserved (`tuple` 6 -> 0, `impl` self type 8 -> 4); `reencoded` stays **1**, because
  both newly-arriving files stop at stage 3 on `ball_arg_get` (#790).
  `tools/coverage-study/baseline.json` is raised on the first two and left alone on the third.
- **Non-`Fn` items inside an `impl` block are SKIPPED, not thrown on (#491 slice 5).** An
  associated `const`/`type` (or an item-position macro) beside real methods no longer aborts the
  whole file — `types.rs::encode_item_impl` skips it and keeps encoding the block's methods, the
  same tolerance the sibling pre-pass `collect_impl_method_params` always had. Safe because a real
  *reference* to the dropped item (`Self::CAP`) still fails loud at `lib.rs`'s "unsupported path
  expression" panic. Proof: `rust/encoder/tests/mixed_impl_items.rs` (encode → compile →
  `cargo build` → run). This is a DIFFERENT gap from the still-open `impl` self-type one above;
  do not conflate their file counts.
- **Module-scope `const`/`static`/`type` alias and non-`Fn` `trait` items are SKIPPED too
  (#491).** `lib.rs`'s top-level item match and `types.rs::encode_item_trait` no longer abort a
  file on a declaration Ball models nothing for — 7 and 3 of the 110 scored Tier A files
  respectively. **The module-scope skip needs a guard the `impl` one does not, and copying the
  precedent without it would be a silent-degradation bug:** a skipped `impl` item is referenced as
  `Self::CAP` (a two-segment path `encode_path_expr` already refuses), but a skipped module-scope
  `const` is referenced as a bare `LIMIT` — a single-segment path the same function would pass
  through its `reference(name)` fallback, emitting a read of a binding nobody declared. So pass 1
  records the names in `Encoder::skipped_item_names` and `encode_path_expr` panics at the USE
  site, naming the declaration. A top-level **macro invocation** is still never *skipped*: it
  can be the thing that DEFINES a type the file references (`bitflags!` → `TestFlags`), so
  skipping it would orphan the references into a worse error. Since #629 a `macro_rules!` one is
  *expanded* instead (next bullet); a macro nothing in scope defines still panics.
  Proof: `rust/encoder/tests/mixed_module_items.rs`. Like every #491 slice, the Tier A
  **aggregate did not move** (`0 passed, 110 failed, 110 total`, `encoded 0/110` before and
  after) — only the first-blocker histogram did; `baseline.json`'s Rust row is unchanged.
- **`macro_rules!` EXPANSION (#629).** `encoder/src/macro_expand.rs` is a **pre-pass** — it runs
  before `fn_params`/`enum_names`/`method_params` collection and before
  `crate_graph::collect_symbols`, because an expansion introduces declarations those passes must
  see. It iterates to a **fixed point** (a self-recursive macro comes back partly expanded —
  measured) with a **depth limit of 128** (rustc's own default `recursion_limit`), handles item /
  `impl`-item / `trait`-item / statement / expression positions, and removes `macro_rules!`
  definitions from the item list. The engine is rust-analyzer's `ra_ap_mbe`, quarantined in
  `ball-lang-macro-expand`; **there is no per-macro special case anywhere — grep for `bitflags`
  in `rust/` and you will find only prose.** Three routes, deliberately distinct: a builtin
  (`println!`/`vec!`/`assert!`/`write!`, with or without a `std::`/`core::`/`alloc::` qualifier)
  goes to `methods.rs::encode_macro` as before — which is what keeps issue #630 separately
  trackable; a name nothing in scope defines is left for the encoder's own loud refusal (the
  proc-macro / `#[derive]` / attribute-macro boundary); a name that SHOULD have been reachable
  and was not is a named `MacroError`, never flattened into "unsupported". A dependency source
  path the walk cannot LOOK at — a subdirectory whose `read_dir` fails, a dangling symlink — is
  recorded through the same `note_unreadable_source` an unparseable file uses and named in the
  resulting diagnostic (#678); "not found" and "could not look" are never conflated. The dependency
  EDGES obey the same rule since #705: a `deps[]` entry with no `name`/`pkg`, a `pkg` id with no
  `packages[]` entry, a package with no library target and a library target with no `src_path` are
  each a `note_unresolvable_dependency`, never a `continue` — a `proc-macro`-only package is the
  one deliberate silence, because that skip is an answer this crate documents. **Hygiene is an
  approximation and must be described as one** — origin-tagged α-renaming of definition-origin
  bindings to `<name>__ball_mbe<N>`, not rust-analyzer's `SyntaxContext` transparency chain —
  so it is the one part of this feature that can produce the #488 class of bug (round-trips
  clean, changes behaviour), which Tier A is structural and cannot see; the run-and-diff-bytes
  round trip in `rust/encoder/tests/macro_expansion.rs` is what does. **Measured yield, stated
  plainly:** only 4 of the 110 scored Tier A files are first-blocked by a `macro_rules!`
  invocation, and the 28-file `TestFlags` bucket is a `#[cfg(test)]`-scoping question, not a
  macro one — expansion moves first blockers, it does not on its own make a file clean. Full
  design record, including the per-class invocation census: `rust/AGENTS.md`.
- **`write!`/`writeln!` route onto the declared text sink, by SYNTAX alone (#630).** `core` defines
  `write!($dst, ..)` as `$dst.write_fmt(format_args!(..))` — the destination is a method RECEIVER,
  so the first argument **is** the sink by construction and `encode_write_macro` consults no type
  information (6 of the 7 first-blocked Tier A files write through an *unannotated closure
  parameter*, so any design needing inference is dead on arrival). Two arms: anything that is not a
  local binding → `std.sink_write{sink, text}`; a bare name bound by a `let` whose initialiser is a
  `String` constructor → a **re-assignment** `s = std.concat(s, text)` (the `itertools::join`
  "join-sites" rule — that local is ALSO read as a `String` in the same function, and an opaque
  sink would silently change those reads); a bare name bound by a `let` of any other shape → a
  **loud refusal** naming the local and its initialiser, never a guess. `writeln!` is `write!` +
  `"\n"`, exactly how `core` spells its own no-argument arm. Both arms are wrapped in the unified
  `Ok(..)` outcome, because `write!` evaluates to a `fmt::Result` that 22 of the 25 corpus sites
  consume with `?`/`.unwrap()`. Supporting: `Encoder::local_scopes` (a binding-frame stack — one per
  fn/closure/`impl` method/default-bodied trait method, seeded with that body's parameters, AND one
  per `{ .. }` block, since a block's `let`s die at its closing brace; looked up innermost-first so
  a closure param or a nested block's own binding shadows an enclosing local) is deliberately SEPARATE from
  `push_fn_scope`, which records parameters only for a 2+-parameter body and is not pushed for an
  `impl` method at all; a bare destination name that is a `&mut` ALIAS binding resolves to the
  variable it borrows FIRST (issue #642's `ref_aliases`, the same resolution
  `encode_path_expr` does for every other read — so `write!(slot, ..)` after
  `let slot = &mut s;` classifies `s`, in both directions) — but only the MODELLED
  `AliasTarget::Variable` half, since an `AliasTarget::Opaque` one (#693) emits a real binding
  recorded as a non-`String` local and must reach the same loud refusal `encode_assign` gives a
  write through it; `Encoder::with_pattern_binding` gives a for-loop variable, a `match`-arm
  binding and an `if let` binding a frame of their own — `record_local`'s only call site is the
  `let` handling, so without one the lookup walked PAST the pattern binding to a same-named
  enclosing local, and `let mut s = String::new(); for s in writers.iter_mut() { write!(s, ..) }`
  re-assigned the outer `s`, losing every write SILENTLY (a pattern binding classifies as a SINK,
  like a parameter, never as a refusal: iterating real sinks is an ordinary shape, and a `String`
  element lands in the documented boundary below and fails loud at RUN time); and
  `String::new()`/`String::with_capacity(n)` now encode as the empty
  string (both were "unsupported call target", so the local-`String` arm would have been
  unreachable; capacity is an allocation hint with no observable effect). Measured: Tier A
  `encoded` **1/77 -> 7/77**, `compiled back` 1 -> 7, `clean` unchanged at 0. Proof:
  `rust/encoder/tests/write_sinks.rs`; design record `docs/SINK_DESIGN.md`.
- **`.fuse()`/`.is_empty()` (#491 slice 6), and the permanent carve-outs beside them.** `.fuse()`
  is an identity passthrough (a Ball `List` has no exhausted state); `.is_empty()` lowers to
  `std.equals(std.length(receiver), 0)`, reusing `.len()`'s own universal dispatch, so it needs no
  type inference. Everything else in `methods.rs`' catch-all bucket is a **permanent** carve-out
  named in that file's module doc comment — `.next()`, `.unwrap_or_default()`, `.spilled()`,
  `.iter_names()`, `.serialize_seq()`, `.is_human_readable()`, `.ok_or()`, `.value()`,
  `.multiunzip()`. Each needs stateful-iterator semantics Ball lacks, or a type-specific default
  no syntactic encoder can supply; guessing produces silently wrong output, not a loud failure.
  **Both new arms defer to a same-file user method of that name** (a `!method_params.contains_key`
  guard) — unlike every older arm, which matches on the name alone. That older bias is inherent to
  a syntactic encoder (a user's `fn len(&self)` has always become `std.length`), but a `Vec`-backed
  struct's own `is_empty` lowered to `std.length(struct) == 0` would be silently wrong output, so
  slice 6 deliberately does not widen it.
- **Receiver-less associated functions + cross-file calls (#491 slice 3).**
  `impl Point { fn new(x, y) … }` now encodes as a `metadata.is_static` class member (the shape
  `type_emit.rs::method_prologue` has supported since #288), and `Point::new(3, 4)` emits
  `FunctionCall{module: "", function: "new"}` with the callee's real parameter names and no
  `"self"` field — proven end to end (encode → compile → `cargo build` → run) by
  `rust/encoder/tests/static_methods.rs`. A call into a module this file does not declare
  (`other_file::helper(1)`) emits `FunctionCall{module: "other_file", …}` plus a **source-less
  `ModuleImport`** ("ref only") instead of panicking, with arguments packed **positionally**
  since an external callee's parameter names are unknown; `rust/encoder/tests/cross_module_calls.rs`
  pins the shape. That fallback is **module-only** — it applies when the segment immediately
  owning the function is `snake_case`, so `Vec::new()`/`std::vec::Vec::new()` (an associated fn on
  a foreign TYPE, which no import could supply) still fail loud. **Verified contract**, not assumed: a source-less import is structurally legal
  and deliberately unresolved — `ball check` accepts the program
  (`rust/cli/tests/cli_check.rs::encoded_cross_file_call_is_structurally_valid_but_unresolved`),
  matching the Dart reference (`cli_core.dart`'s `validationErrors` never inspects imports;
  `runner.dart`'s `ball build` treats only a source-BEARING import as needing the resolver), and
  the program is not runnable until the module is supplied — the same boundary library mode set
  for an empty `entry_function`. Keep this decision consistent with the C# encoder's eventual
  cross-file slice (#492 bucket d). That known limitation - a `crate::`/`self::`-qualified call
  treated as external - applies to the SINGLE-FILE entry points only; `encode_crate` resolves
  both (next bullet).
- **Crate-aware encoding - `encode_crate` / `ball encode --crate` (#491, owner decision
  2026-09-13).** `rust/encoder/src/crate_graph.rs` walks a crate's `mod` graph from its root (the
  `Cargo.toml` directory, the `src` directory, or the root `.rs` file) and encodes every file
  against ONE crate-wide symbol table - the Rust sibling of
  `dart/encoder/lib/package_encoder.dart`. That is what closes the largest #491 bucket: a
  `receiver.method(args)` whose method is declared in another file. Resolution follows the Rust
  reference (`foo.rs` XOR `foo/mod.rs`; the declaring file's own directory for a mod-rs file and
  `<dir>/<stem>/` otherwise; `#[path]` relative to the declaring FILE's directory outside an
  inline block and to the nested directory inside one; an inline `mod` block is its own module,
  and `#[path]` ON such a block replaces the component it contributes, so
  `#[path = "thread_files"] mod thread { #[path = "tls.rs"] mod local_data; }` resolves to
  `thread_files/tls.rs`, #626); TEST-ONLY modules are not walked, because `cargo build` does not
  compile them either. Test-only means the `cfg` predicate evaluated with `test := false` and
  every other leaf UNKNOWN - never a token scan for a bare `test` ident, which also matched
  `#[cfg(not(test))]` and silently dropped a module every ordinary build HAS (#626).
  `#[cfg(any(test, feature = "x"))]` is kept: cargo builds it with the feature.
  **Output is multi-module and needed NO compiler change** - a cross-file call carries
  `FunctionCall.module`, which `type_emit.rs::resolve_user_call_name` (issue #38's multi-module
  output) already turns into the `<mod>::` qualifier onto that module's dispatcher. What it
  narrows rather than removes, each pinned in `rust/encoder/tests/crate_encoding.rs`: a method no
  file in the crate declares still fails loud; so does a method short name declared in two
  modules when the call site's own module declares neither (the compiler's dispatcher resolves by
  short name WITHIN a module, so picking one would silently dispatch to the wrong body); a
  cross-module enum-variant read is refused by name; a `mod` with no file is a loud panic, never
  a dropped module. **Indexing must not fail loud where encoding must**: the walk catalogues the
  whole crate before encoding anything, so it reads parameter names with its own non-panicking
  `simple_param_names` - reaching for `param_names_and_types`/`method_non_self_params` there
  turned `itertools`' one `fn cmp(&self, (c, t): ...)` into "no crate-aware measurement for the
  entire crate". Measured before/after with ONE binary over one checkout (`rq1-study
  --single-file` reproduces the per-file measurement): stage-1 `1 encoded` **0/110 -> 1/110**,
  clean unchanged at **0/110**, histogram conserved (`unsupported method call` 18 -> 11,
  `unsupported call target` 35 -> 32). `tools/coverage-study/baseline.json`'s Rust row is raised
  to `encoded: 1` and nothing else.
- **Default-bodied receiver-less `trait` functions (#491).** `trait Maker { fn make(n, m) -> i64
  { n + m } }` encodes as the same `metadata.is_static` class member an `impl`-declared associated
  fn does, and `Maker::make(3, 4)` resolves through the same short-name dispatcher — the compiler
  needed **zero** change, because `compile_struct_def`/`compile_method_dispatchers` filter members
  by `is_abstract` **alone** and never look at whether the owner is a `trait`. So the guard in
  `types.rs::encode_item_trait` keys on the missing *body*, not the missing *receiver*; a
  signature-only one still fails loud and keeps its `#[should_panic]` pin. A new pre-pass,
  `collect_trait_static_params`, registers each such member into `static_method_params` under the
  same owner-qualified `(owner, method)` key `collect_impl_method_params` uses.
  **Gotcha worth remembering:** a receiver-less member's `metadata.params` must come from
  `param_names_and_types`, never `method_non_self_params` — the latter unconditionally `.skip(1)`s
  a `self` that isn't there and silently drops the FIRST real parameter. A 0-/1-parameter example
  cannot expose that, so the proof test declares two. Proof: `rust/encoder/tests/static_methods.rs::
  default_bodied_trait_fn_without_receiver_encodes_and_round_trips` (encode → compile →
  `cargo build` → run, prints `12`). Like every #491 slice so far, this did **not** move the Tier A
  aggregate (`0 passed, 110 failed, 110 total`) — a default-bodied *receiver-less* trait fn is a
  narrow idiom; state that plainly rather than implying a moved floor.
- **A `&mut` ALIAS binding is resolved, not copied (#642/#693) — the one shape whose mis-encoding
  is silent.** `let slot: &mut T = &mut place;` is what `rust/compiler`'s
  `lvalue.rs::emit_mutation` emits for EVERY Ball `assign`
  (`let __slot: &mut BallValue = (&mut i); ...; *__slot = __new.clone();`), and Ball has no
  references: binding it as a value made the write land on a copy, so the borrowed variable never
  changed and every loop whose counter is mutated that way ran forever. Measured: 28 of the
  corpus's loop fixtures re-encoded "clean" and then hung on the Dart reference engine, killed at
  60 s; fixing it moved the `rust-roundtrip` row 68 -> 99 of 351 and the job from 40 min to 14 — worse than a refusal, because `ball check` accepts the Program. `block.rs::encode_local`
  now records `alias → variable` in a BLOCK-SCOPED table and emits no binding, and
  `encode_path_expr` resolves a read of the alias to the borrowed variable. Deliberately narrow:
  only a borrow of a plain NAMED variable — `&mut v[0]`/`&mut p.x` are left exactly as they were
  rather than guessed at, and a `&mut` passed to a callee is still the wider, open
  reference-semantics gap. The alias is SHADOWED like any other Rust binding — by a later `let` of
  the same name (cleared in `encode_local` AFTER its initializer is encoded, so `let r = r + 1;`
  still reads the old one) and by a fn/closure PARAMETER of the same name (saved and restored
  around every `push_fn_scope`/`pop_fn_scope`) — or a read of the shadowing binding would silently
  resolve to the borrowed variable instead, the same class of wrong answer in the other direction.
  Guards: `rust/encoder/tests/compiler_output.rs`'s
  `mutation_through_a_mut_alias_targets_the_borrowed_variable`,
  `a_borrow_of_a_non_variable_place_is_not_treated_as_an_alias`,
  `a_later_let_of_the_same_name_shadows_the_alias` and
  `a_parameter_shadows_an_alias_of_the_same_name`.
  **And a WRITE through a borrow that is NOT that one shape now fails loud (#693).** Leaving
  `let s = &mut p.x;` to encode as a value is correct for a READ (a read of a borrow and a read of
  a copy give the same answer) and silently wrong for a write — the same lost write as the alias
  bug, one place over. `block.rs::encode_local` classifies the initializer as
  `AliasTarget::Variable` (modelled, no binding emitted) or `AliasTarget::Opaque` (binding still
  emitted, carrying the borrowed place rendered back to Rust), and
  `lib.rs::refuse_write_through_an_unmodellable_borrow` — called from `encode_assign`, the single
  choke point for `=` and every compound operator — panics when a write's ROOT (through
  parens/deref/field/index, `write_root_name`) resolves to an `Opaque` alias, naming the alias, the
  place and #692. A `&mut` of a variable that is itself `Opaque` inherits the opaqueness rather
  than becoming a modelled alias of the copy. A SHARED `&p.x` is never `Opaque`: Rust cannot write
  through a `&T`, so there is nothing to lose. Guards:
  `rust/encoder/tests/mut_borrow_writes.rs` — four refused write shapes and four controls (a
  read-only `&mut` borrow, a shared borrow, the modelled plain-variable alias, and shadowing).
  **And so does a MUTATING METHOD CALL through such a borrow (#775).** An assignment is not the
  only way to mutate: `let s = &mut v[0]; s.push(x);` encodes as
  `std_collections.list_push(list: <receiver>, value: x)`, `list_push` appends IN PLACE
  (`dart/engine/lib/engine_std.dart`: `list.add(m['value'])`), and `encode_path_expr` resolves an
  `Opaque` receiver to the emitted COPY — the identical silent loss, reached through `.method(…)`.
  `methods.rs::refuse_mutating_method_through_an_unmodellable_borrow` runs before arm dispatch and
  shares `lib.rs::refuse_mutation_through_an_unmodellable_borrow` (and therefore `write_root_name`)
  with `encode_assign`, so a projection off the alias is refused exactly as a bare `*s` is. **The
  covered set is exactly, and only:** a bare or compound ASSIGNMENT whose root is an `Opaque`
  alias, and a call of a built-in arm that mutates its RECEIVER — `methods.rs`'s
  `RECEIVER_MUTATING_METHODS`, today the single entry `("push", 1)`, matched on name AND arity so
  it mirrors the arm's own guard. A method that is in NEITHER list and is not a user-declared one
  is refused too, a few lines earlier than the catch-all would have refused it anyway — "not
  provably a read" is never assumed safe, so an arm added later without being classified stays
  closed. **Out of scope, and why:** (a) a READ through the borrow
  (`s.len()`, a bare `s`) is never refused — a read of a borrow and a read of a copy give the same
  answer, which is why `RECEIVER_READ_ONLY_METHODS` exists as a listed set rather than an implicit
  "everything else"; (b) a `&mut` handed to a CALLEE (`f(&mut x)`) is a different mechanism — the
  callee's mutation, not a local alias — and stays with #692; (c) a USER-DECLARED instance method
  mutating its own receiver, which no receiver carries back on any call, aliased or not
  (`type_emit.rs::method_prologue` extracts `self` from `input.clone()` — the boundary `types.rs`'s
  module doc comment already records), also #692. The classification is a CLOSED SET over the arm
  table, not a hand-list: `methods.rs`'s `every_built_in_method_arm_is_classified` PARSES
  `encode_method_call` with `syn` and fails on an arm in neither list or a listed name with no arm,
  over a measured floor of 40 arms — a regex could not tell an arm pattern from a string literal
  inside an arm body. Guards: `rust/encoder/tests/mut_borrow_method_calls.rs` — three refused
  shapes (an index place, a field place, an inherited-opaque alias, an unclassified method) and
  six controls (a read-only method call through the borrow, a user-declared method through it, the
  modelled plain-variable alias, an ordinary receiver, an unclassified method on an ordinary
  receiver keeping the catch-all diagnostic, and shadowing). No conformance fixture exercises it: `rust/compiler/src/lvalue.rs` only ever binds
  `(&mut <var>)`, which is `AliasTarget::Variable`, so the round-trip corpus is structurally blind
  to the whole `Opaque` class — which is exactly why #693's assignment-only wiring survived review.
- **The runtime's COLLECTION constructors and the compiler's CLASS PROLOGUE (#692).**
  `runtime_ctors.rs` is the sibling of `runtime_helpers.rs` for the two shapes that are not base
  CALLS at all. `BallValue::List(x)`/`BallValue::Map(x)` join the `BallValue::String(…)` identity
  arm (a Ball value is dynamic, so the wrapper means nothing); `BallList::from(x)` is the same
  identity; `BallList::new()` is an empty list literal and `BallMap::new()` is `std.map_create`
  with no entries — the two nodes `dart/encoder` emits for `[]` and `{}`. Each arm defers to a
  file that declares its own type by that name, like the `enum_names` guard on `BallValue`.
  - **The message builder is matched as ONE BLOCK, not statement by statement.**
    `compile_message_creation` emits `{ let mut __ball_map = BallMap::new();
    __ball_map.insert("x".to_string(), …); BallValue::Message(BallMessage::new("main:Point",
    __ball_map)) }` — an imperative builder, not a literal. Taking it apart would need an inverse
    for `BallMap::insert` and would yield a *different* node (a block that mutates a map) from the
    `message_creation` it compiled from, so `block.rs::encode_message_builder` matches the whole
    idiom and gives the exact node back. The match is STRUCTURAL (a fresh `BallMap::new()`
    binding, every intermediate statement an `insert` on it, a tail that consumes it), never keyed
    on the compiler's `__ball_map` spelling; anything that is not the whole idiom falls through to
    ordinary block encoding and still fails loud on its unmapped `.insert()`.
  - **`pub fn __ball_register_types()` is the compiler's class prologue, and it is DROPPED.** Its
    `ball_register_superclass(child, parent)` calls invert to the child `TypeDefinition`'s
    `metadata.superclass` — where `dart/encoder` writes it and `type_emit::superclass_of` reads it
    back — and `fn main()`'s leading call to it is dropped in `block.rs`. Resolving the
    registration's SHORT `Dog` against a declared type has to undo `sanitize_ident`: the compiled
    struct for Ball's `main:Dog` is `main_Dog`, so `apply_superclass_registrations` accepts the
    short name itself or that name behind a `_`-joined qualifier, and fails loud on zero or
    multiple matches rather than losing a class relationship silently. Any statement in that
    function that is not a two-string-literal registration is a loud failure too, because the
    whole function is dropped.
  - Dropping the prologue is also what made the **whole-program fixpoint** reachable —
    `compile_reencode_roundtrip.rs::re_compiling_the_re_encoded_program_still_computes_the_same_answer`
    builds and RUNS both the first and the second compile. Before it, a second compile emitted
    `__ball_register_types` twice (`error[E0428]`). That run-proof is the only assertion that can
    tell the `message_creation` the builder compiles from apart from some other structurally valid
    node; `rust/encoder/tests/compiled_collection_ctors.rs` holds the shape assertions beside it.
  - **Known, stated gap:** the compiled `pub struct main_Dog` re-encodes as the `TypeDefinition`
    `main:main_Dog`, while the instances the same program builds still carry
    `BallMessage::new("main:Dog", …)`. That type-NAME infidelity predates #692 and is asserted
    (not papered over) in `the_compiled_class_registry_re_encodes_as_superclass_metadata`.
  - **Measured yield:** the `rust-roundtrip` row moved **100 -> 109** — of 358 when it was first
    measured (run 34803611448) and of 360 after this branch merged `main` (run 35550645549),
    because two fixtures joined the corpus and neither round-trips. Quote the PASSED count, not
    the ratio: the denominator moves with the corpus and the floor is on the numerator alone.
    Both buckets' fixtures now stop on their NEXT blocker — `101_simple_class`/
    `102_inheritance` on `ball_message_type_name` (#718). A closed bucket moves the histogram; it
    does not on its own make every fixture in it pass.
- **The IS/AS REGISTRY and the MAP/SET literal constructors (#692, second half).** Four more
  `ball_*` helpers that are not table rows — the table's contract is "one positional argument per
  input field" — so they have their own arms in `lib.rs::encode_runtime_helper_call`. Gate:
  `rust/encoder/tests/compiled_type_ops_and_literals.rs`.
  - **`ball_is`/`ball_is_not`/`ball_as`/`ball_is_type` -> `std.is`/`is_not`/`as`**
    (`runtime_helpers.rs::type_op_helper`). `ball_is_type` (`pattern.rs::type_check`, emitted for
    every pattern type test) maps to the SAME `std.is` as `ball_is`, because it is the same
    discrimination — `ball_is` is literally `BallValue::Bool(ball_is_type(&value, type_name))` —
    and its bare-`bool` result has no Ball counterpart, a condition site coercing truthiness
    implicitly. The second operand must be a string LITERAL (`std.is`'s `type` field is one in the
    Ball node too — `dart/encoder` writes `type.toSource()` into it), so a computed type name
    fails loud. `runtime_helpers.rs`'s old "no type-name string operands" exclusion is retired: it
    was keeping a supported shape out, not describing an unsupported one.
  - **`ball_map_create`/`ball_set_create`** are the NON-EMPTY map/set literals (`BallMap::new()`/
    `BallList::new()` above are only the empty ones). Their Ball inputs are *shaped*:
    `std.map_create` takes one repeated `entry` field per pair, each an anonymous `{key, value}`
    message-creation; `std.set_create` names its list `elements`.
  - **Match the operand AFTER encoding it, never on the `syn` tree.** A pair list arrives as
    `BallValue::List(BallList::from(vec![…]))`, three identity wrappers deep, and `encode_expr`
    already reduces all of them to the list literal underneath — `lib.rs::list_literal_elements`
    is the whole reader.
  - **The COMPREHENSION lowering fails loud on purpose.** `{for e in m.entries: k: v}` compiles to
    an imperative block that splices into a local `Vec` and hands `ball_map_create` that variable;
    its Ball node is a `map_create` with `element` fields, a different and larger inverse.
    Encoding it as an entry-less `map_create` would silently compute `{}` — the issue #55 class —
    so both helpers panic naming the shape. `a_map_create_over_a_spliced_list_fails_loud` and its
    set twin are the pins.
  - **Stated gap (pre-existing, surfaced here): every compiled STRING literal re-encodes wrapped
    in `std.to_string`.** `compile_expression` emits one as `BallValue::String("a".to_string())`,
    and `.to_string()` is not one of `methods.rs`'s identity passthroughs — in hand-written Rust
    it genuinely IS `std.to_string`, which over a `String` returns its operand unchanged. A
    node-fidelity difference, not a behavioural one; asserted (map KEYS come back as
    `std.to_string({value: "a"})`) rather than normalized away, so a change to it is loud.
  - **Measured yield:** the `rust-roundtrip` row moved **109 -> 124** of 361 (run 35556939950,
    job `Rust Round-Trip Leg (measurement)`), and `RUST_ROUNDTRIP_FLOOR` is raised to 124 in the
    same PR. All FOUR of #692's blockers left the first-blocker histogram entirely
    (`ball_map_create` 21, `ball_is_type` 18, `ball_set_create` 7, `ball_is` 3 -> zero each); the
    leaders are now `ball_arg_get` 61, `ball_message_type_name` 23 (#718),
    `ball_unsupported_base_call` 18 and `ball_iterate` 16. Quote the PASSED count, never the
    ratio — the denominator moves with the corpus and the floor is on the numerator alone.
- **Library mode (#491 slice 2).** `encode` requires a `fn main()`; `encode_library` (CLI:
  `ball encode --lib`) drops **only** that requirement — every other documented gap still panics.
  A library-mode `Program` carries `entry_module = "main"` (needed by `compile_library`, which
  looks that module up) and an **empty `entry_function`**, so it is deliberately NOT runnable:
  `ball check` reports `missing entry_function`, and that is the correct, documented boundary —
  never synthesise a fake entry function to silence it. The C# encoder's `EncodeLibrary` makes the
  identical call; keep the two consistent. Proof: `rust/encoder/tests/library_mode.rs` compiles the
  encoded program through `compile_library` and asserts `cargo build` accepts it as a real `[lib]`.

### Compiler ↔ encoder round trip — an invariant, not a nice-to-have (#632)

**Every construct `ball-lang-compiler` emits must be one `ball-lang-encoder` can read back.**
Tier A's stage 3 re-encodes this repo's OWN compiler output, so a construct the compiler emits
and its own encoder refuses caps that column no matter how good either half is on its own.

- It was not hypothetical: `type_emit.rs::compile_method_dispatchers` emitted its fallback arm as
  a bare `panic!`, `methods.rs::encode_macro` refused `panic!`, and **every** library whose
  compiled output carries a method dispatcher (i.e. every library with a struct and a method)
  failed stage 3 with ``unsupported macro invocation `panic!` ``. Neither crate's own tests could
  see it — `rust/compiler`'s assert on emitted Rust, `rust/encoder`'s start from hand-written
  Rust.
- The gate is `rust/encoder/tests/compile_reencode_roundtrip.rs`. Stage 3 is an **encode** gate for
  every program but one: the compiler's output names runtime helpers (`ball_message_type_name`, …)
  that are not user functions, so **re-compiling stage 3's output is not a fixpoint at large** —
  measured, and neither Tier A nor this test pretends otherwise. The single exception is #692's
  `re_compiling_the_re_encoded_program_still_computes_the_same_answer`, which builds and runs BOTH
  compiles of a program made of the constructs that slice taught the encoder; it became possible
  only once the class prologue stopped coming back as a user function. Since #646
  reading them is fail-loud: `encoder/src/runtime_helpers.rs` maps the helpers with a
  universal-`std` inverse and an UNMAPPED `ball_*` aborts the file rather than becoming a
  same-file call to a function nobody declared. That table is the universal-`std` subset only, so
  a compiled library naming any other helper stops at the first one — never read a green run of
  that file as "stage 3 is green for libraries at large". Sweep the difference, never quote it:
  `grep -ohrE '\bball_[a-z0-9_]+' rust/compiler/src/*.rs | sort -u` against the quoted names in
  `runtime_helpers.rs`. The behavioural half sits beside it, on the constructs
  themselves: three cases compile the compiler's own output, link it against a hand-written
  `main`, and RUN it, asserting the thrown message as bytes. A shape assertion alone would pass
  on a throw carrying the wrong message. Extend THAT test when you add a compiler emission shape;
  do not add a second, weaker round trip.
- `panic!` encodes to `std.throw` (field `value`), the same shape `dart/encoder`'s
  `ThrowExpression` arm emits and the same one this crate's `encode_unwrap` already used. The two
  really are one mechanism on this target: `runtime.rs::ball_throw` IS `std::panic::panic_any`,
  and `ball_catch_payload` re-wraps a non-Ball payload (what `panic!` carries) as
  `BallValue::String(message)` — so a `catch` binds the identical value either way. A bare
  `panic!()` carries Rust's own `explicit panic` message, never `""`.
- **`unreachable!` is mapped too, and for the same reason** — it is `panic!` with a fixed prefix
  (`library/core/src/panic.rs`'s `unreachable_2021` expands to
  `panic!("internal error: entered unreachable code: {}", format_args!(..))`), and the compiler
  EMITS it: `base_call.rs::flow_propagation` ends a `try` carrying a `break`/`continue` with no
  enclosing loop in exactly that macro. It encodes as the same `std.throw`, carrying Rust's whole
  message — **prefix included**, because that prefix is part of what a `catch` binds, and an
  encode-only assertion could not see it dropped. `an_unreachable_throws_rusts_own_internal_error_message`
  is the run-proof; `a_bare_unreachable_encodes_the_message_rust_itself_prints` pins the
  argument-less form, which must NOT carry a trailing `": "`.
- **Enumerate what the compiler emits; do not assume it is one construct.** #632 arrived as a
  single `panic!`. Sweeping `rust/compiler/src` for constructs inside EMITTED string literals
  found three more: `unreachable!` (`flow_propagation`), and — in `compile_list_literal`'s
  imperative lowering, used by EVERY spliced collection literal (`std.spread`, `null_spread`,
  `collection_if`, `collection_for`) — both `Vec::new()` and `matches!`. All four are closed
  (`unreachable!` mapped, the pair fixed compiler-side by #712). Re-run that sweep whenever you
  add an emission shape; everything past the first was invisible to the issue that named it.
- The dispatcher fallback's message is **target-neutral** — `no method '<name>' for <type>`,
  byte-identical to `go/compiler/library.go`'s `ballrt.Thrown` and
  `csharp/compiler/src/TypeEmit.cs`'s `BallRuntimeException`. It used to carry a
  `ball-lang-compiler runtime:` prefix no other target emits, which is the #616/#641
  error-rendering drift in a spot no fixture observed. Changing that spelling means re-running the
  round-trip gate, which asserts it on both sides.
- **Tier A's Rust row was dammed at STAGE 1, not stage 3** — measured on both sides of this fix
  (`1/77` at stage 1, 2 and 3 in runs 34766105061 and 34769384905; 76 files stopped at
  `encode-error`, none at `reencode-error`). So the `panic!` fix did not move the published
  funnel, and a lane that wants those numbers up works on stage 1's named reasons
  (`gh run download <run-id> -n coverage-study-tier-a-rust` — **never from prose**, which is how
  the six-gap list #767 collected went stale: `write!` had already closed by the time it was
  filed). Since #630 and #767 closed three of them, stage 1 is `9/77` and the dam has MOVED to
  stage 3, where every arriving file now stops on `ball_arg_get` (#790). The round-trip gate is
  what proves the compiler↔encoder invariant; the third-party funnel is a separate, slower
  instrument.
- The script-mode entry-point IIFE is **CLOSED**, and #687 with it. #646's
  `lib.rs::as_zero_arg_closure` inlines the closure body (pin flipped to
  `compiled_entry_point_iife_encodes`), which is sound for the entry wrapper — a Ball `return`
  returns from the enclosing FUNCTION, the IIFE exists only because Rust's `main` returns `()`,
  and the entry body IS the function body. The open half — "is the IIFE equally faithful for a
  NESTED block in value position" — was answered by #687's own run-proof, and the answer moved
  the fix to the ENCODER, not the compiler: `compile_block` emits a **native Rust block**, so the
  compiler never wraps a value-position block at all, but `as_zero_arg_closure` inlined every
  immediately-invoked closure in the HAND-WRITTEN Rust the encoder reads, which re-binds a
  `return` from the closure to the enclosing function. Inlining is now conditional on the body
  having no closure-bound early exit, and #687's `std.invoke`-over-`lambda` shape is what an
  early-exiting one gets. See the Encoder section's bullet on it, and `rust/AGENTS.md`'s
  "Immediately-invoked closures". The script-mode round-trip leg lives beside the library-mode
  ones in `compile_reencode_roundtrip.rs`.
- **The spliced collection-literal lowering (#712) is CLOSED, compiler-side.**
  `compile_list_literal` goes imperative the moment any element splices, so ONE lowering carried
  every spliced list, set and map literal there is — and it emitted
  `let mut __lit: Vec<BallValue> = Vec::new();` (refused as an associated fn on a foreign type,
  and measured as the FIRST refusal) with `if !matches!(__sp, BallValue::Null)` behind it. Closing
  it by teaching the encoder those arms was ruled out: that encodes compiler-internal spellings
  while still refusing every real-world one, which is what Tier A measures. What landed instead,
  in the plain-call vocabulary the neighbouring `ball_truthy`/`ball_iterate`/`ball_spread_iter`
  already use:
  - the accumulator is a **`BallList`** built with `.push()` — `runtime_ctors.rs` inverts
    `BallList::new()` to an empty list literal and `methods.rs` maps `.push()` to
    `std_collections.list_push`. No `mut`: `BallList::push` takes `&self`, so the tail is
    `BallValue::List(__lit)` directly;
  - the null guard is `ball_truthy(ball_not_equals(__sp.clone(), BallValue::Null))` — two helpers
    already in the table, composing to exactly `std.not_equals(__sp, null)`;
  - since #646 that vocabulary no longer re-encodes *soft*, so #712 also owed
    `runtime_helpers.rs` the inverses of the helpers the loops name: **`ball_iterate` joins
    `ball_truthy` as an identity passthrough** (the iteration coercion `std.for_in` performs
    implicitly — emitted at four sites, all for-loop iterables, so this widened re-encodability
    well past #712: every compiled `for-in` loop named it) and **`ball_spread_iter` maps to
    `std.spread`** (field `value`), the exact inverse of the line that emits it. Deliberately NOT
    the same mapping: the two differ on a portable set (`ball_iterate` yields `[key, value]` entry
    pairs, `ball_spread_iter` the backing items), so collapsing them would be silently wrong.

  Gated by `compile_reencode_roundtrip.rs::spliced_collection_literal_compiler_output_re_encodes`
  (all four spliceable element kinds in one literal, encode → compile → encode) plus the run-proof
  `a_spliced_collection_literal_still_splices_after_the_lowering_change`, which COMPILES AND RUNS
  it and diffs `[1, 2, 3, 4, 5, 6]` as bytes — an element that nested instead of splicing
  re-encodes just as cleanly and prints a different answer (#39/#300). The `documented_gaps.rs`
  pin is flipped to `compiled_spliced_list_literal_re_encodes`;
  `the_matches_macro_is_a_documented_gap` KEEPS its `#[should_panic]`, now pinning the encoder's
  **permanent** boundary for hand-written Rust rather than a compiler emission. The **map**
  comprehension got the same lowering fix but keeps one refusal — `ball_map_create` over the local
  accumulator. #692 (#796) gave that helper a table arm AFTER #712 was written, so the refusal is
  now a SHAPE one from that arm, not the unmapped-helper fallthrough: it inverts a LITERAL
  `[[key, value], …]` list to the `entry`-shaped `std.map_create` it compiled from, and the
  comprehension's Ball node is a larger `map_create` carrying `element` fields instead. Pinned as
  `compiled_spliced_map_literal_stops_at_ball_map_create` (the compiler-output half of
  `a_map_create_over_a_spliced_list_fails_loud`).
- The invariant has **one** OPEN instance left, pinned fail-loud in `documented_gaps.rs`:
  - the compiled **method dispatcher's scrutinee**, tracked as **#718**, and the one that turned
    `main` red: `compile_method_dispatchers` opens every instance-method dispatcher with
    `match ball_message_type_name(&__self).as_str()`, and that helper has no universal-`std`
    inverse. It returns the receiver's module-QUALIFIED tag (`main:Point`); `std.type_of` (#489)
    returns the SHORT base name, prefix stripped — so mapping one to the other would re-encode a
    dispatcher whose arms can never match its own scrutinee, and `dart/shared/std.json` declares
    no qualified-name function to map it to instead. It is a semantic merge conflict between #646
    (the fail-loud table) and #685 (the first test that re-encodes a dispatcher), each green
    alone. Pinned by `compiled_method_dispatcher_scrutinee_is_a_documented_gap`; the dispatcher's
    behavioural half is untouched and still run-proved by
    `dispatcher_fallback_throws_the_target_neutral_message`. Whatever closes it must keep #646's
    fail-loud direction.

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++: compile
  `dart/self_host/engine.ball.json` through `ball-lang-compiler` into `src/compiled_engine.rs`.
- **Status: complete, runs at Dart parity** (#39/#300). The compiled engine builds and runs the
  whole corpus with Dart-identical output: `Results: 363 passed, 0 failed, 363 total` (the 4
  golden-less resource-limit/sandbox fixtures 196/197/201/202 are behavioral carve-outs skipped
  like the Dart runner). The `self_host` cargo feature gates the compiled-engine driver (the
  generated `compiled_engine.rs` is a gitignored build artifact); a default build without it
  stays green on the wrapper foundation. Regenerate + run: `cargo run -p ball-engine-regen` then
  `cargo test -p ball-lang-engine --features self_host --test self_host_conformance -- --ignored`.
- Fixes to engine behavior belong in `rust/compiler/` or `ball_lang_shared::runtime` (or the Dart
  self-host source, then regenerate) — **never** hand-patch `compiled_engine.rs`. When a fixture
  diverges from Dart, check whether the divergence is in the compiler's emitted code (a compiler
  fix + regen) or in a runtime helper the emitted code calls (a `ball_lang_shared::runtime` fix, no
  regen) — the final-24 close-out was split roughly evenly between the two.

## Generated Files — NEVER Edit

- `rust/shared/gen/*.rs` — protobuf bindings from the `buf.build/community/neoeinstein-prost`
  plugin (root `buf.gen.yaml`; there is no official `protocolbuffers/rust` plugin). Regenerate
  via `buf generate`.
- `rust/engine/src/compiled_engine.rs` — gitignored (like C++'s `engine_rt.cpp`), regenerated
  via `cargo run -p ball-engine-regen`.

## Testing

- **Third-party coverage study, Tier A (#493).** `rust/tools/rq1-study` (crate
  `ball-rq1-study`, `publish = false`, a workspace member so it is built/formatted/
  linted with everything else) runs real pinned crates through
  `encode_library` -> `compile_library` -> `encode_library`, diffs the declaration
  inventory with **`syn` directly** (never the encoder's own walk) and checks a
  second-generation fixpoint. It is CRATE-AWARE since #491's `encode_crate`
  slice: each package's `mod` graph is walked once and every file it reached is
  encoded with the crate's symbol table in hand (`rq1-study --single-file`
  turns that off and reproduces the older per-file measurement, so a
  before/after is one binary over one checkout; each JSON row's `crateModule`
  says which way that file was measured). **Tier A scores LIBRARY code only
  since 2026-09-14** (the owner's methodology decision on #491): a file under a
  PACKAGE-ROOT `tests/`/`benches/`/`examples/` directory (a sibling of `src/` —
  a Cargo target; `src/tests/` is NOT one, #637), or one the crate's `mod` graph
  reaches ONLY through a `#[cfg(test)]` module, is excluded from the denominator
  and counted on the harness's own `excluded (test-only): N` line. **The
  reachability half is anchored on a CRATE ROOT, and a missing anchor is FATAL
  since #648**: `crate_root()` searches `lib.rs`/`main.rs`/`src/lib.rs`/
  `src/main.rs` under the studied subtree, and not finding one used to return an
  empty exclusion set and carry on — switching the only working half of the rule
  off, readmitting all 34 files, and letting `coverage_table.py` ratchet UP on
  the jump in `scored`. It now errors, naming every path searched. A subtree that
  really has no crate root declares it, per pin, with `"crateRoot": "none"` (CLI:
  `--no-crate-root`); no pin needs it today, and any other value of that key is
  itself an error. `coverage_table.py` is the second line of defence: `excluded`
  dropping to 0 while `scored` rises by at least that many files is a breach
  naming the readmitted population, never a raise. That took 34
  of `bitflags`' files out — all 34 by reachability, since `src/tests.rs` and
  `src/tests/*.rs` alike are only reached through `#[cfg(test)] mod tests;` — so
  the denominator is **77, not the 110 every #491 histogram in this file and in
  `rust/AGENTS.md` is written against**; read those as history. Honest baseline,
  **0/77 clean, 9/77 encoded** (1/77 before #630's `write!` slice, 7/77 before
  #767's tuple + reference-`impl`-self-type slice) — the encoders' documented
  gaps (proc-macro / `#[derive]` item invocations, the unmapped `assert!` family,
  `core::fmt`'s `.finish()` debug-builder chain, tuple/array `impl` self types)
  are in essentially every real crate file, and a file that
  clears one lands on the next. A closed gap category usually moves the
  histogram, not the aggregate; the crate-aware slice was the first one to move
  the aggregate at all, and it moved it by one file, then #630's `write!` slice
  took it 1 -> 7 and #767's 7 -> 9. `clean` has never moved and none of those
  moved it — its remaining walls are **#790**
  (``unsupported runtime helper `ball_arg_get(...)` `` stops EVERY file that
  reaches stage 3, which is why #767 raised `encoded`/`compiledBack` and left
  `reencoded` at 1; this used to read #632, whose own
  wall #685 closed on main while #630 was open — re-measure before quoting one) and
  declaration drift. The 5 pinned crates are `itertools`, `smallvec`, `bitflags`, `heck`,
  `strsim` (`tools/coverage-study/packages/rust.json`), not the original 10-crate
  #491 set. **Always point `CARGO_TARGET_DIR` at a path inside the current
  worktree** — a target dir shared with another lane serves a stale `rlib` and
  produces a false red that reproduces nowhere in your own diff. `cargo test -p
  ball-rq1-study` (the harness's own self-test) IS gated on every PR in the `rust`
  job; the RUN is the `rust-tier-a` job in `coverage-study.yml`, which
  has **no `pull_request:` trigger** (its row is floored by ratchet in that
  workflow's `publish` job). Methodology:
  `tests/conformance/COVERAGE_STUDY.md`.

- **The std module builders are a PORT of Dart's and are gated name-for-name** (#505).
  `rust/shared/src/std_dart_parity.rs` (a `#[cfg(test)]` module) scans
  `dart/shared/lib/<module>.dart` for `_fn('name'` registrations and each
  `std_*_module.rs`'s `function_names_match_dart_source` test asserts the Rust builder declares
  exactly that set. These used to be bare `assert_eq!(module.functions.len(), N)` counts, which
  can only notice a change made in Rust — that is how this crate silently fell thirteen functions
  behind when Dart declared its routed-but-undeclared std functions. **When you add or remove a
  `_fn(...)` in `dart/shared/lib/std*.dart`, port it here in the same PR**; a hardcoded count is
  never an acceptable substitute for the name-for-name check. C# has the same contract
  (`csharp/shared/test/StdModuleBuilderTests.cs`); Go/Python/TS/C++ have no std module builders.
  Since #557 each module ALSO has a `function_output_types_match_dart_source` test:
  the name gate cannot see a declared-TYPE drift, and that is exactly how
  `set_add`/`set_remove` kept `outputType: ""` here after #545 declared `'bool'`
  in Dart — both sides green, the cross-target contract split. Port the
  `outputType` too, not just the name.
- **`is BallRawMap` is the engine's own raw-map probe, and this crate answers it
  (#557).** `ball_is_type`'s `"Map"` arm deliberately EXCLUDES a tagged set so a
  user program's `{1,2} is Map` is `false` (#528/#553) — but the self-hosted
  engine's `_ballValueIsSet` needs the opposite answer for its OWN
  representation, and with only `is Map` to ask with it was permanently `false`
  here, so every in-place set mutation the engine performed went to a throwaway
  copy. `BallRawMap` (a typedef in `dart/engine/lib/engine_types.dart`) is that
  second question, answered structurally: `matches!(value, BallValue::Map(_))`,
  no exclusion. Conformance fixture `462_set_mutation_in_place` is the guard.
- `cargo test --workspace` from `rust/` (via WSL). `ball-lang-engine`'s compiled-engine driver is
  feature-gated off by default, so this stays green without depending on #39.
- `rust/engine/tests/roundtrip_conformance.rs` is a whole-corpus measurement sweep
  (#452 item 3): Ball → Rust → Ball → the **Dart** reference engine → golden diff, all in-process
  except the Dart run (no per-fixture `rustc`, ~7 s for 321 fixtures). It measured a flat **0/321**
  from the day it shipped until #642 — the encoder refused the compiler's own output outright: the
  unconditional `pub static Expression_Expr: LazyLock<BallValue>` namespaces, the
  `(|| -> BallValue { … })()` IIFE the entry body is wrapped in, and the
  `BallValue::String(…)`/`BallValue::Null` constructors every literal becomes. The compiler now
  emits a oneof namespace only when the compiled text mentions it
  (`type_emit::oneof_discriminator_enum_defs`), and `lib.rs` recognises the IIFE
  (`as_zero_arg_closure`) and the `BallValue` constructors; `rust/encoder/tests/compiler_output.rs`
  is the fast guard. `#[ignore]` so `cargo test --workspace` never picks it up; run it with
  `cargo test -p ball-lang-engine --test roundtrip_conformance -- --ignored --nocapture`
  (`BALL_DART` overrides the launcher). Its CI home is the `rust-roundtrip` row in
  `conformance-matrix.yml`, which **is a PR gate since #619** and **floored + ratcheted since
  #642**: harness health PLUS `passed >= 1` PLUS `passed >= RUST_ROUNDTRIP_FLOOR`, enforced by
  `tools/ci/roundtrip_floor.sh`. Still NOT a parity gate — but a flat zero is red, and the floor
  only rises. **Raise it in the SAME PR as the fix that earned it**; the job prints the exact new
  value. **A fixture that HANGS is its own hard error since #693**, never one more increment of
  `failed`: the per-fixture budget is `BALL_TIMEOUT_MS` (default 60 000, fail-loud on a
  non-integer) and `roundtrip_floor.sh` reds the row on any `FAILING [name] timeout` line (C#'s
  row passes its own `  <name>: TIMEOUT` pattern). The kill itself is self-tested on a fabricated
  runaway — `a_runaway_fixture_is_killed_at_the_budget_and_reported_as_a_timeout`, and
  `the_repo_root_handed_to_the_dart_cli_is_not_a_verbatim_path` (#692; `canonicalize` returns a
  `\\?\` path on Windows, `dart run` rejects one on stderr and **exits 0**, so every local Windows
  run of the sweep reported a phantom `0 passed` — CI, on ubuntu, was never affected). Those are
  the only non-`#[ignore]`d tests in that target, so `cargo test --workspace` runs them on every
  PR. The remaining gap is named in the row's own step summary with the issue tracking it, never
  as an "expected baseline". #692's own two buckets are CLOSED — the leg moved **100 -> 109**
  (of 358 at run 34803611448, of 360 at run 35550645549 after two more fixtures joined the
  corpus) — and #712's spliced collection-literal fix, with the `ball_iterate`/
  `ball_spread_iter` inverses it owed, took it **109 -> 121 of 361** (run 35557346693): every
  fixture whose compiled output carries a `for-in` loop or a spliced literal re-encodes now.
  At 121 the row's own "first still-failing fixture" line names `ball_message_type_name`
  (#718); re-measure the other leaders from a run artifact rather than quoting the pre-#712
  figures, which were taken at 109. **#692's 124 and #712's 121 are two INDEPENDENT measurements
  against the same 109 baseline, each taken on its own branch — never add them.** The merged tree
  MEASURES **138 of 362** (run 35561847017, job 106216902719) and that is what
  `RUST_ROUNDTRIP_FLOOR` carries: the number a run printed, never one derived from two. The
  leader at 138 is still `ball_message_type_name` (#718). The
  method-dispatcher `panic!` sub-case (#632) is a DIFFERENT metric — it moves Tier A, not this
  leg.
- `cargo test -p ball-lang-compiler` / `cargo test -p ball-lang-encoder` include `tests/end_to_end.rs`
  suites that compile emitted Rust with the **real `cargo run`/`rustc`** and assert on actual
  stdout — prefer extending these (or, once #40 lands, `tests/conformance/` fixtures) over
  Rust-only unit tests, per the repo-wide "prefer conformance tests" rule.
- No `tests/conformance/*.ball.json` runner exists for Rust yet (#40) — do not claim conformance
  parity in commit messages or docs until it does.

## Dependencies

- `prost = "0.14.4"` + `prost-reflect = "0.16.4"` — pinned exact versions; `prost-reflect`'s
  `DescriptorPool`/`DynamicMessage` are required for descriptor-driven `MessageCreation`/
  `google.protobuf.Struct` metadata work. Google's upb-based `protobuf` v4 crate has no
  reflection API and was rejected.
- `indexmap = "2"` — backs `BallMap`; insertion-ordered like every other engine's map type
  (Dart's `LinkedHashMap`, C++'s `BallOrderedMap`). Never substitute `HashMap` for Ball-value
  maps.
- `syn = "2"` (`features = ["full", "extra-traits", "visit", "visit-mut"]`) + `proc-macro2` +
  `quote` — encoder's Rust parser. `visit-mut` drives the macro-expansion pre-pass and the hygiene
  rename; `visit` drives `closure_body_exits_early`, the read-only walk that decides whether an
  immediately-invoked closure may be inlined (#687).
- `ra_ap_mbe` / `ra_ap_tt` / `ra_ap_span` / `ra_ap_intern`, all `"=0.0.351"`, plus `salsa = "0.28"`
  and `serde_json = "1"` — **`ball-lang-macro-expand` only** (#629). The `=` pins are mandatory:
  `ra_ap_mbe` pins its own siblings with `=`, so a mixed set does not resolve. These republish
  weekly with rust-analyzer, so **dependabot's `cargo-minor-patch` group will file no-op PRs
  against them**; bump all four together and deliberately, never one at a time.
