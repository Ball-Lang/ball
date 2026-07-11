<!-- Parent: ../AGENTS.md -->

# C# (Phases 1–5 complete + Phase 6 self-host engine RUNS hello_world + fibonacci — bindings + runtime value model + Ball→C# compiler + Roslyn encoder + compiled self-hosted engine)

## Purpose

Directory scaffold + package manifests for the C# Ball implementation (epic #377). Phase 1
(#378) wired up five SDK-style projects — `shared`, `compiler`, `encoder`, `engine`, `cli` —
plus one xunit test project per package, all under a single solution. Phase 2 (#379) made the
buf-generated protobuf bindings in `shared/gen/` consumable: pins the `Google.Protobuf` runtime
to the gencode's plugin version and adds binary + JSON round-trip smoke tests (see "Proto
bindings" below). **Phase 3 (#380) added the runtime value model + std module builders + the
base-op helper layer to `shared/`** (see "Runtime value model" below). **Phase 4 (#381) added the
Ball → C# compiler to `compiler/`** (see "Compiler" below). **Phase 5 (#382) added the C# → Ball
encoder to `encoder/`** (via Roslyn, syntax-only — see "Encoder" below; verified end-to-end
against the DART reference engine). The `engine`/`cli` packages are still Phase-1 placeholders —
see the phase table in the epic #377 tracking comment.

## Layout

```
csharp/
  Ball.slnx               # solution (see "Solution format" below)
  Directory.Build.props   # shared MSBuild settings (net10.0, nullable, implicit usings)
  Directory.Packages.props # Central Package Management — all NuGet versions pinned here
  global.json              # minimum SDK: 10.0.100, rollForward: latestFeature
  shared/
    gen/Ball.cs            # buf-generated protobuf bindings — NEVER edit by hand
    src/BallValue.cs       # #380: polymorphic value hierarchy + numeric/display semantics
    src/BallList.cs        # #380: ordered, reference-semantic list (List<BallValue> backing)
    src/BallMap.cs         # #380: insertion-ordered map (OrderedDictionary<string,BallValue>)
    src/BallMessage.cs     # #380: descriptor-backed message instance (shared field map)
    src/BallFunction.cs    # #380: first-class callable (Func<BallValue,BallValue>)
    src/BallExceptions.cs  # #380: BallRuntimeException (fail-loud) + BallThrow (catchable)
    src/BallRuntime.cs     # #380: base-op helper layer the Phase-4 compiler dispatches to
    src/DescriptorBuilders.cs # #380: proto-descriptor helpers for the module builders
    src/StdModuleBuilders.cs  # #380: BuildStd{,Collections,Io,Memory}Module()
    src/Fields.cs          # #380: Fields.Extract(FunctionCall) named-argument convention
    src/PackageInfo.cs     # Phase 1 marker (still referenced by cli's CliInfo)
    test/                  # Ball.Shared.Tests — binary+JSON protobuf smoke + value-model/runtime/builder tests
  compiler/
    src/CSharpCompiler.cs  # #381: Compile(Program) -> C# — 7 node types, stmt/expr contexts
    src/BaseCall.cs        # #381: base-function dispatch + lazy control flow (native if/for/while/…)
    src/TypeEmit.cs        # #381: typeDefs[] -> class/abstract class/enum + method dispatchers
    src/Naming.cs          # #381: identifier sanitization + literal emission helpers
    src/PackageInfo.cs     # Phase 1 marker (still referenced by cli's CliInfo.Banner)
    test/                  # #381: end-to-end (compile+run) + lazy-eval + dispatch + type/lambda tests
  encoder/
    src/CSharpEncoder.cs   # #382: Encode(source) -> Program; std accumulation; entry point
    src/Encoder.cs         # #382: pre-pass declaration collection + core expression dispatch
    src/Statements.cs      # #382: block/local (LetBinding) encoding
    src/ControlFlow.cs     # #382: if/for/foreach/while/do-while/switch/try -> LAZY std calls
    src/Types.cs           # #382: class/struct/record -> TypeDefinition; object creation
    src/Methods.cs         # #382: invocation/member-access dispatch, interpolation, lambdas
    src/Builders.cs        # #382: Expression/Statement/metadata builder toolbox
    src/EncoderException.cs # #382: fail-loud exception type (never a silent drop)
    test/                  # Ball.Encoder.Tests — 77 tests: one file per construct family +
                            # a std-accumulation/zero-csharp_std suite + proof-program tests
                            # (hello_world/fibonacci/factorial)
  engine/
    src/PackageInfo.cs     # Phase 1 placeholder; self-hosted engine wrapper lands in #383
    test/
  cli/
    src/Program.cs         # Phase 1 placeholder entry point; real subcommands land in #385
    src/CliInfo.cs          # proves shared/compiler/encoder/engine all resolve as references
    test/
```

## Solution format

`dotnet new sln` on the installed .NET 10.0.201 SDK generates the new XML `.slnx` format by
default (not the classic text `.sln`) — `Ball.slnx` is the real solution file; `dotnet build`/
`dotnet test`/`dotnet sln add` all work against it directly. Don't hand-author a `.sln`; use
`dotnet sln Ball.slnx add <path>` to add new projects.

## Test project layout (decision, issue #378)

Each package gets a **sibling** `<pkg>/test/` directory holding its own `.csproj` (e.g.
`shared/test/Ball.Shared.Tests.csproj`), not a top-level `test/` tree. This mirrors the
`src/`/`test/` split documented in `.claude/skills/new-ball-language/SKILL.md` §1.1 and keeps
parity with the sibling-language directory convention (`rust/compiler/`, `ts/compiler/` are
direct children of the language root, not nested under a shared `src/`). Because the .NET SDK's
default item globbing is recursive from each `.csproj`'s own directory, every main package
`.csproj` explicitly excludes `test/**/*.cs` (`<Compile Remove="test/**/*.cs" />`) so the main and
test projects never double-compile each other's files.

Each package's test project is a real xUnit.net v3 project (`dotnet new xunit3` shape — self
executing app, bridged to `dotnet test` via `xunit.runner.visualstudio`), not an empty stub. The
only non-trivial one is `shared` — see "Proto bindings" below. The other four packages have no
real logic yet (that's phases #380-383), so their tests assert on a `PackageInfo.Name` placeholder
constant instead; `cli`'s test additionally asserts its `CliInfo.Banner` references all four
sibling packages, proving the whole project-reference graph resolves (the C# analog of Rust's
Phase 1a "five member crates wired together via path dependencies").

## Proto bindings (issue #379, epic #377 Wave B Phase 2)

`shared/gen/Ball.cs` is buf-generated (`buf.build/protocolbuffers/csharp:v35.1`, see root
`buf.gen.yaml`) and consumed via a single `PackageReference Include="Google.Protobuf"` (version
resolved centrally — see "Google.Protobuf version pairing" below). Two smoke tests in
`shared/test/` prove the bindings are actually consumable, not just compilable:

- `ProtoBindingSmokeTests.cs` — constructs a `Ball.V1.Program` by hand, round-trips it through
  `ToByteArray()` / `Parser.ParseFrom()`, and asserts field equality. Proves the generated code
  compiles and binary (wire-format) protobuf works against the pinned runtime.
- `ProtoJsonRoundTripSmokeTests.cs` — loads a **real** conformance fixture
  (`tests/conformance/202_sandbox_mode.ball.json`, not a hand-built string) through
  `Google.Protobuf.JsonParser`, then round-trips the parsed message through binary protobuf
  (JSON → message → bytes → message) and asserts full structural equality (`Assert.Equal` on the
  generated message types, which implement deep field-by-field `Equals`). This is the JSON leg:
  it proves proto3-JSON compat, which the self-hosted engine loader (a later phase) will rely on
  when it reads `.ball.json` files off disk.

  A `.ball.json` file is a proto3-JSON `google.protobuf.Any` envelope — an explicit
  `"@type": "type.googleapis.com/ball.v1.Program"` key alongside the message's own fields (see
  `dart/shared/lib/ball_file.dart` for the canonical reader). The test mirrors that convention:
  it parses the envelope with `System.Text.Json`, asserts the `@type` value, strips the key, and
  hands the remaining body to `JsonParser` (with `IgnoreUnknownFields` on, matching the Dart
  reader's `ignoreUnknownFields: true` safety net) — rather than reaching for
  `JsonParser.Settings.IgnoreUnknownFields` to paper over the unrecognized `@type` field, which
  would test a looser contract than what the engine loader actually needs to implement.

### Google.Protobuf version pairing

`Google.Protobuf` `3.35.1` is pinned in `Directory.Packages.props` to match the
`buf.build/protocolbuffers/csharp:v35.1` gencode plugin line exactly — deliberately, not by
default resolution. The C++ target burned days on a gencode/runtime version skew (#302); the
fix here is the same discipline as C++'s `protobuf_deps.bzl` pin: **when bumping the `csharp`
plugin version in `buf.gen.yaml`, bump `Google.Protobuf`'s `PackageVersion` in
`Directory.Packages.props` to the matching minor/patch line in the same commit**, then rerun both
smoke tests above (a skewed pairing typically still compiles — the wire format is
backward/forward compatible across nearby versions — so the smoke tests, not the build, are what
would catch a meaningful skew; treat a passing build alone as insufficient evidence).

### Regen discipline — `buf generate proto` reproduces `shared/gen/` byte-identically

Verified 2026-07-11 with `buf` v1.56.0 on `PATH` (`buf --version`): ran `buf generate proto` from
the repo root (the module lives at `proto/buf.yaml`, so `proto` must be passed explicitly — see
root `CLAUDE.md`) and diffed the result against the committed tree.

- `git hash-object csharp/shared/gen/Ball.cs` before and after regeneration returned the
  **same blob hash** (`85f5ef99e0990ee12a1d00d8e066a02418f899d8`), and `cmp` against the
  pre-regen blob exited 0 (bytes identical) — i.e. `buf generate proto` reproduces
  `csharp/shared/gen/Ball.cs` byte-for-byte from `proto/ball/v1/ball.proto` + `buf.gen.yaml`.
- `git status` reported the file (and every other language's `gen/` output) as modified anyway.
  This is a benign local artifact of `core.autocrlf=true` on Windows: `buf`'s remote plugins emit
  LF line endings and none of `dart/`, `go/`, `java/`, `python/`, `rust/`, `ts/`, or `csharp/`
  `gen/**` carry a `text eol=lf` (or `binary`) `.gitattributes` rule, only `linguist-generated=true`
  — so a Windows checkout with `autocrlf=true` flags the LF-committed generated file as
  "would-convert" even when its content exactly matches HEAD. Confirmed via `git diff --numstat`
  (zero output — no line changes) and the blob-hash/`cmp` check above; do not read a bare `git
  status` "M" on `**/gen/**` after a regen as evidence of drift on Windows — check the blob hash.
- Regen command (also what CI should run once a C# CI job exists — #386):
  `buf generate proto` from the repo root, with `buf` on `PATH`.

## Ordered-map decision (issue #378, for the runtime value model landing in #380)

`BallMap` (Ball's `std_collections` map type) has insertion order as a hard invariant — the same
requirement Rust satisfied with `indexmap::IndexMap` (see `rust/shared/Cargo.toml`). C# does not
need a third-party package for this: **`System.Collections.Generic.OrderedDictionary<TKey,TValue>`**
was added to the BCL in .NET 9 (`System.Collections.dll`) and is present unchanged in the .NET 10
docs (verified via learn.microsoft.com,
`system.collections.generic.ordereddictionary-2?view=net-10.0`, 2026-07-11). Since this project
targets `net10.0`, `BallMap` will wrap `OrderedDictionary<string, BallValue>` directly — no
`Google.Protobuf`-adjacent or third-party ordered-map dependency needed. This type is not yet
used in Phase 1 (no runtime value model exists yet); the decision is recorded here for #380 to
consume.

## Runtime value model (issue #380)

The `shared/` package now carries the runtime types the compiler/encoder/engine all build on,
the C# port of `rust/shared/src/value.rs` + `runtime.rs` (its closest sibling) and the Dart
reference engine's value hierarchy.

### Value hierarchy (`BallValue`)

`BallValue` is an **abstract sealed class hierarchy** (the idiomatic C# analog of Rust's
`enum BallValue` — exhaustive `value switch { BallInt i => …, BallList l => … }`). Concrete
subclasses: `BallNull`, `BallBool`, `BallInt` (`long`), `BallDouble` (`double`), `BallString`,
`BallBytes`, `BallList`, `BallMap`, `BallMessage`, `BallFunction`. Construct primitives via the
factories `BallValue.Null` / `.Bool(bool)` / `.Int(long)` / `.Double(double)` / `.Str(string)` /
`.Bytes(byte[])` (`Null`/`Bool` are cached singletons); the collection/callable/message types are
`BallValue`s themselves (`new BallList(...)`, `new BallMap()`, `new BallMessage(name, fields)`,
`new BallFunction(name, input => …)`).

- **Reference vs value semantics (the load-bearing invariant).** `BallList`/`BallMap`/
  `BallMessage`/`BallFunction` are reference types, so `var b = a;` aliases the same backing — a
  mutation through `b` is visible through `a`, exactly like Dart's `List`/`Map`/class instances
  (and the `Arc<Mutex<…>>`-shared Rust `BallList`/`BallMap`). Primitives are immutable/value-
  semantic. A `BallMessage` shares its field `BallMap` backing (the property the self-hosted
  engine's mutable `this` relies on). **Copy points must snapshot** (`BallList.Snapshot()` /
  `BallMap.Snapshot()`): list literals, `toList()`, spread, and `+` concat build a fresh backing —
  never alias an operand.
- **`BallMap` is insertion-ordered** via `System.Collections.Generic.OrderedDictionary<string,
  BallValue>` (.NET 9+): overwriting an existing key keeps its position; `Remove` preserves the
  order of the rest (unit-tested). Never substitute `Dictionary<,>`.
- **Numeric cross-type equality.** `BallValue.ValueEquals` (and each subclass's `Equals`/
  `GetHashCode`) treats `Int` and `Double` as equal when numerically equal (Dart's `0 == 0.0`).
  `BallList.Contains`/`IndexOf` and set ops route through it. Maps compare order-independently;
  functions compare by delegate identity.
- **`ToString()` matches reference-engine stdout**: whole doubles keep a trailing `.0`, `-0.0` is
  distinct, NaN/`Infinity`/`-Infinity` spellings, maps/messages render `{k: v, …}`, functions
  render `<function name>`/`<lambda>`.

### Module builders + field extraction

- `StdModuleBuilders.BuildStdModule()` / `BuildStdCollectionsModule()` / `BuildStdIoModule()` /
  `BuildStdMemoryModule()` construct the universal base `ball.v1.Module`s (every function
  `IsBase = true`, no `Body`). Counts are **asserted against the canonical Dart inventory** in the
  tests — `std` name-for-name against `dart/shared/std.json` (parsed at test time), and
  `std_collections`/`std_io`/`std_memory` (which have no committed JSON) against each `_fn('name',
  …)` in `dart/shared/lib/std_*.dart`. Never hardcode a bare count. `DescriptorBuilders`
  (`TypeDef`/`ExprField`/`StringField`/`BaseFn`/…) mirrors `rust/shared/src/descriptor_builders.rs`.
- `Fields.Extract(FunctionCall) → OrderedDictionary<string, Expression>` — the named-argument
  convention: no input ⇒ empty; a `MessageCreation` input ⇒ `{field.name: field.value}` (an
  absent value becomes a default, non-null `Expression`); any other input ⇒ `{"value": input}`.

### Base-op helper layer (`BallRuntime`) — what Phase 4 (#381) emits calls to

Static `BallRuntime` is the C# analog of `rust/shared/src/runtime.rs` / `cpp/shared/include/
ball_dyn.h`: the compiler emits `BallRuntime.Add(a, b)` etc. instead of re-deriving operator
semantics as text. **Every method takes/returns `BallValue`** (invariant #1). Signatures the
compiler dispatch table depends on:

- **Arithmetic** (int/double promotion, 64-bit wrapping, Euclidean modulo, truncating `~/`):
  `Add`, `Subtract`, `Multiply`, `Divide`, `DivideDouble`, `Modulo`, `Negate`. `Add` also does
  string concat and non-mutating list concat; `Multiply` does string×int repeat.
- **Comparison** (numeric promotion, ordinal string order): `Equals`, `NotEquals`, `LessThan`,
  `GreaterThan`, `Lte`, `Gte`, `CompareTo`.
- **Truthiness / dispatch**: `Truthy` (bool/`null`-falsy, else fail loud), `CallFunction`
  (first-class value dispatch), `UnsupportedBaseCall(module, function)` (fail-loud fallback),
  `Throw`. `and`/`or`/`??` short-circuit, so the compiler emits them **inline**, not as calls.
- **Logic / bitwise**: `Not`, `BitwiseAnd`/`Or`/`Xor`/`Not`, `LeftShift`, `RightShift`,
  `UnsignedRightShift`. **Null**: `NullCheck`, `NullCoalesce`.
- **Conversion / string**: `ToStringValue`, `Length`, `StringToInt`/`StringToDouble` (throw a
  catchable `FormatException` via `BallThrow`), `ToInt`/`ToDouble`, and the `String*` family
  (`Concat`, `StringContains`/`StartsWith`/`EndsWith`/`IndexOf`/`Substring`/`ToUpper`/`Trim`/
  `Replace`/`ReplaceAll`/`Split`/`Repeat`/`PadLeft`/`PadRight`, …). C#'s native UTF-16 `string`
  already gives Dart's `String.length`/index semantics for free.
- **Collections**: `ListGet`/`ListLength`/`ListFirst`/`ListContains`/… (read), `ListPush`/`ListPop`/
  `ListInsert`/`ListRemoveAt`/`ListSet`/`ListClear` (mutate the shared backing), `ListReverse`/
  `ListConcat`/`ListSlice`/`ListTake`/`ListDrop` (non-mutating, snapshot). `Map*`
  (`MapGet`/`MapSet`/`MapDelete`/`MapKeys`/…). `Set*` — a set is a duplicate-free list
  (`SetCreate`/`SetAdd`/`SetContains`/`SetUnion`/…). `StringJoin`.

**Fail loud** (throw `BallRuntimeException`) on an unhandled/mistyped shape — never a silent
`null`/placeholder. `BallThrow` is the catchable Ball `throw` (carries a `BallValue` payload +
optional type name for `on Type catch`). Phase 4 (#381) added the remaining node-type helpers the
compiler dispatches to: `FieldGet`/`FieldSet` (`object.field`), `IndexGet`/`IndexSet`
(`target[index]`), `Iterate` (`for_in`), `MessageTypeName` (method dispatch), and `Print`
(newline is always `\n`, never the platform `\r\n`, so compiled-program output is byte-identical
to the other engines on every OS). **Scope:** still deferred (fall back to `UnsupportedBaseCall`):
higher-order collection ops needing multi-arg callbacks (`list_map`/`list_reduce`/…), `regex_*`,
the `math_*` transcendental family, most of `std_io`, and all of `std_memory`.

## Compiler (issue #381) — `compiler/`

`CSharpCompiler.Compile(Ball.V1.Program) → string` emits a **single, runnable C# source file**.
The closest sibling is `rust/compiler/` (string emission + `base_call.rs`-style dispatch to a
shared runtime); `dart/compiler/lib/compiler.dart`'s `_compileBaseCall` is the canonical dispatch
inventory. Every compiled expression evaluates to a `BallValue`; base calls dispatch to
`BallRuntime.*` (operators) or lower to native C# (control flow); user calls become a direct
method call, or `BallRuntime.CallFunction(local, input)` for a first-class function value in a
local.

### Block-lowering decision (the C#-specific choice)

C#'s `if`/`for`/`while`/`foreach`/`switch`/`try` and `{ … }` blocks are **statements, not
expressions** (unlike Rust's block-expressions and C++'s IIFE lowering is only a fallback). The
compiler runs in **two contexts**:

- **Statement context** (`EmitBlockInner`/`EmitStatement` in `CSharpCompiler.cs`, control-flow
  lowering in `BaseCall.cs`) — used for function bodies and every block statement. Control flow
  lowers to the **native** C# statement, and `return`/`break`/`continue` to the real C# keyword.
  This makes compiled code read almost 1:1 with the Dart source and — load-bearing — makes a
  `return` inside an `if`-branch return from the enclosing function, which a pure-IIFE lowering
  gets wrong (it would return from the lambda).
- **Expression context** (`CompileExpression`) — used where a value is required. An `if` becomes a
  C# ternary; a block/loop that lands here is wrapped in a `Func<BallValue>` IIFE
  (`Run(() => { … })`, the C++ precedent), confined to that narrow case.

Rejected: pure-IIFE-everywhere (unreadable + mis-scopes `return`); full statement-lowering with
temp-var spilling (most readable, but needs an ANF pass — disproportionate for Phase 4).

**Single-file emission:** the entry module's functions are `static` methods on one `BallProgram`
class; every other user module is its own nested `static class`; base modules (`std`, …) emit
nothing (they *are* `BallRuntime`). A thin `static void Main` calls the compiled entry function.

**Lazy control flow (invariant #4):** `if`→native `if`/ternary; `and`/`or`/`??`→native
`&&`/`||`/conditional (untaken operand never reached); `for`/`for_in`/`while`/`do_while`→native
loops with the body inlined. Regression-tested with both-branches-side-effecting programs
(`LazyControlFlowTests`).

**Type emission:** `typeDefs[]` `metadata.kind` → C# `sealed class`/`abstract class`; `Module.enums[]`
→ a working dynamic enum namespace; instance methods (`owner:Type.member` + `metadata.kind`) →
run-time dispatchers routing on the receiver's `type_name`. The runtime representation stays
**dynamic** (`BallMessage`, like the Rust sibling), so class declarations are faithful field
*shapes* — `message_creation` always builds the dynamic message. Body-carrying constructors,
`super` chains, static members, and labelled `break`/`continue` are documented gaps for the
self-host phase (#383).

### Formatting

The emitter emits structurally-correct but minimally-indented C#; run `dotnet format whitespace`
for idiomatic indentation (the C# analog of `rustfmt`/`ts-morph`). Generated program text is a
build artifact — never committed.

### Tests (`compiler/test/`)

xUnit v3. `EndToEndTests` compile `hello_world`/`28_fibonacci`/`57_recursion_factorial`/
`100_complex_control_flow` and assert **byte-exact** stdout (Roslyn in-memory compile + run —
`TestSupport.cs`); `LazyControlFlowTests` prove single-branch evaluation; `BaseDispatchTests`
cover the dispatch categories; `TypeEmitTests`/`LambdaTests` cover types + closures. `Ast.cs`
builds Ball trees in-code for the targeted tests.

## Encoder (issue #382)

`csharp/encoder/` encodes C# source into a Ball `Program` via **Roslyn**
(`Microsoft.CodeAnalysis.CSharp`, pinned in `Directory.Packages.props` — verified latest stable
on nuget.org at lane time: `5.6.0`, matching `dotnet/roslyn`'s C# 14/.NET 10 line). Parsing is
**syntax-only** (`CSharpSyntaxTree.ParseText`, no `CSharpCompilation`/semantic model) — the same
discipline as `dart/encoder/lib/encoder.dart`'s `parseString` approach (see
`.claude/rules/dart.md`'s "syntactic-encoder gotchas": dispatch is by *syntax and name
heuristics*, never by static type, since none is available). **Hard invariant: there is no
`csharp_std` base module** — every construct routes through `std`/`std_collections`, verified by
a CI-checkable xunit assertion (`StdModuleAccumulationTests`).

### The "one input" convention — this encoder's key departure from `rust/encoder`

`rust/encoder` packs 2+-parameter functions into `field_access(reference("input"), name)` to
work around its *compiled-Rust-closure* compile target. This encoder targets the tree-walking
reference engine directly instead, and **verified against `dart/engine/lib/engine_invocation.dart`
that the engine binds every declared parameter — 1 or many — directly under its own real name**
whenever `FunctionDefinition.metadata.params` lists it (`_extractParams`/`_callFunction`): this is
engine-level behavior, not merely compiler-cosmetic metadata. So every function/method/lambda
this encoder emits, of any arity, references each parameter via a plain `reference(name)`
throughout its body — no positional `arg0`/`arg1` packing needed for a *known* (same-file)
callee. Lambdas are true closures on the reference engine (`_evalLambda` captures `scope.child()`),
so a nested lambda referencing an enclosing function's parameters by name resolves correctly with
no special-casing needed.

Instance methods use the engine's separate, **unconditional** `self` convention (verified in
`_callFunction`/`_evalCall`): a method call's `input` carries a `"self"` field with the receiver,
and the engine binds `self` into scope — and flattens the receiver's own fields into scope too —
whenever that key is present, independent of `metadata.params`. This encoder lists only a
method's own (non-`self`) parameters in `metadata.params`, and always addresses a field via
explicit `field_access(reference("self"), field)` (never a bare name) — mirrors
`dart/compiler/lib/compiler.dart`'s own `reference("self")`/`this` convention exactly. An
instance method compiles to `"main:Owner.Method"` (dot-split by the engine's
`_registerFunctionDispatchTables` to build its runtime-type dispatch table); a static method
compiles to a plain top-level function `"Owner_Method"` (underscore, to avoid colliding with the
dot-based instance convention) — **except** a method literally named `Main`, always the bare
entry-point name `"Main"` regardless of which class declares it.

### Construction is field-mapping only

`new Foo(a, b)` / `new Foo { X = 1 }` never interprets a constructor **body** — only the
constructor's (or a C# 12 primary constructor's) parameter list is consulted to map positional
args onto field names; a class may declare at most one constructor. `List<T>`/`HashSet<T>`/…
construction becomes a Ball list literal; `Dictionary<K,V>` has no native Ball map literal (see
`proto/ball/v1/ball.proto`'s `Literal` oneof — no map case), so it routes through
`std_collections.map_from_entries` instead. A `*Exception`-named unknown type (no same-file class
declaration) is assumed to be a BCL exception and becomes an anonymous `{Message: ...}` — Ball's
`throw`/`try`/`catch` model is value-based, needing no exception type hierarchy.

### Documented gaps (fail loud, never silently dropped)

Target-typed `new(...)` (no semantic model to resolve the implied type); `enum` declarations;
`goto`/switch pattern-matching labels/catch exception filters; chained `?.` beyond one level;
multiple constructors per class; local functions; sized array allocation without an initializer;
interpolation alignment/format specifiers (`{x,5:F2}`). A few method names are inherently
ambiguous without a semantic model and bias toward one route (documented in `Methods.cs`'s module
doc comment): `.Contains`/`.IndexOf` → string ops; `.Remove` → `map_delete`.

### Proof (verified 2026-07-11 against the DART reference engine — no C# engine exists yet, #383)

Encoded `hello_world`/`fibonacci`/`factorial`/a fields+methods+object-initializer class program/
a control-flow-heavy program (foreach/while/switch/try-catch-finally/lambda/null-conditional) and
ran each `.ball.json` via `dart run dart/cli/bin/ball.dart run <file>` from the repo root — every
output matched real C# semantics exactly (fib(0..9), 1!..10!, `p.SumCoords()`, etc.). This is the
encoder's actual ground truth, independent of the not-yet-built C# compiler/engine.

## Self-hosted engine (issue #383, Phase 6 — self-host grind in progress)

The engine is the reference engine itself — a Ball program
(`dart/self_host/engine.ball.pb`, a binary `google.protobuf.Any` envelope; the 21 MB JSON exceeds
protobuf's 100-level nesting default) — compiled through the Ball → C# compiler into
`csharp/engine/src/CompiledEngine.cs` (SKILL.md Phase 4 Option B, same route as Rust/TS/C++).

- **Regen tool** (`csharp/engine/tool/Ball.Engine.Regen.csproj`) — `dotnet run --project
  csharp/engine/tool/Ball.Engine.Regen.csproj` loads the `.pb` (or falls back to the `.json`),
  unpacks the `Any` to a `ball.v1.Program`, compiles it (library shape — the engine has no
  top-level `main`, so no `Main` is emitted), and writes `CompiledEngine.cs`. It is a
  **deliberately separate project** (not a target in `Ball.Engine`), so a broken generated file
  never makes the regenerator itself un-buildable — the C# analog of Rust's `ball-engine-regen`
  crate.
- **Feature-flag arrangement** (the C# analog of Rust's `self_host` cargo feature):
  `CompiledEngine.cs` is **gitignored** and **excluded from the default build**; it participates
  only under `-p:SelfHost=true` (which also defines the `SELF_HOST` symbol). So the **default
  build stays green with the generated file absent** (fresh checkout) or non-compiling (the
  grind). Measure the grind with `dotnet build csharp/engine/Ball.Engine.csproj -p:SelfHost=true`.
- **Wrapper foundation** (`csharp/engine/src/`, all default-build, tested): `Loader` produces the
  canonical proto3-JSON `BallValue` view the compiled engine reads (JSON + binary, `@type`
  stripped, proto3 defaults materialized, metadata re-expanded to the raw `Struct` shape);
  `BallEngine` is the facade (`FromJson`/`FromBinary`/`Run`). `Run` throws `SelfHostPendingException`
  until the grind lands.
- **`ball_proto` access patterns** live in `Ball.Shared.BallProto` (the discriminators
  `whichExpr`/…, presence `hasBody`/…, `getField`/`setField`/Struct access/defaults). The compiler
  dispatches `ball_proto.*` base calls there (`BaseCall.cs`'s `CompileBallProtoCall`). Unit-tested
  against real fixture IR shapes in `csharp/engine/test/BallProtoTests.cs`.
- **Self-host status:** `CompiledEngine.cs` **COMPILES** under `-p:SelfHost=true` (0 `csc`
  errors). The first compile produced 474; Round 1 (unique per-scope input names,
  oneof-discriminator constants, stub-library-module fail-loud routing) took it to 174, and
  Round 2 to **0** via: dynamic built-in-method dispatch (`BallRuntime.CallMethod` — `x.group(1)`/
  `list.addAll(y)`/`int.tryParse(s)`/set algebra, the ~130 empty-module `{self, arg0, …}` calls)
  + type-literal markers (`BallRuntime.TypeLiteral`, for bare `int`/`num`/`DateTime` receivers);
  globally-unique local aliases in `BindLocal` (all `let`/param/field-alias/loop/catch bindings,
  since C# forbids the nested-scope shadowing Dart allows — even a top-level binding conflicts
  with a namesake in a textually-earlier nested block); and a fail-loud `UnresolvedReference`
  fallback for the last handful (an inherited field on a base-type superclass like `entries` on
  `BallObject extends BallMap`, a stub-module enum `io_FileMode`, a second catch binding
  `stackTrace`).
- **Running (Round 3):** the engine now **constructs and EXECUTES** — `BallEngine.Run` (under
  `-p:SelfHost=true`) builds a `BallEngine` via its compiled constructor and drives the compiled
  `run` on a large-stack thread (`RunSelfHosted`). Round 3 landed the execution machinery:
  body-carrying constructor emission (`BallEngine.new`/`BallObject.new` — init-formals + field
  defaults like `_functions = {}` / `_globalScope = _Scope()`, inherited fields via the
  `metadata.superclass` chain, `super`, and body-mutated-field write-back); implicit-`this`
  injection + bound method tear-offs (`{'print': _stdPrint}`); static-member emission (no
  receiver/dispatcher); top-level-variable getter invocation; `switch_expr` with Dart-3 structured
  patterns (`WildcardPattern`/`LogicalOrPattern`/`ConstPattern`); and a large, **polymorphic**
  runtime surface (`FieldGet` virtual properties `.length`/`.isEmpty`/`.entries` + proto-getter
  aliases `field_2`→`field`; `CallMethod` built-in dispatch incl. `has*` proto getters and
  `DateTime.now`; math/collections/convert). The engine runs through construction, lookup-table
  building, module-handler `print` dispatch, and deep into expression evaluation.
- **Runs the reference programs (Round 4):** `hello_world` **and** `fibonacci` now produce
  **byte-exact golden output** through the compiled engine — `SelfHostRunTests` passes under
  `-p:SelfHost=true`. Round 4 landed the seven root-cause fixes that unblocked execution: (1)
  null-aware index-set `target?[index] = value` short-circuits instead of eagerly dereferencing
  (`BaseCall.cs`); (2) multi-parameter functions/lambdas bind name-**or**-positionally
  (`ParamPrologue` uses `ArgGet`, so a first-class `op(a, b)` invoke resolves); (3)
  `reference("input")` resolves through a declared `input` local (an instance method's extracted
  argument, not the raw `{self, arg0}` wrapper); (4) `BallObject extends BallMap` is modelled as
  `is BallMap` so map-shaped paths (`_stdAsMap` → `.entries`) fire; (5) the engine's own
  `BallMap`/`BallList` value-model wrappers store their backing under `entries`/`items`, and (6)
  `LinkedHashMap()`/`HashMap()` lower to a native `BallMap` (not an opaque message); (7) — the
  keystone — **Dart switch-statement fall-through** (a bare `case 'a': case 'b': <stmt>`) now ORs
  the empty-body labels into the shared body, instead of dropping it; this silently broke every
  `++`/`--` (a four-label fall-through case), hanging every counter loop.
- **Climbs the corpus (Round 5):** the informal `tests/conformance/*.ball.json` sweep is now at
  **251 passed / 324** (0 timeouts), up from 199. Round 5 landed three bounded root-cause
  categories, each measured: (a) the **RegExp surface** (`BallRegex.cs`: `firstMatch`/`hasMatch`/
  `allMatches` on a `RegExp` message, `group` on the returned match — the engine parses type/
  expression strings with `RegExp`, and Dart's default flags line up with .NET's default
  `Regex`); (b) **core-collection copy/fill constructors** — `Map.from`/`List.of`/`List.filled`
  (and the `LinkedHashMap`/`HashMap` aliases) now materialize a native `BallMap`/`BallList`
  (`CompileCollectionFactory` → `BallRuntime.MapCopy`/`ListCopy`/`ListFilled`) instead of an
  opaque `BallMessage` the engine then fails to `..remove(k)`/iterate; and (c) the **universal
  `toString` dispatcher fallback** — a `toString` method dispatcher that matches no user override
  now falls back to `BallRuntime.ToStringValue` (Dart's `Object.toString()` is universal — a core
  value or an override-less object must still stringify), which the engine's own value-stringify
  (`result.toString()` on an interpreted method's String result, and its final `v.toString()`)
  depends on.
- **Closes the double-value-representation gap (Round 6):** the sweep is now at **271 passed /
  324** (0 timeouts), up from 251 — the whole Round-5 residual "null-operand numeric ops" bucket
  (and its `{value: …}`/`{arg0: …}` output-diff siblings) was one root cause: the engine boxes
  every double literal in its own `BallDouble(this.value)` value-model class (`ball_value.dart`),
  and three seams dropped its `value`. (a) The compiler emitted the positional constructor arg as
  `arg0`, not the initializing-formal field `value` — `ValueModelWrapperFields` only mapped
  `BallMap`→`entries`/`BallList`→`items`, so every `.value` read on a double returned `null` and
  `roundToDouble`/`string_to_double`/arithmetic threw "expected a number, got Null" (added
  `BallInt`/`BallDouble`/`BallString`/`BallBool`→`value`, `TypeEmit.cs`). (b) The wrapper's own
  `toString()` override is absent from the (typeDef-less) dispatch table, so it printed as the map
  `{value: 3.14}`; `Ball.Shared` now renders an engine scalar value-model wrapper as its payload
  (`ScalarWrapperPayload` in `BallValue.cs`, consumed by `BallMessage.ToString`). (c) The
  `Loader` re-serializes a whole double (`9.0`) as proto3-JSON's bare integer `9` and loaded it as
  a `BallInt`, dropping the trailing `.0`; a `doubleValue` key now always loads a `BallDouble`
  (`Loader.cs`). All three are the same coherent gap, each measured (+9/+5/+6), 0 regressions.
- **Live instance-field state + loader depth (Round 7):** the sweep is now at **291 passed /
  320** (0 timeouts, 0 regressions), up from 271, via two bounded root-cause categories. (a) The
  **loader JSON depth cap** — deeply-nested programs (labeled loops / nested try-catch / editions
  resolver) blew past `System.Text.Json`'s default 64-level read cap *and* Google.Protobuf's
  default 100-level `JsonParser` recursion limit; both are lifted in `Loader.cs` (+4). (b) The
  **reassigned-instance-field write-back gap** — the compiler read every instance field into a
  method-entry alias local (a read-time snapshot), so a bare `field = x` rebind mutated only the
  local shadow, never the field. That silently broke every field observed *across* a method /
  closure boundary mid-run: `_activeException` (set by `_evalLazyTry`'s catch handler, read by
  the separate `rethrow` dispatch closure — so `rethrow` always saw null → "rethrow outside of
  catch"), plus the dispatch-table / closure-capture state behind the OOP method-resolution and
  nested-function fixtures. The compiler now treats a field reassigned anywhere in its class as
  *volatile* — references compile to a live `FieldGet(self, …)` and assignments to
  `FieldSet(self, …)`, matching Dart's implicit-this — and skips its alias local
  (`_volatileFields` / `VolatileFieldsOf` in `csharp/compiler`) (+16: all rethrow chaining, the
  `MathUtils`/`.greet`/`.name`/`.tag`/named-constructor OOP dispatch, and the nested-function
  captures).
- **First-class callback invoke + list-literal spread splice (Rounds 8–9):** the sweep climbed
  **291 → 303 / 320** (0 regressions; `hello_world`+`fibonacci` still byte-exact golden). Round 8
  (PR #408) implemented the `Function.apply`/`Iterable.fold` higher-order callbacks the engine
  invokes on its own runtime values (`Ball.Shared` `CallMethod`). Round 9 fixed the largest
  remaining bounded category — **list-literal spread/comprehension elements were never spliced**:
  `CompileListLiteral` emitted every element (including a `std.spread`/`collection_if`/
  `collection_for` call) as one nested value, so the engine's own `_ballSetOf([...items, v])` /
  `list_concat` / `set_union` produced a nested `{[...], v}` instead of appending — silently
  breaking every internal `set.add`/`list.addAll`/set-algebra path (`118`/`129`/`350`/`386`/`392`).
  The compiler now builds a spread-containing literal imperatively, splicing via
  `BallRuntime.SpreadIter` (mirrors `ball-compiler`'s `compile_list_literal` and the reference
  engines' `_addCollectionElement`).
- **Remaining failures (17):** `remainder`/`toInt`/`convert` scalar-method singletons (`320`/`188`/
  `185`), NaN/infinity/number-getter diffs (`214`/`215`/`263`/`317`), `toStringAsFixed`/
  exponential-precision rounding (`316`/`357`), logical-and pattern binding (`258`), int-boundary
  `abs` overflow (`230`), non-string (int) map-key coercion (`391`/`95`), bytes-literal-to-list
  (`399`), catchable `int.parse`/index-range errors surfacing loud (`275`/`199`), and the
  `stackTrace` catch binding (`300`). The proper gated harness is #384; the acceptance tests are
  `csharp/engine/test/SelfHostRunTests.cs` (SELF_HOST-gated, excluded from the default build; run
  with `dotnet test -p:SelfHost=true`).
- **Fixes to compiled-engine behavior belong in `csharp/compiler/` or `Ball.Shared` (BallRuntime/
  BallProto)** — NEVER hand-edit `CompiledEngine.cs` (it is regenerated).

## Generated Files — NEVER Edit

- `csharp/shared/gen/` — protobuf bindings (`buf generate`, plugin
  `buf.build/protocolbuffers/csharp:v35.1`, see root `buf.gen.yaml`)
- `csharp/engine/src/CompiledEngine.cs` — the self-hosted engine, regenerated by
  `csharp/engine/tool` (gitignored; only in the build under `-p:SelfHost=true`)

## Build & Test

```bash
# .NET 10 SDK is native on Windows — no WSL needed (unlike C++/Rust in this repo)
dotnet build csharp/Ball.slnx
dotnet test csharp/Ball.slnx
dotnet format csharp/Ball.slnx --verify-no-changes   # run `dotnet format` (no flag) to fix
dotnet run --project csharp/cli/Ball.Cli.csproj       # prints the Phase 1 wiring banner

# Self-hosted engine (issue #383): regenerate, build, and run the acceptance tests.
# The regen tool prefers dart/self_host/engine.ball.pb (binary Any envelope). In a
# fresh checkout that gitignored artifact is absent AND the JSON fallback exceeds
# System.Text.Json's depth limit, so materialize the .pb first:
#   cd dart && dart run compiler/tool/compile_engine_cpp.dart   # writes engine.ball.pb
#   (the trailing C++ emit step errors when ball_cpp_compile is absent — harmless;
#    the .pb is written before it. `gen_engine_json.dart` only writes the .json.)
dotnet run --project csharp/engine/tool/Ball.Engine.Regen.csproj    # writes CompiledEngine.cs
dotnet build csharp/engine/Ball.Engine.csproj -p:SelfHost=true      # compile the generated engine
dotnet test csharp/engine/test/Ball.Engine.Tests.csproj -p:SelfHost=true \
  --filter "FullyQualifiedName~SelfHostRunTests"   # hello_world + fibonacci golden
```

## For AI Agents

- Status: Phases 1–5 complete — every package compiles; `shared` consumes the buf-generated
  bindings against a version-pinned `Google.Protobuf` runtime with binary AND JSON round-trip
  smoke tests and verified byte-identical regen discipline (#379); the runtime value model + std
  module builders + base-op helper layer with real tests (#380); the Ball → C# compiler with
  compile-and-run end-to-end tests (#381; see "Compiler" above); and the Roslyn C# → Ball encoder
  — 77 xunit tests, zero `csharp_std` modules, verified against the Dart reference engine (#382;
  see "Encoder" above). **Phase 6 (#383) is in progress: the self-hosted engine wrapper
  foundation** — the regen tool, the `Loader`/`BallEngine`/`BallProto` foundation with real tests,
  and the category grind that took the generated `CompiledEngine.cs` from 474 `csc` errors to
  **0 — it now COMPILES** under `-p:SelfHost=true`, and — after the Round-4 execution grind —
  **RUNS**: `hello_world` + `fibonacci` are byte-exact golden through the compiled engine, and an
  informal corpus sweep is at 291/320 with no hangs after the Round-7 category grind (Round 5:
  RegExp surface, core-collection copy/fill constructors, universal `toString` fallback; Round 6:
  the double-value-representation gap — scalar value-model wrapper field mapping + wrapper
  stringification + whole-double loader coercion; Round 7: live reassigned-instance-field
  read/write through `self` + loader JSON depth-cap lift — see "Self-hosted engine" above and #383). The
  `cli` package is still a Phase-1 placeholder — see the phase table in the epic #377 tracking
  comment for the blocked-by graph (#384 conformance, #385 CLI, #386 CI, #387 docs).
- The compiler emits calls into `BallRuntime.*` for base-function dispatch and builds
  lists/maps/messages with the reference-vs-value-semantics copy rules above — do not re-derive
  operator semantics as emitted text. Fixes to compiled-program behavior belong in the compiler
  (`compiler/src/`) or a `BallRuntime` helper, never in emitted text.
- With both #381 and #382 landed, re-verify the encoder's proof programs through the full C#
  pipeline (encode → compile → dotnet run) as part of the #384 conformance harness — today's
  encoder proof is Dart-engine-only.
- Follow `.claude/skills/new-ball-language/SKILL.md` for the remaining phases.
- Central Package Management is on (`Directory.Packages.props`) — add new package versions there,
  not per-project `Version=` attributes.
- Verify maturity against CI (`.github/workflows/ci.yml`), not this prose — no C# CI job exists
  yet (that's #386).
