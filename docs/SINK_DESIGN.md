# Mutable output sinks — design record

**Issue:** [#630](https://github.com/Ball-Lang/ball/issues/630) — *represent mutable output sinks so
`write!`/`writeln!` encode*. Owner-approved 2026-09-13; landed by
[#636](https://github.com/Ball-Lang/ball/pull/636) (the declarations, engines, compilers, runtimes and
conformance fixture) and [#698](https://github.com/Ball-Lang/ball/pull/698) (the Rust encoder rule).

This is the normative record for **what a Ball sink is** and **how each source language's sink
constructs map onto it**. It is the document to read before adding sink support to another encoder,
another compiler, or another target. Status and remaining work live in GitHub issues, not here.

---

## 1. The problem

Every source language Ball encodes has a *mutable output sink*: an append-only text accumulator
passed by reference, written into, and finally read back as a string. Rust has
`&mut fmt::Formatter` / `impl fmt::Write` / `&mut String`, Dart has `StringBuffer`/`StringSink`, C#
`StringBuilder`/`TextWriter`, Go `strings.Builder`/`io.Writer`, Python `io.StringIO`, TypeScript a
`string[]` joined at the end, C++ `std::ostringstream`.

Ball had **no declared value for one**. `std_io` prints, `std` concatenates strings, and nothing
modelled accumulation. What it did have was an *undeclared, divergent, partially-implemented* sink: a
`__type__`-tagged map carrying `__buffer__`, hardcoded by name in the Dart engine (buffer: a
`String`), in the TS engine (buffer: an `Array` — and, in a second registration in the same file, a
`String` again, issue #633), and in the TS compiler preamble (an `Array`) — and implemented **nowhere**
in the Rust/C#/Go/Python/C++ compilers or runtimes, so a compiled Ball program using a `StringBuffer`
had no `write` at all on five of seven targets. `dart/shared/lib/cli_core.dart` documents avoiding
`StringBuffer` in portable code for exactly that reason. That is issue #505's shape one level up:
implemented by hardcoded name, declared nowhere, divergent where it exists, silently absent where it
does not.

## 2. The declarations

Three base functions in the **universal `std`** module (`dart/shared/lib/std.dart`), with three input
types beside them:

```
sink_create(initial?) -> Sink        SinkCreateInput   { string initial = 1; }
sink_write(sink, text) -> null       SinkWriteInput    { <sink> sink = 1; string text = 2; }
sink_to_string(sink) -> String       SinkToStringInput { <sink> sink = 1; }
```

**`std`, not `std_io`** (the issue body proposed `std_io`). `dart/shared/lib/capability_table.dart`
derives `ball audit`'s capability report from module membership, and `std_io`'s own module description
is *"Not available in all runtimes (browser, WASM, embedded)"*. A string builder performs no I/O and
exists in every runtime; declaring it in `std_io` would mark every string-building program
I/O-capable, changing `ball audit` output and the `cli_core` parity golden for nothing.

**Exactly three.** `writeln` desugars to `write` + `"\n"` (Rust `core` itself defines
`writeln!($dst)` as `write!($dst, "\n")`), `writeCharCode` to `write` + `string_from_char_code`, and
`.length`/`.isEmpty`/`.isNotEmpty` to the existing string ops over `sink_to_string`.
`clear`/`writeAll` stay on the Dart-SDK method surface and are deliberately not declared; revisit when
a source construct needs them.

## 3. Runtime contract (normative)

`sink_create(initial?)` returns a `Sink`. `sink_write(sink, text)` appends `text` to its contents.
`sink_to_string(sink)` returns `initial` followed by every appended `text`, in order.
`std.type_of(sink)` answers `"Sink"`.

**The sink is reference-semantic:** passing it to a function and appending there is observable by the
caller.

ONE representation on every target makes both of those fall out instead of being re-derived seven
times: **a reference-semantic map tagged `__type__ = "std:Sink"` carrying a `__buffer__` string.**
Every target's `type_of` already reads a `__type__` tag off a map, and every target's map is already
reference-semantic.

| target | backing |
|---|---|
| Dart engine (`engine_std.dart`) — the source all six self-hosted engines are generated from | `__type__`-tagged map, **portable Dart only** (a plain map literal lowers to a by-value `std::map` in the C++ self-host) |
| Dart compiler | `Map<String, dynamic>` (a reference type), `_ballSinkCreate` |
| TypeScript compiler / engine | plain object, `__ball_sink_create` |
| Rust compiler / `ball-lang-shared` | `BallValue::Map` = `Arc<Mutex<IndexMap>>`, `ball_sink_create` |
| C# compiler / `Ball.Shared` | `BallMap` (a reference type), `BallRuntime.SinkCreate` |
| Go compiler / `ballrt` | `*ballrt.Map` (a **pointer**), `ballrt.SinkCreate` |
| Python compiler / `ballrt` | `dict`, `ballrt.sink_create` |
| C++ compiler / `ball_dyn.h` | `BallOrderedMap`, `shared_ptr`-wrapped by `BallDyn` |

`__buffer__` is a **`String`** on every target — one shape, so `sink_to_string` is a read rather
than a per-target join, and so the two incompatible TypeScript registrations of #633 cannot recur.

**Reference semantics is the half that fails silently.** A target backing the sink with a by-value
type (a bare `String`, a `strings.Builder` *value*, a copied `ostringstream`) loses every append made
through a function boundary, with no error anywhere — the shape of issue #300, where
`rust/shared/src/value.rs` holds `BallList` behind `Arc<Mutex<…>>` precisely because *"a plain
by-value `Vec<BallValue>` clone … copied on every call, so those appends were lost"*, and of
`dart/engine/lib/engine_eval.dart`'s note that a plain map literal lowers to a by-value `std::map` in
the C++ self-host. That is why conformance fixture `tests/conformance/466_string_sink.ball.json`
writes **across a function boundary**, and why each target's unit test asserts both
`type_of(sink) == "Sink"` and an append performed inside a callee.

`type_of` is deliberately **not** asserted by the conformance fixture: goldens are produced by running
the fixture's Dart source natively, and real Dart's `StringBuffer().runtimeType.toString()` is
`"StringBuffer"`. A golden asserting `"Sink"` would be one the oracle cannot produce. The contract is
pinned per target in unit tests instead — see `docs/TESTING_STRATEGY.md` §5b.

## 4. How each source language maps on

| language | sink type(s) | create | write | read back |
|---|---|---|---|---|
| Rust | `&mut fmt::Formatter`, `impl fmt::Write`, `&mut String` | `String::new()` | `write!` / `write_str` | the `String` |
| Dart | `StringBuffer`, `StringSink`, `IOSink` | `StringBuffer()` | `write` / `writeln` / `writeAll` / `writeCharCode` | `toString()` |
| C# | `StringBuilder`, `TextWriter` | `new StringBuilder()` | `Append` / `AppendLine` | `ToString()` |
| Go | `strings.Builder`, `bytes.Buffer`, `io.Writer` | `&strings.Builder{}` | `WriteString` / `WriteRune` | `String()` |
| Python | `io.StringIO` | `io.StringIO()` | `write` | `getvalue()` |
| TypeScript | `string[]` + `join`, or `+=` | `[]` | `push` | `join("")` |
| C++ | `std::ostringstream` | default ctor | `operator<<` | `.str()` |

Every one is append-only text accumulation with a terminal read, and every one's `writeln`-flavoured
variant is `write` + `"\n"`. The three declarations are exactly that common denominator.

## 5. The Rust encoder rule for `write!` / `writeln!`

**`write!` needs no type information, and that is the whole design.** `core`'s own definition is

```rust
($dst:expr, $($arg:tt)*) => { $dst.write_fmt($crate::format_args!($($arg)*)) };
```

— the destination is a **method receiver**, so the first argument **is** the sink by construction.
rustc special-cases only `format_args!` (rust-lang/rust#106745 moved it into the AST), and
rust-analyzer makes the identical split: `format_args`/`format_args_nl` are builtin expanders,
`write!`/`writeln!` go through the ordinary `macro_rules!` path in `core`. A source-to-IR tool that
wants `write!` does not special-case it; it lets the destination fall out as a receiver.

That is not a theoretical convenience. In the Tier A Rust corpus, **6 of the 7 files first blocked by
`write!` write through an unannotated closure parameter** (`|f| write!(f, "-")` in `heck`). Any design
needing to infer the destination's type is dead on arrival for them.

`rust/encoder/src/methods.rs::encode_write_macro` therefore classifies the destination by **syntax
alone**, in three closed cases:

| destination | emitted |
|---|---|
| anything that is not a local binding — a parameter, a field, a closure parameter, a call result | `std.sink_write{sink, text}` |
| a bare name bound by a `let` whose initialiser is a `String` constructor | `std.assign{target: s, value: std.concat(s, text), op: "="}` |
| a bare name bound by a `let` of any other shape | a **loud refusal** naming the local and its initialiser |

The second row is the **join-sites** rule. In `itertools::join` the same local is *also* read as a
`String` in the same function (returned, length-tested), so turning it into an opaque sink would
silently change every one of those reads; and a genuine local `String` silently treated as a sink
would lose them. Guessing either way is a behaviour change, so the third row refuses rather than pick.
The accepted initialiser set is `String::new()`, `String::with_capacity(..)`, `String::from(..)`,
`"literal".to_string()`/`.to_owned()`, and `format!(..)` — a *wider* guess here would silently turn a
non-`String` local into a re-assignment.

`writeln!` is `write!` plus a `"\n"` part, exactly how `core` spells its own no-argument arm. Both
arms are wrapped in the unified `Ok(..)` outcome message, because `write!` evaluates to a
`fmt::Result` which real call sites immediately consume with `?` or `.unwrap()`; `?` applied to a
non-outcome value is a silent-degradation seed.

Three supporting mechanisms ship with the rule:

* **`Encoder::local_scopes`** — a stack of binding frames: one per fn / closure / `impl` method /
  default-bodied trait method body, seeded with that body's parameters, **and one per `{ .. }`
  block** inside it, since a block's `let`s are gone at its closing brace. Each frame is filled with
  its `let`s as they are encoded (recorded *after* the initialiser, so `let s = s;` still reads the
  outer `s`). Lookup is innermost-first, so a closure's own `f`, or a nested block's own `f`, shadows
  a same-named enclosing local. It is deliberately **separate** from `push_fn_scope`: that one
  records parameters only for a 2+-parameter body (its `input`-aliasing rule) and an `impl` method
  pushes no fn scope at all — either would leave a parameter looking like a local, and a parameter
  misread as a local `String` is exactly the silent miscompile the frame exists to prevent.
* **A `&mut` alias binding resolves to the variable it borrows, before classification.**
  `let slot = &mut s;` is recorded in `Encoder::ref_aliases` and emits no `let` at all (issue #642 —
  Ball has no references, so binding it as a value would turn every write through it into a write to
  a copy), and every read of `slot` resolves back to `s` in `lib.rs::encode_path_expr`. A `write!`
  destination is a read like any other, so the classifier resolves the bare name through that table
  first: `write!(slot, ..)` and `write!(&mut s, ..)` are the same write and take the same arm, in
  both directions — an alias of a local `String` is re-assigned, an alias of a sink parameter stays
  `std.sink_write` on the parameter. Skipping the resolution is not a *silent* error (an alias is
  never recorded in a binding frame, so the local `String` would take the sink arm and every target
  rejects a non-sink loudly) but it answers at run time a question this encoder already has the
  answer to at encode time. Tests:
  `write_sinks.rs::a_write_through_a_mut_alias_re_assigns_the_local_string_it_borrows` and
  `::a_write_through_a_mut_alias_of_a_sink_parameter_stays_a_sink_write`.
* **`String::new()` / `String::with_capacity(n)` encode as the empty string.** Both were in the
  encoder's "unsupported call target" bucket, so the local-`String` arm would have been unreachable.
  Capacity is an allocation hint with no observable effect on what a program computes, and Ball has
  no allocation model to carry it into. Every other `Type::assoc()` on a foreign type stays the
  documented gap it was.

Failure modes, all loud and all named: an empty `write!` body panics naming the macro; a format string
that is not a string literal, and a placeholder/argument count mismatch, reuse the existing
format-macro refusals; a local destination that is not a `String` constructor panics naming the local
and its initialiser. Tests: `rust/encoder/tests/write_sinks.rs`.

**Known boundary of the syntax-only rule, and why it is safe.** A `String` that reaches a `write!`
as anything other than a local `let` takes the sink arm. Two shapes: a local handed to *another*
function which writes into it (`let mut s = String::new(); helper(&mut s);`), where the caller's `s`
encodes as a Ball `String` and `helper`'s parameter as a sink; and a `String` **field**
(`write!(self.out, ..)`), which has no `let` to classify. Either way the encoded program passes a
string where `std.sink_write` expects a sink. That mismatch is **loud on
every target** — each engine's sink helper proves the value is a tagged sink before touching it
(`dart/engine/lib/engine_std.dart::_stdSinkBacking`: *"Fail loud rather than fabricating an empty
sink: silently accepting a non-sink would turn every mis-routed `sink_write` into a discarded
write"*), and each compiler's runtime does the same. Neither shape occurs in the Tier A corpus.
Closing them needs knowledge of how the destination is used *elsewhere* — a resolution-time question
for `encode_crate`, not a `write!` question — so they stay a loud refusal rather than a guess.

**A *pattern* binding is a binding, and takes the sink arm.** A for-loop variable, a `match`-arm
binding and an `if let` binding all introduce a name without a `let`, so `record_local` — whose only
call site is the `let` handling — never sees one. Left unrecorded a pattern binding is not merely
unknown but **invisible**: the innermost-first lookup walks straight past it to whatever *enclosing*
binding wears the same name, and an enclosing local `String` is the one kind that does not fail loud.
`let mut s = String::new(); for s in writers.iter_mut() { write!(s, "x")?; }` encoded as a
re-assignment of the **outer** `s`, losing every write the Rust aims at an element, with nothing
reporting it — the one silent direction the rule still had. `Encoder::with_pattern_binding` opens a
frame for each of the three constructs (and drops a `&mut` alias of that name for its duration,
exactly as a plain `let` of it does), so the binding shadows.

What it shadows *to* is the **sink** arm, the one every non-`let` destination takes — not a loud
refusal. The re-assignment arm is not even expressible for a pattern binding: `s = concat(s, ..)`
would write to the loop variable, and whether that reaches the collection is not something Ball
models. And `for w in writers.iter_mut() { write!(w, ..) }` over real sinks is an ordinary working
shape that must keep encoding. When the element is a plain `String` instead, the write lands in
exactly the documented boundary above — a string where `std.sink_write` expects a sink, which every
engine and runtime rejects **loudly** at run time. Tests:
`write_sinks.rs::a_for_loop_variable_shadows_an_enclosing_local_string`, the `if let` and `match`
siblings, `::a_for_loop_variable_shadows_a_mut_alias_binding`, and the positive control
`::a_for_loop_variable_that_shadows_nothing_is_still_a_sink` — which is what makes the choice
falsifiable, since "refuse every pattern binding" would pass the other four.

## 6. Options considered, and why they were rejected

**(a) Desugar to string concatenation on a provably-local `String`, alone.** Measured on the Tier A
Rust corpus: it closes **0** of the files first-blocked by `write!` and 2 of 25 invocations. 22 sinks
are `&mut fmt::Formatter` *parameters* and 2 are a generic `W: fmt::Write` parameter — a parameter has
no initialiser to prove anything about, and the 6 `heck` closure parameters have no type annotation at
all.

**(b) A universal sink abstraction, alone.** Cannot handle the `itertools::join` sites, where the same
local is also read as a `String` in the same function.

**(b-variant) Reuse existing std — a sink as a `List<String>` (`list_add` + `list_join`).** Tempting:
zero new declarations, every target already implements both, already fixtured. **Rejected.** It
conflates two distinct source-language types: once the C#/Dart/Go/Python encoders gain sink support, a
`StringBuilder` and a `List<string>` would encode to the same Ball type, so the compiled-back C# of a
method taking a `StringBuilder` would take a `List<string>` — a changed public API that round-trips
syntactically clean. That is precisely the issue #488 class Tier B exists to catch and Tier A
structurally cannot see. It would also make `std.type_of(sink)` answer `"List"`.

**(c) Both** — adopted. Every site in the corpus falls into exactly one of the two arms, decided by
syntax alone.

## 7. Citations

1. `write!` is a method call on the destination — `library/core/src/macros/mod.rs`:
   `($dst:expr, $($arg:tt)*) => { $dst.write_fmt($crate::format_args!($($arg)*)) };` and
   `writeln!`: `($dst:expr $(,)?) => { $crate::write!($dst, "\n") };`.
2. <https://doc.rust-lang.org/std/macro.write.html> — *"The writer may be any value with a `write_fmt`
   method; generally this comes from an implementation of either the `fmt::Write` or the `io::Write`
   trait."* … *"The macro returns whatever the `write_fmt` method returns; commonly a `fmt::Result`, or
   an `io::Result`."*
3. <https://doc.rust-lang.org/std/fmt/trait.Write.html> — *"A trait for writing or formatting into
   Unicode-accepting buffers or streams."* … *"`String` implements this trait."*
4. <https://doc.rust-lang.org/std/fmt/struct.Formatter.html> — `impl Write for Formatter<'_>`.
5. rustc treats only `format_args!` specially — rust-lang/rust#106745, *"Move format_args!() into AST
   (and expand it during AST lowering)"*; compiler-team#541.
6. rust-analyzer makes the same split —
   <https://rust-lang.github.io/rust-analyzer/src/hir_expand/builtin/fn_macro.rs.html>: `format_args`,
   `const_format_args`, `format_args_nl` are builtin expanders; `write!`/`writeln!` are not.
7. <https://doc.rust-lang.org/std/string/struct.String.html#method.with_capacity> — capacity is an
   allocation hint: *"the string will be able to hold at least `capacity` bytes without reallocating"*.
8. <https://api.dart.dev/stable/dart-core/StringSink-class.html> — `write()`, `writeln()`;
   implementers `StringBuffer`, `IOSink`, `ClosableStringSink`.
9. <https://pkg.go.dev/strings#Builder> — *"The zero value is ready to use. **Do not copy a non-zero
   Builder.**"* (§3's reference-semantics requirement in Go's own words).
10. <https://docs.python.org/3/library/io.html#io.StringIO> — *"A text stream using an in-memory text
    buffer."*; `getvalue()`.
11. <https://learn.microsoft.com/en-us/dotnet/api/system.text.stringbuilder> — *"Represents a mutable
    string of characters."*; `Append(String)`; `ToString()`.
