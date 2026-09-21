---
paths:
  - "cpp/**"
---

# C++ Specific Instructions

## Build System

- C++20 standard required (set in cpp/CMakeLists.txt:4)
- CMake build system — root at `cpp/CMakeLists.txt`
- Primary targets: `ball_shared`, `ball_cpp_compile` (compiler), `ball_cpp_encode` (encoder), `ball` (unified CLI — `cpp/cli/`, issue #367) — plus library targets and test executables (see the `CMakeLists.txt` files)
- Self-hosted engine: `dart/self_host/lib/engine_rt.cpp` (generated from Dart engine via Ball compiler)
- Self-host conformance: `test_selfhost_conformance` target
- Unified `ball` CLI (`cpp/cli/`): subcommands `compile`/`encode` (reuse the compiler/encoder libs), `run` (self-hosted `engine_rt`), and `info`/`validate`/`tree`/`version` (self-hosted `cli_core`, library-compiled to the generated `dart/self_host/lib/cli_rt.h` via `gen_cli_cpp.dart`). Verbs/run gate on their generated artifacts (stubbed when absent, so the build-isolated main cpp CI job still builds `ball`). Parity gate: `test_cli_parity` (see `cpp/cli/AGENTS.md`).
- Dart-free distribution channels get the real verbs from the **self-host sidecar** (issues #368/#361): `release-cpp.yml` publishes `dart/self_host/lib/{cli_rt.h,engine_rt.cpp}` as the release asset `ball-selfhost-cpp-src-vX.Y.Z.tar.gz`, and `tools/vcpkg-port/`'s portfile downloads + unpacks it into `${SOURCE_PATH}/dart/self_host/lib/` before configuring (default-on `selfhost` feature; `ball-lang[core]` opts out). Never rename that asset on one side only — `tools/vcpkg-port/test/test_selfhost_asset_wiring.sh` pins both spellings, and a mismatch costs every future release its verbs silently.
- Encoder requires nlohmann/json (FetchContent from GitHub if not installed)
- Stack sizes: compiler 128MB, encoder 256MB (for deep protobuf ASTs)

```bash
cd cpp/build && cmake .. && cmake --build .
```

## Buf CLI Integration

CMake integrates with `buf` CLI for protobuf code generation, linting, and formatting.

- **`BufGenerate.cmake`** (`cpp/cmake/`) — CMake module providing `buf_generate_cpp()`, `buf_add_lint_target()`, `buf_add_breaking_target()`, `buf_add_format_target()`
- When `buf` is on PATH: protos regenerate into the build tree when `ball.proto` changes
- #18 Stage 5: the C++ build is libprotobuf-free — there is NO C++ protobuf codegen, no `cpp/shared/gen/`, and no cpp plugin in `buf.gen.yaml`. `buf` is used only for proto lint/breaking/format.

### CMake Targets

| Target | Command | Description |
|--------|---------|-------------|
| `buf_lint` | `cmake --build build --target buf_lint` | Lint proto schema |
| `buf_breaking` | `cmake --build build --target buf_breaking` | Check backward compatibility |
| `buf_format` | `cmake --build build --target buf_format` | Check proto formatting |
| `buf_check` | `cmake --build build --target buf_check` | Lint + format in one shot |

### Manual generation (without CMake)

```bash
# From repo root:
# (no C++ codegen since #18 Stage 5 — C++ is libprotobuf-free; buf is proto lint/format only)
```

## Architecture

### Shared (`cpp/shared/`)
- `BallValue` = `std::any` (runtime polymorphism)
- `BallList` = `std::vector<BallValue>`
- `BallMap` = `std::map<std::string, BallValue>` (ORDERED — not unordered_map)
- `BallFunction` = `std::function<BallValue(BallValue)>`
- Module builders: `build_std_module()`, `build_std_memory_module()`, etc.

### Compiler (`cpp/compiler/`)
- Ball → C++ code generation via string concatenation
- Blocks compiled as immediately-invoked lambdas
- Base function dispatch maps std functions to C++ operators/calls
- Type mapping: int → int64_t, double → double, String → std::string, List → std::vector<std::any>

#### Class-dispatch rules that are easy to get wrong

- **Method-shortcut dispatch is arity-gated (#511).** `compile_method_call`'s 77
  STL/Dart-SDK shortcuts are keyed on the method NAME, so each one carries the
  arity window of the Dart method it stands for (`argc_in(min, max)`); the 33
  names shared with `dart/encoder/lib/encoder.dart`'s `collectionRoutes` reuse
  that table's windows verbatim. A new shortcut MUST get a window, and a window
  MISS must FALL THROUGH (never `return`) so control reaches the user-defined
  class method dispatch below the chain. Too narrow pushes a real std call into
  the generic fallback; too wide re-opens the collision.
- **Shadowed-getter routing is PER CLASS, never program-wide (#515).**
  `shadowed_getter_names_` is a whole-program name set and must not decide a
  dispatch on its own. Use `class_field_shadows_getter` /`class_has_getter` /
  `class_has_own_field`, which are keyed by the SANITIZED bare class name —
  `class_shadowed_fields_`/`class_getters_` are keyed by the QUALIFIED name
  (`"main:B"`), so a lookup with `current_class_name_` silently misses. For an
  external receiver, resolve its class with `static_class_of()` and fall back
  EXPLICITLY when it cannot be proven; never guess "not shadowed".
- **A `final` field declared beside a same-named SETTER reuses the #501
  backing-member lowering — with only the GETTER half (#664).** Dart allows the
  pair (a `final` field contributes a getter and nothing else, so the explicit
  setter is the only setter for that name — `collection`'s `ListSlice`); C++ has
  no such split, and g++ rejects a data member `length` beside a member function
  `length(v)` outright ("conflicts with a previous declaration"). The
  shadowed-field analysis therefore also marks a field whose OWN class declares
  a setter of that name, so `emit_struct` stores it under
  `shadow_backing_name()` and re-exposes the name as a public accessor — but
  `class_setter_backed_fields_` suppresses the implicit SETTER half, which would
  redefine the user's own member. Two consequences: the read path's
  receiver-scoped branch now answers "getter" for any
  `class_field_shadows_getter` field (for a #501 field `class_has_getter`
  already did, via the ancestor that declares it; here there IS no ancestor
  getter), and these fields are deliberately NOT added to the program-wide
  `shadowed_getter_names_` — widening that would reroute an unrelated class's
  plain `obj.length = v` into a setter it does not have. A write whose receiver
  class cannot be proven therefore names the private backing member and fails to
  BUILD: loud, never silent. Conformance `470_setter_beside_final_field` is the
  guard; the self-hosted engine declares **zero** setters, so `engine_rt.cpp` is
  provably untouched by this branch.
- **The `.length` / `.isEmpty` / `.isNotEmpty` shortcuts yield to a receiver
  whose own class DECLARES that name (#664).** Those three sit near the top of
  `compile_field_access`, ahead of the getter / struct-field dispatch, and used
  to fire unconditionally — so a class declaring `final int length` compiled
  `slice.length` to `ball_length(slice)`, the instance's ELEMENT COUNT, with no
  error anywhere. They are now skipped when `receiver_class_of` PROVES a class
  that declares the name as a getter, an own field, or a shadow-backed accessor;
  an unprovable receiver keeps the virtual property, which is the behaviour that
  predates this. Scoped exactly like every other receiver-scoped decision here
  (#515). Note `.isEmpty` rarely reaches this code at all — the Dart encoder's
  `unaryRoutes` turns it into `std.string_is_empty` (that is why conformance
  `115_generic_class`'s `Stack.isEmpty` getter never tripped it) — so `length`
  is the reachable case and `470_setter_beside_final_field` is its guard, with
  `cpp/test/test_compiler.cpp`'s
  `length_on_a_class_that_declares_it_is_the_field_not_ball_length` as the fast
  gate. `475_instance_field_named_length` (#681) is the second gate, and the
  plainest shape of the same collision — a mutable `int length;` with no getter
  and no shadowing field, so `class_has_own_field` alone carries it — read
  externally, read unqualified from inside the class, and read again after a
  write, with a list, a string and a map as the controls proving `.length` still
  answers for real collections.
  **#697 extended that predicate to the NUMERIC family too** — `.isNaN`,
  `.isFinite`, `.isInfinite`, `.isNegative`, which used to fire unconditionally
  a few lines below, so a class declaring `bool isNaN` compiled `b.isNaN` to
  `ball_isNaN(b)`: "is this OBJECT a NaN double", always `false`, and the emitted
  C++ compiles and runs, it just answers wrong. That is why the predicate is now
  the named `declared_by_receiver` lambda rather than an inline `bool` — ONE
  predicate, two families. `.sign` needed nothing (this compiler never had a
  shortcut for it). The gate is
  `476_user_member_named_like_builtin_accessor`, which declares every routed
  accessor name as a user member and reads each back, beside the `String` /
  `List` / `int` / `double` receivers whose shortcut must survive; it surfaced
  the defect on the e2e leg as `expected true/false/true, actual false/false/false`.
  `cpp/test/test_compiler.cpp` carries the fast gate for both families.
  **The field half of the predicate asks the whole INHERITANCE CHAIN**
  (`class_chain_has_field`), not just this class's own descriptor fields — the
  #697 follow-up. `class_getters_by_sname_` is FLATTENED over the chain when the
  metadata is built, but `class_own_fields_by_sname_` is strictly own-fields by
  name and by construction, so an inherited `int get length` proved the receiver
  while an inherited plain `int length;` did not, and `child.length` on a
  subclass whose BASE declares the field compiled to `ball_length(child)`. It is
  #681's defect reached from the one side its table could not see, and it is
  invisible to every engine row (they resolve a plain `fieldAccess` own-key-first
  through the `__super__` chain) — only the `C++ Compiled` row can fail it.
  `class_has_own_field` keeps its narrow meaning for the #513 slot decisions
  that depend on it; the widened question is asked ONLY where the
  accessor-shadowing decision is made. Fixture
  `476_…`'s `CountedChild` half is the cross-target gate, and
  `numeric_predicate_inherited_from_a_base_class_is_the_field` /
  `collection_property_inherited_from_a_base_class_is_the_field` are the fast
  ones. Every one of those fast gates asserts what the emit must CONTAIN
  (`(*this).isNaN`) alongside what it must not — a refusal-only test also passes
  for an emit that dropped the access entirely.
  **The cross-target fixture's inherited reads use the NUMERIC family on
  purpose.** An INHERITED field of the COLLECTION family (`isEmpty` /
  `isNotEmpty` / `length`) still reads back `null` from a subclass receiver on
  this target — **issue #800**, a THIRD defect, separate from both #697 halves
  and from the chain walk above: the emitted access correctly names the member
  (`compiler_tests` proves that), so the loss happens after emission, at
  construction or member resolution. It is `C++ Compiled` only; every engine row
  answers the same program correctly, because they resolve a plain `fieldAccess`
  own-key-first through `__super__`. Do not re-add those lines to fixture `476_…`
  until #800 lands — the issue body carries them verbatim, and restoring them is
  the whole reproduction.
  The guard covers those SEVEN names. The sibling shortcuts further down in
  `compile_field_access` — `.entries`, `.keys`, `.values`, `.first`, `.last`,
  `.runtimeType` — are still unconditional, so a class declaring one of those
  names as a plain field reads back the map/iterable emulation instead of the
  field: the same defect #681 fixes for `length`, still live for its siblings,
  and **this target only** (they encode as plain `fieldAccess` nodes, which every
  engine resolves own-key-first).
  Corroborating measurement: the first draft of `475_instance_field_named_length`
  carried `int keys; int values; int entries;` and failed the `C++ Compiled` row
  (`Results: 351 passed, 1 failed, 352 total`, run 34768683903) while the
  `Dart Engine` and Rust / C# / Go / Python rows passed it — though that run
  cannot attribute the failure to those three fields alone, since the same draft
  carried `length` too and this guard had not landed. Extending
  `declared_by_receiver` to that last group needs its own fixture first, exactly
  as the numeric family got `476_…`; do not widen the guard without one.
- **A subclassed class is never passed or returned by value (#516).** C++ struct
  value semantics slice the derived part (vtable included) away. Parameters go
  through `map_param_type()` (`T&` when `class_is_subclassed(T)`), and
  `map_return_type()` emits the concrete class the body provably returns. Both
  are scoped to subclassed classes only — a leaf class keeps by-value emission,
  and nothing is universalized into `BallDyn`.
- **A class-typed FIELD is erased to `BallDyn`; recover it before naming a
  member (#513).** `emit_struct` maps every non-primitive descriptor field to a
  `BallDyn` member, and `map_type` answers `BallDyn` for every `T?`, so a
  receiver that is a class-typed field, or a `T?` local/parameter, is a BallDyn
  at the C++ level even though it holds a struct. Resolve it with
  `receiver_class_of()` (which widens `static_class_of()` with the DECLARED
  types recorded in `local_declared_types_` / `class_field_decl_types_by_sname_`
  and looks past the `std.null_check` a Dart `!` encodes to), ask
  `receiver_is_erased()`, and wrap the receiver in `ball_obj_as<C>(…)` before
  emitting the struct-member or accessor form. The bracket fallback must keep
  reading the untouched BallDyn. The same receiver-scoped proof is what lets a
  field literally named `value` / `fields` / `kind` / `values` take the struct
  path — that four-name skip list exists for map-backed proto-shaped receivers,
  not for a concrete class that declares such a field.
  **Both spellings of a field are the same slot (#488).** Inside its own class a
  field is normally named BARE (`leaf`, not `this.leaf`) — `compile_reference`
  emits the plain member name for it — so `receiver_class_of()` /
  `receiver_is_erased()` answer for that Reference through
  `declared_field_class_of_own_name()`, with the same getter/shadowed-field
  refusals the FieldAccess branch uses and `declared_locals_` shadowing first. A
  local/parameter of that name wins, exactly as in Dart.
- **`BallDyn` accepts a compiler-emitted struct (#513).** `ball_is_user_struct`
  SFINAEs on the `static __ball_type_name()` every emitted struct carries — no
  standard-library or runtime type has it — so the constructor cannot steal
  overload resolution from the `BallMap` / `BallList` / typed-`std::vector`
  ones. It boxes through `BallUserRef`, so `ball_obj_as<T>` recovers the struct
  and `ball_identical` compares pointers. Without it, `f(root)` into a `Node?`
  (BallDyn) parameter needed two user-defined conversions and did not compile.
- **A constructor body is not always a Block (#513).** `Chain(this.depth) { if
  (…) … }` encodes to a single `std.if` Call. Emit every constructor body
  through `compile_ctor_body()`, never a Block-only loop — the old loops dropped
  a single-expression body silently, so the constructor ran and did nothing. A
  NAMED constructor additionally lowers to a STATIC factory over a local
  `__obj`, so its body needs `ctor_obj_prefix_` set: a bare own-field reference
  has no `this` to resolve against there.
- **An instance creation is a VALUE, not an argument bag (#523).** The Ball
  encoder gives a call's argument bag an EMPTY `typeName` (or a std input
  message name like `PrintInput`); only an instance creation names a user class.
  Check `is_instance_creation_value()` FIRST in `compile_call_arguments` and in
  the `.new` constructor-call path — matching a class's own fields against the
  callee's parameter names places nothing and drops the argument entirely. TS
  fixed the same bug class under #213.
- **A `let` bound to a CALL takes the callee's emitted return type (#524).**
  `map_return_type()` is the single source of truth for that type, #516's
  concrete-class widening included, and it covers a named constructor
  (`static <Class> from(...)`) as well as a top-level function. The only callee
  whose emission does not follow it is a FACTORY constructor (always
  `static BallDyn`). Declaring the local `BallDyn` erases every member;
  declaring it with the callee's *declared* base type slices.

- **`ClassName() = default;` is only emitted when no user constructor ALREADY
  is the zero-argument one (#514).** `emit_struct` synthesises a defaulted
  default constructor so `return ClassName()` compiles in a class that has user
  constructors. When the class's only constructor is itself zero-argument, the
  two declarations collide and g++ rejects the struct with
  "'Flags::Flags()' cannot be overloaded with 'Flags::Flags()'". Only a REAL
  C++ constructor can collide, so the scan skips `is_factory` ones (static
  methods) and named ones (static factories) - a class whose sole constructor is
  `Foo.named(...)` still needs the synthesised default.
- **`Foo.new(x)` is a CONSTRUCTOR TEAR-OFF, not a static method (#531).** The
  Dart encoder emits it as a generic self-carrying call
  (`{function: "new", input: {self: Reference("Foo"), arg0: ...}}`), which the
  `has_self` dispatch routes into `compile_method_call` before either
  constructor path can see it. `sanitize_name("new")` is `new_` (`new` is a C++
  keyword), so the static-dispatch branch emitted `Foo::new_(x)` - a member no
  emitted struct declares. Route `fn == "new"` to plain `Foo(args)` construction
  unless `class_has_factory_new(cls)` (a real `factory Foo.new`, the one shape
  that genuinely compiles to `Foo::new_`). The `throw` arm needs its own branch
  for the same shape: `call.function` is the bare string "new", so the
  `mod:Foo.new` identifier parsing finds no type name and leaves the generic
  "Exception" tag - take it from `self` instead. A BUILT-IN exception
  (`is_builtin_exception_name`) must land its first argument in
  `BallException::fields["message"]`, because a typed catch compiles `e.message`
  to `e.fields.at("message")`; `_ball_make_exception` stores it under `value`
  instead and aborts with `map::at`.
- **A constructor's field write is gated on `is_this`, never on a name
  collision or a param/field COUNT (#561).** `ctor_params`/`ctor_defaults`
  (which decide whether a field keeps its own inline initializer, or degrades
  to an unseeded nullable `BallDyn`) must be built with
  `extract_is_this_flags`, never a bare `extract_params` - a PLAIN parameter
  that merely shares a field's name binds nothing, not even when it belongs to
  a different constructor of the same class. The old "auto-assign" heuristic
  that positionally wrote every param into every field whenever the counts
  matched is gone with NO replacement (it emitted `Holder(auto b) : seen(b)`
  from a class-typed parameter, which g++ rejects outright): a plain
  parameter's effect on a field comes from an explicit colon-initializer or a
  body assignment, both already handled. And a constructor's OWN parameters
  must be seeded into `declared_locals_` before its body compiles, mirroring
  the method-emission pattern - a NAMED constructor's body runs in a static
  factory with no `this`, so an own-field reference is rewritten to
  `__obj.<field>` unless `declared_locals_` proves the name is shadowed. Seed
  the named branch with the PLAIN parameters ONLY: Dart routes both reads and
  writes of a `this.`-formal's name in the body to the FIELD (`Baz.tagged(
  this.v) { v = 99; }` leaves `v == 99`), so those must keep the `__obj.`
  rewrite.

- **`is BallRawMap` is the self-hosted engine's own raw-map probe, and the `is`
  codegen answers it (#557).** The `is Map` arms all carry
  `&& !ball_is_ball_set(...)` so a user program's `{1,2} is Map` is `false`
  (#68/#528) — but the compiled engine's `_ballValueIsSet` needs the OPPOSITE
  answer for its own `{'__ball_set__': [...]}` representation, and with only
  `is Map` to ask with it was permanently `false`, so every in-place set
  mutation the compiled engine performed went to a throwaway copy while reads
  still looked right. `BallRawMap` (a typedef in
  `dart/engine/lib/engine_types.dart`) is that second question, emitted as a
  bare `ball_is_map_dyn(...)` with NO set exclusion, in both the `is`/`is_not`
  codegen and `_typeCheckCondition`. Conformance fixture
  `462_set_mutation_in_place` is the guard; the whole `ctest -L selfhost` sweep
  passes with it.

- **`std_collections.list_find` THROWS when nothing matches (#597).** It is Dart's
  `Iterable.firstWhere` WITHOUT `orElse` — what its own declaration in
  `dart/shared/lib/std_collections.dart` says ("Find first:
  list.firstWhere(callback)") and what the Dart reference engine does
  (`engine_std.dart`: `throw StateError('No element')`). Never a `null`/
  `undefined`/empty placeholder, and never an untyped throw: the thrown value
  must carry the type name `StateError` so the program's own `on StateError
  catch` sees it. `tests/conformance/463_list_find_no_match` is the cross-target
  guard; `cpp/test/test_compiler.cpp`'s `list_find` assertions (the emitted lambda throws `BallException("StateError", "Bad state: No element")`, mirroring `list_reduce`; it must never fall off the end with `return BallDyn();`) is this target's half. See `docs/TESTING_STRATEGY.md` §5b.

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
  reference-semantics leg) plus this target's own tag test — `cpp/test/test_compiler.cpp`'s `string_sink_emits_the_runtime_helpers`.
  Backing: `ball_sink_create`/`ball_sink_write`/`ball_sink_to_string` in `ball_dyn.h`, over a `BallOrderedMap` that `BallDyn` wraps in a `shared_ptr` — which is what makes the callee's append visible. `_ball_sink_backing` takes its `BallDyn` **by value** on purpose: a copy shares the same `BallOrderedMapRef`, and a by-value parameter is what lets a `const BallDyn&` call site reach the non-const accessor. Editing `ball_dyn.h` needs a compiler REBUILD — it is embedded into every emitted program via the generated `ball_dyn_embed.h`.
- **`.first`/`.last`/`.single` guard their own emptiness (#616).**
  `BallDyn::front()`/`back()` answer a default-constructed (null) `BallDyn` for an
  empty list and `[0]` answers the FIRST element of a longer one, so the emitted
  `list_first`/`list_last`/`list_single` wrap an explicit check and throw
  `BallException("StateError"s, "Bad state: No element"s)` (and
  `"Bad state: Too many elements"s`) — the same silent-placeholder defect
  `list_find` had before #597. The runtime helpers are deliberately left alone:
  the compiled engine reaches them on paths that have already checked. C++ was
  ALREADY correct on the message text that issue #616's title flagged — it is the
  only target that spelled Dart's `toString()` all along.
  See `docs/TESTING_STRATEGY.md` §5b.

- **A CAUGHT exception renders through ONE table (#640).**
  `catch (e) { print('$e'); }` lowers to `ball_to_string(e)`, and the `try`
  lowering binds `e` two ways — `const BallException&` when any clause is typed,
  a reified `BallDyn` (`_ball_caught_to_dyn`) when none is. Both route through
  `_ball_dart_error_to_string` in `cpp/shared/include/ball_emit_runtime.h`
  (#616's closed table: `StateError` → `Bad state`, `FormatException`,
  `RangeError`, nothing else — the same three rows as Go's `dartErrorToString`
  and C#'s `DartErrorToString`; the siblings also carry a `TypeError` row, which
  this table deliberately does not — see the #641 bullet below for why there is
  no prefix for it to hold).
  Key on the `message` FIELD, never on the type
  name alone: a literal `throw StateError('boom')` keeps its ctor argument in
  `fields` with `what()` = the bare type name, while `_ball_make_exception`
  already carries the canonical `toString()` string in `what()` with no fields —
  prefixing that one again reads `Bad state: Bad state: No element`. Edit the
  header, never the spliced copies (`*_embed.h` are generated at configure time,
  `cpp/shared/ball_protobuf_rt.h` by the compiler). Full table and guards:
  `cpp/AGENTS.md` → "Rendering a CAUGHT exception".

- **`cpp/shared/ball_protobuf_rt.h` is regenerated and diffed by CI (#708).**
  It is the C++ target's one COMMITTED generated artifact — Ball's own
  `ball_protobuf` runtime compiled Ball → C++ in `--library` mode — and it
  carries a SPLICED COPY of the compiler's runtime preamble. Change the preamble
  (`cpp/compiler/src/compiler.cpp` or `cpp/shared/include/ball_emit_runtime.h`)
  and this file is stale until it is regenerated. Nothing noticed for four
  months: it froze at #398 with the two-argument `ball_cast_assert` #659
  replaced and none of #630's `sink` handling. The gate is the `cpp` job's
  Linux leg (`Regenerate` + `Assert the committed ball_protobuf C++ runtime`),
  and it is the ONLY one — never add a second regeneration pass. Red run →
  the fixed bytes are the run's `regenerated-cpp-protobuf-rt` artifact. See
  `cpp/shared/AGENTS.md` → "Freshness".

- **A caught `TypeError` reads as Dart's own message, and the rendering table is
  CLOSED by a test (#641).** A failed cast pattern raises `TypeError`, and Dart
  spells it
  `type '<runtime type>' is not a subtype of type '<target>' in type cast` —
  naming the VALUE's type first, and with **no** `TypeError: ` prefix, because
  `_TypeError.toString()` IS its message (the odd one out of the four built-ins).
  Every target used to spell `type cast failed: not a <T>` and then render it a
  different way; the canonical form is real Dart's because
  `generate_conformance.dart` builds a golden by RUNNING the fixture's Dart
  source on the SDK. The emitted `ball_cast_assert` takes the subject as a `BallDyn` now.
  C++ needs no `TypeError` ROW in the #640 table above: `ball_cast_assert` uses
  the 2-argument, no-`fields` ctor, so the `message` lookup misses and
  `ball_to_string(const BallException&)` returns `what()` — the canonical string
  the THROWER already carried. That also means there is nothing for a row to
  hold, since Dart spells this one with no prefix at all.
  `tests/conformance/467_caught_type_error_to_string` is the cross-target guard,
  and `tools/check_error_rendering_tables.py` (`Proto Checks`, every PR, with its
  own self-test) is the structural one. C++ is the single target it marks
  `coverage_exempt`, and that exemption is narrow: it excuses C++ from needing a
  row for a name whose thrower carries the string, and excuses it from NOTHING
  else — the three rows the table does hold are checked against Dart's spellings
  exactly like Go's, C#'s, Rust's and TS's, with a negative control in the
  self-test proving that check fires. Add a new built-in error here and to that
  contract in the same PR, or the checker fails.

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
  This target needed only the `ArgumentError` row: #640's `arg0` -> `message`
  rename in the throw lowering already had it ahead of every sibling.

### Encoder (`cpp/encoder/`)
- Clang JSON AST → Ball program (`clang -Xclang -ast-dump=json`)
- C++ pointer/reference ops are inlined to universal std/std_memory during encoding (no separate normalizer)
- Recursion limit: 512 for encoder, 10000 for protobuf

### Self-Hosted Engine (`dart/self_host/lib/engine_rt.cpp`)
- Generated from the Dart reference engine via Ball IR → C++ compiler
- Regenerate: `cd dart && dart run compiler/tool/compile_engine_cpp.dart` — it takes NO arguments. There is exactly ONE self-host C++ emit shape, `engine_rt.cpp`. Issue #601 deleted the multi-TU `--split`/`--shards` emit that used to be this tool's DEFAULT (and `--monolithic`, the flag that opted out of it): that output had never compiled, and `cpp/test/CMakeLists.txt` PREFERRED it whenever it was present, so the documented default handed you an engine that could not build. The `C++ self-host: exactly one emit shape (#601)` step in `regression-gates.yml` keeps it that way — it fails if a `dart/self_host/lib/engine_rt/` tree appears, if the tool names a shape-selecting flag again, or if `cpp/` re-acquires an `engine_rt_common.hpp` preference
- Conformance: `ctest -L selfhost` — one CTest test per fixture, each run in its own process (a crash/hang fails only that fixture). Run a single fixture directly: `test_selfhost_conformance <fixture_stem>` (the `BALL_TEST_FILTER=<stem>` env var also works)

## Test Harness

C++ tests live in `cpp/test/test_compiler.cpp`, `cpp/test/test_selfhost_conformance.cpp`, and `cpp/test/test_encoder.cpp` and use a custom `TEST(name)` macro framework (no gtest). Build + run via:

```bash
cd cpp && cmake --build build --target test_compiler test_selfhost_conformance
./build/test/Debug/test_compiler.exe
# Self-host conformance: one CTest test per fixture, each isolated in its own
# process (a crash/hang fails only that fixture). Run all, or a single fixture:
ctest --test-dir build -L selfhost -j4 --output-on-failure
./build/test/Debug/test_selfhost_conformance.exe 01_hello_world
```

### CI time budget + the e2e build knobs (#521)

`ctest` in ci.yml's `cpp` job runs with `-j <runner CPUs> --no-tests=error`, and
its `Run tests` step carries a **step-level `timeout-minutes`: 13 on Windows, 8
on Linux/macOS** (job budget 25), against a pre-fix 28m33s / 12m12s / 9m56s.
Those numbers are a gate, not decoration — a change that puts the fixture
compiles back on one core, or that costs the leg its compiler cache, fails the
job. Re-measure and update them (with the run id, as the workflow comment does)
if you change what the step does.

Size them against the **cold**-cache run, never the warm one. Warm, the
Linux/macOS step is 11s / 19s; cold it is 5m19s / 4m57s (run 33698642352, with
`ccache -s` showing 22 hits of 292 cacheable calls). A cold cache is normal and
blameless — every PR that touches the Ball->C++ emitter or
`cpp/shared/include/ball_dyn.h` changes all ~297 generated TUs, as does a cache
eviction or a first run on a new key — so a budget sized to the warm number
red-lights a required check on an innocent PR.

Windows' 13 was re-derived the same way in #594, once that leg had a cache that
is actually applied: **14m27s uncached** (run 34727102995) -> **8m51s cold with
every fixture compile a miss** (run 34728878760) -> **1m12s warm** at 318 of 318
hits (run 34729468858, whole job 2m02s against 19 min on main); 13 min is ~47%
over the COLD number and still fails a regression back to the uncached
behaviour. It stays the
loosest of the three by measurement, not assumption: each generated fixture is a
~278 KB TU pulling 29 standard headers, and MSVC needs ~1000s of front-end CPU
for ~297 of them when nothing is cached. The generator was never the cost (a
Ninja scratch build measured 590s against MSBuild's 591s) — it is simply the one
CMake honours a compiler launcher for.

Two env knobs drive the per-fixture compiles; CI sets both, and they work the
same way for `test_e2e`, `full_e2e.sh` and `quick_e2e.sh`:

| Env | Meaning |
|-----|---------|
| `BALL_E2E_JOBS` | Fixture compiles to run concurrently. Default: `hardware_concurrency()` / `nproc`. `1` restores the old serial behaviour. |
| `BALL_E2E_LAUNCHER` | Compiler launcher (`ccache` / `sccache`) for the fixture compiles, so an unchanged fixture is a cache hit. Empty/unset = none. |

`BALL_E2E_LAUNCHER` is set on **all three** legs since #594 (`ccache` on
Linux/macOS, `sccache` on Windows). It used to be Linux/macOS only: CMake
honours `<LANG>_COMPILER_LAUNCHER` for the Makefile and Ninja generators, and
the Visual Studio (MSBuild) generator — the `windows-latest` default — ignores
it, so the Windows leg compiled everything uncached for months while staying
green (main run 33673078770's `Post ccache` reported `Compile requests 0`; the
parent build's `-DCMAKE_CXX_COMPILER_LAUNCHER=sccache` was a no-op there too).

Five things have to be true, and each is now pinned by CI rather than by prose:

1. **Windows configures with `-G Ninja`** (`ilammy/msvc-dev-cmd` supplies the
   MSVC environment Ninja needs; `ninja` is preinstalled on the runner image).
   `test_e2e`'s scratch project inherits the generator via
   `BALL_E2E_GENERATOR`, so this fixes the parent build and the fixtures.
2. **The scratch project pins `CMAKE_BUILD_TYPE` to empty** (`test_e2e.cpp`).
   CMake's MSVC module initialises an *unset* build type to Debug, and its
   `/Zi` writes a PDB shared by every TU of a target — a shape sccache refuses
   to cache. Without this the leg reported `Non-cacheable compilations 296`,
   i.e. every fixture, with a working launcher.
3. **A gate asserts the cache is used at all.** `cpp/test/check_compiler_cache_applied.sh`
   (run by the `Compiler cache applied (#594)` step, unit-tested via
   `--self-test` in the always-on `proto` job) fails when the job compiled > 0
   cacheable TUs and the cache recorded **zero requests**. It deliberately never
   asserts a hit *rate* — a cold cache is blameless; a launcher that is
   configured and ignored is not. A step-time budget cannot tell those apart,
   which is why this leg sat under its 20 min budget, permanently cold, for so
   long.
4. **The same gate asserts the cache does not DECLINE every compile** (#599).
   Point 2's failure shape leaves requests/hits/misses looking healthy while
   nothing is cached, so point 3's check is blind to it. The ceiling on
   non-cacheable compilations is **0 on all three legs**, measured from the
   gate's own step in three consecutive green main runs and recorded with those
   run ids in the script's header. Move it only against a fresh measurement.

   Both numbers come from a **machine-readable** form, never a human summary
   (#660): sccache's `Non-cacheable compilations <int>` line, and for ccache the
   sum of `ccache --print-stats`'s `FLAG_UNCACHEABLE` + `FLAG_ERROR` counters —
   which is exactly `total_calls - (hits + misses)`, the shortfall ccache itself
   derives its `Cacheable calls: <n> / <total>` line from. Parsing that human
   line is what the gate used to do — regex over the rendered row, then the
   first two numeric runs of `split($0, a, /[^0-9]+/)`. That is a required gate
   reading a **presentation layer**: `TextTable` sizes each column to the widest
   cell across *all* rows, so the row's rendering depends on unrelated rows, and
   ccache re-cuts the summary between releases. Any re-render the regex does not
   expect takes the C++ leg red with `could not read a non-cacheable compilation
   count` — red for a non-cache reason. (It is *not* a thousands-separator
   mis-count: ccache renders those cells with `fmt::format("{}", number)` and
   never groups them. That claim was written into this rule and the gate's own
   header before either was checked against ccache's source — `Cell::Cell(uint64_t)`
   in `src/util/TextTable.cpp` 4.9.1 / `src/ccache/util/texttable.cpp` 4.14.)
   The counter classification is
   version-pinned to the ccache the runners install — **4.9.1 on ubuntu-latest,
   4.14 on macos-latest**, whose tables differ by exactly one id — and lives in
   three lists at the top of the script; a counter id in none of them **fails
   the gate loud**, because a new uncacheable reason silently left out of the
   sum is the very state the ceiling exists to catch. `ccache -s` is still run,
   purely so the human numbers reach the log, and its failure is a hard error.
   So is a `ccache --version` the gate cannot read: since #700 it collects the
   version alongside the statistics, prints it on every run, and names it in the
   `UNCLASSIFIED CCACHE COUNTER ID(s)` / `MISSING CCACHE COUNTER ID(s)` failures
   with the remedy — `hendrikmuhs/ccache-action` installs the OS package and
   pins no version, so an image that moves ccache and grows a counter must not
   read as a cache regression. A version off `CCACHE_TABLE_VERSIONS` whose
   counters all classify stays GREEN and says so; the assertion is the counter
   set, never the version string.

5. **The gate step must run BEFORE the e2e smoke steps, and that is gated too**
   (#660). ubuntu's *post-job* `ccache -s` shows 4 uncacheable calls, which
   accrue later from `full_e2e.sh`'s compile-and-link smoke (a link is
   uncacheable by construction) and are not the gate's input — so the ceiling of
   0 is only correct because of the step order.
   `cpp/test/test_cache_gate_step_order.sh` (ci.yml's always-on `proto` job)
   asserts that order from ci.yml, plus that exactly one step runs the gate
   under the documented name, that at least one `full_e2e.sh` step exists (or
   the order assertion is vacuous), that the job is still one steps list over
   the 3-OS matrix, and that it carries no `continue-on-error`. It proves itself
   with negative controls on relocated / renamed / smoke-less copies of the real
   workflow. A reorder would red the ubuntu/macOS legs at 4 against a ceiling of
   0, with a cause that points at build types and shared PDBs while nothing has
   regressed.

Parallelism must never shrink coverage, so each harness asserts its own count:
`test_e2e` compares executed tests against `e2e_fixture_list.h` + 3 inline
programs, `full_e2e.sh`/`quick_e2e.sh` compare recorded outcomes against the
selected fixtures, and `cpp/test/CMakeLists.txt` fails at configure time if the
self-host fixture glob matches nothing.

`test_e2e` also writes its count line to `BALL_E2E_COVERAGE_FILE`
(`<build>/test/e2e_coverage.txt`), because `ctest --output-on-failure` prints
nothing for a passing test — the number would otherwise never appear in a green
log. ci.yml deletes that file before `ctest` and re-checks it afterwards
(`C++ e2e fixture coverage`), which also detects "the e2e test never ran".

Both shell harnesses run each fixture binary in a private empty directory, since
they execute fixtures concurrently (`test_e2e` parallelises only the build).
That is what makes concurrent execution safe for a future `std_fs` fixture; do
not drop it.

`full_e2e.sh` gets required-check coverage on every PR, from ONE step on the
Linux leg (`C++ compiled e2e — new/changed fixtures + harness slice`): the PR's
added/changed fixtures **plus** a derived four-fixture slice, in a single call.
Without it, the only thing exercising the harness is the `C++ Compiled` matrix
leg, which runs after merge. The two live in one invocation because
`full_e2e.sh`'s positive floor (`passed == 0 && failed == 0` ⇒ exit 1) is
per-invocation: a PR whose every changed fixture is a tracked
`CPP_COMPILE_CARVEOUTS` entry would otherwise run nothing and go red naming the
wrong cause. `472_initializer_list_field_with_setter` was that PR while #695 was
open; #680 closed #695 and `CPP_COMPILE_CARVEOUTS` is empty again, but the hole
is structural and outlives any one entry, so the widened filter stays. Widen the
filter — which is what the floor's own error message says — never delete the
floor or the carve-out.

### Fast local `test_compiler` without CMake

The full CMake build is 40+ minutes and does not work on native Windows, which
is why C++ work is usually gated on CI alone. `test_compiler` does not need it:
it links only `compiler.cpp`, `ball_shared.cpp` and `ball_rt_decode.cpp`, and the
only generated inputs are the two embed headers. That is a ~2-minute compile
with any C++20 compiler (clang++ works on Windows against the MSVC toolchain),
which turns a 40-minute CI round trip into a local edit/run loop — including
proving a unit test RED before a fix and green after.

```bash
T=$(mktemp -d)                       # scratch: embed headers + the binary
mkdir -p "$T/gen" "$T/include/nlohmann"
cmake -DIN=cpp/shared/include/ball_emit_runtime.h \
      -DOUT="$T/gen/ball_emit_runtime_embed.h" \
      -P cpp/shared/cmake/EmbedRuntimeHeader.cmake
cmake -DIN=cpp/shared/include/ball_dyn.h -DOUT="$T/gen/ball_dyn_embed.h" \
      -DVAR_NAME=BALL_DYN_SOURCE -P cpp/shared/cmake/EmbedRuntimeHeader.cmake
curl -sSL -o "$T/include/nlohmann/json.hpp" \
  https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp

clang++ -std=c++20 -O0 -w \
  -I cpp/compiler/include -I cpp/shared/include -I cpp/shared \
  -I "$T/gen" -I "$T/include" \
  -DBALL_CONFORMANCE_DIR="\"$PWD/tests/conformance\"" \
  cpp/test/test_compiler.cpp cpp/compiler/src/compiler.cpp \
  cpp/shared/src/ball_shared.cpp cpp/shared/ball_rt_decode.cpp \
  -o "$T/test_compiler" && "$T/test_compiler"
```

This covers `test_compiler` only. The compiled-fixture e2e and the self-hosted
engine still need the real build (CI), so it shortens the loop rather than
replacing the gate.

Four CI-plumbing shell tests need no C++ toolchain at all (sub-second, and run
in ci.yml's always-on `proto` job, so they gate every PR). Each prints a
`Results: N passed, M failed, T total` line and refuses to report success on
zero cases:

```bash
bash cpp/test/test_build_cov_floor_parsing.sh          # build-cov-floor.sh's parser + exit codes
bash cpp/test/test_cov_floor_ci_wiring.sh              # that coverage.yml actually RUNS it (#63/#59)
bash cpp/test/check_compiler_cache_applied.sh --self-test  # the cache gate's parsers + ceiling (#594/#599/#660)
bash cpp/test/test_cache_gate_step_order.sh            # that ci.yml runs the gate BEFORE the e2e smoke (#660)
```

## Coverage floors

`cpp/build-cov-floor.sh` owns the per-target line-coverage floors for
cpp/{compiler,encoder,shared}, and since #63/#59 `.github/workflows/coverage.yml`'s
cpp job **invokes it** — its exit code fails the step. The floors are a
regression ratchet derived from CI's own measurement minus a ~2pt variance
buffer, not a completion target (#63's target is 100%). Raise them as tests land;
never lower one to clear a red. The workflow step also asserts each per-target
tracefile is non-empty and that all three targets reported, because the script's
missing-tracefile branch is a deliberate non-fatal SKIP.

A fast, CI-equivalent local measurement (no nested per-fixture g++ builds) is the
`corpus_driver` target wired into `build-cov-build.sh` / `build-cov-run.sh` /
`build-cov-report.sh`. Read the aggregate from `lcov --summary`, never
`lcov --list` — its per-file Rate column is unreliable on a merged tracefile.

Two things routinely make a coverage number mean the opposite of what it looks
like, so check both before writing a test against a "dead" line:

- **`cpp/shared/include/{ball_emit_runtime,ball_dyn}.h` are structurally
  undercounted, not unexercised.** They are embedded verbatim into every
  generated program, and `test_e2e` compiles each fixture in a separate,
  NON-`--coverage` subprocess; gcov can only attribute a hit to code compiled
  `--coverage` in the same binary that ran it. A function here reaches 0% while
  the whole conformance corpus pounds it. The only instrument that moves it is a
  direct in-process call from an instrumented ctest binary — a `cov_*` case in
  `cpp/test/test_ball_dyn.cpp`, never another fixture.
- **The Codecov API's `line_coverage` state is `0 = HIT`, `1 = MISS`** — the
  opposite of the obvious reading, and an earlier #63 audit got it backwards and
  concluded a wholly-dead cluster was already covered. Calibrate before trusting
  it: fetch
  `https://api.codecov.io/api/v2/github/Ball-Lang/repos/ball/file_report/cpp/shared/include/ball_shared.h?flag=cpp`
  and check that the count of state-`0` entries equals the reported
  `totals.hits`. Line numbers also drift between commits, so re-derive the
  ranges against the source at the reported `commit_sha` rather than reusing a
  range from an issue comment.

### Exclusions: `LCOV_EXCL_*` is a last resort, per site, with a proof

The #63 reachability audit of the two biggest miss buckets (`ball_dyn.h`, 246
missed lines / 75 clusters, and `encoder.cpp`, 96 / 38, at main @ `f673169c`)
found that **330 of those 342 missed lines were reachable from an instrumented
ctest binary** and simply untested; the other **12** are dead by domination and
carry the three per-site exclusions listed below. The default answer to an
uncovered line here is a test:

- `cpp/encoder/src/encoder.cpp` is a pure JSON-AST -> `ball::ir` transform — no
  I/O, no toolchain, no engine — so every branch is selected by handing
  `encode_from_clang_ast` the AST shape that reaches it. Nothing in it is
  self-host-only.
- `ball_dyn.h`'s misses are the structural undercount above, NOT
  self-host-exclusivity. A 0% line there means "no instrumented binary called it
  in-process", never "only the self-hosted engine can reach it" — every member
  is an `inline` function on a plain value type. Where the public constructor
  normalises a value away from the shape you need (e.g. `BallDyn(BallOrderedMap)`
  upgrades to a shared `BallOrderedMapRef`, hiding the by-value arms the
  self-hosted engine actually produces), assign `_val` directly instead of
  reaching for an exclusion.

The tree carries exactly **three** exclusion sites, all added by that audit and
all **dominated dead code** — unreachable in every build, not merely outside
self-host. Each one is named here so this rule can be checked against the tree
(`grep -n LCOV_EXCL cpp/shared/include/ball_dyn.h cpp/encoder/src/encoder.cpp`
must return these three and nothing else). The line numbers below were
re-derived from the `file_report` at main @ `07344ca9`, where both files' miss
totals are still the audited 246 and 96 — always re-derive rather than reusing
these:

| site | dominating guard | missed lines excluded |
|---|---|---|
| `ball_dyn.h` `operator==`'s `BallListRef`/`BallList` arms (main @ `07344ca9` lines 1003-1016) | the earlier `_listPtr()` arm already handles **both** list representations element-wise, with the same aliasing short-circuit, so control never arrives here with a list on either side | 9 (the two `if` guard lines themselves are HIT — the arms are entered, never taken — so the denominator drops by 11, not 9) |
| `ball_dyn.h` `_BallRefDeref::_obj_map_fn` lambda body (main @ `07344ca9` lines 1465-1466) | both call sites of `_BallRefDeref::obj_map` test `typeid(BallObjectRef)` themselves and short-circuit first | 2 |
| `encoder.cpp` `has_qualifier`'s `"static"` clause (main @ `07344ca9` line 1337) | line 1 of the same function (`node.value("storageClass", "") == qualifier`) already returns true for exactly that case | 1 |

That is where the "12 dead of 342" above comes from, and it is also the check
that the markers took effect: the two files' instrumented denominators fall by
13 and 1 respectively (a `LCOV_EXCL_START`/`STOP` removes the HIT guard lines
inside its range too, which is why the denominator delta is larger than the
missed-line count). Rules for adding a fourth:

- Per site only (`LCOV_EXCL_LINE`, or a tight `LCOV_EXCL_START`/`STOP` around the
  guarded body). **Never `LCOV_EXCL_FILE` and never a whole function.**
- Write the reachability proof next to it — name the dominating guard or the
  platform that makes it unreachable. "Hard to test" is not a reason.
- Prove unreachability before writing it, and never write a test against a line
  whose reachability you have not established: a blind test that happens to pass
  hides the fact that the line was dead.
- Genuinely dead code should ultimately be deleted, not excluded. When it lives
  in the runtime spliced into every emitted program (`ball_dyn.h` /
  `ball_emit_runtime.h`), that deletion needs the C++ self-host conformance sweep
  and belongs in its own change.

**Always add tests alongside every C++ change.** Conformance tests automatically pick up new programs added to `tests/conformance/`.

## When Adding Features

1. Implement in the Dart reference engine first, then regenerate `engine_rt.cpp`
2. Add test cases in `cpp/test/test_compiler.cpp`; conformance tests automatically pick up new programs added to `tests/conformance/`
3. Verify the self-hosted engine passes conformance after regeneration
