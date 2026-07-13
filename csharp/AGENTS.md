<!-- Parent: ../AGENTS.md -->

# C# (epic #377, Phases 1–10 complete — bindings + runtime value model + Ball→C# compiler + Roslyn encoder + compiled self-hosted engine at Dart parity (320/320) + committed conformance harness + `ball` CLI + CI/CD + documentation)

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
against the DART reference engine). **Phase 6 (#383, CLOSED) added the self-hosted engine to
`engine/`**, running the whole conformance corpus at Dart parity (see "Self-hosted engine" below).
**Phase 7 (#384) added the committed conformance harness to `engine/conformance/`** (see
"Conformance harness" below). **Phase 8 (#385) added the `ball` CLI to `cli/`** —
`run`/`compile`/`encode`/`check` plus the self-hosted cli-core verbs `info`/`validate`/`tree`/`version`
(see "CLI" below). **Phase 9 (#386) added CI/CD** — a `csharp` job in `ci.yml` (build, test, format
check, and the regenerate-then-run self-hosted engine conformance sweep), a `csharp-engine` row in
`conformance-matrix.yml`, a coverlet→Codecov coverage flag/floor, and a `nuget` dependabot entry
(see "CI/CD" below). **Phase 10 (#387) added documentation** — this file, `.claude/rules/csharp.md`,
and the root `CLAUDE.md`/`AGENTS.md` status paragraphs, cross-checked against the actual `csharp`
CI job and `csharp-engine` conformance-matrix row. This completes all 10 phases of epic #377's
phase table (the epic issue itself closes separately, per maintainer review).

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
    src/PackageInfo.cs     # Phase 1 marker (kept as a stable PackageInfo.Name constant)
    src/Loader.cs          # #383: proto3-JSON/binary -> typed Program + canonical BallValue view
    src/BallEngine.cs      # #383: FromJson/FromBinary/Run facade; RunSelfHosted under SELF_HOST
    src/CompiledEngine.cs  # #383: GENERATED, gitignored — see engine/tool below
    tool/                  # #383: Ball.Engine.Regen — regenerates src/CompiledEngine.cs
    conformance/           # #384: Ball.Engine.Conformance — the Phase-7 harness (see below)
    test/
    tool/                  # #383: Ball.Engine.Regen — regenerates src/CompiledEngine.cs
  cli/
    src/Program.cs         # #385: `ball` entry point — System.CommandLine wiring (class
                            # CliEntryPoint, deliberately not `Program`, to avoid colliding with
                            # Ball.V1.Program in this assembly's other files)
    src/CliError.cs        # #385: CliError (Io=3/Parse=2/Runtime=1) — the exit-code contract
    src/Loader.cs           # #385: load_engine — .ball.json/.ball.bin -> BallEngine
    src/Output.cs           # #385: write_text/write_bytes — --output <file> or stdout
    src/ExceptionGuard.cs   # #385: compiler/encoder exception -> CliParseError
    src/Serialize.cs        # #385: Program -> Any-wrapped JSON/binary (ball encode's output)
    src/Commands/*.cs       # #385: one file per subcommand (Run/Compile/Encode/Check/Info/
                            # Validate/Tree/Version)
    src/CompiledCli.cs      # #385: GENERATED, gitignored — see cli/tool below
    test/                   # golden/cli_core/*.txt — checked-in Dart CLI goldens (parity gate)
    tool/                   # #385: Ball.Cli.Regen — regenerates src/CompiledCli.cs
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
- Regen command: `buf generate proto` from the repo root, with `buf` on `PATH`. `shared/gen/` is
  committed and consumed as-is by the `csharp` CI job (#386); regen-and-diff drift checking is the
  root `proto` job's concern (`buf lint`/`buf breaking`), not `csharp`'s.

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
*shapes* — `message_creation` always builds the dynamic message. `super` chains and labelled
`break`/`continue` are documented gaps for the self-host phase (#383).

**Impl-method naming:** a class member is emitted as `Owner__member`, and a **setter** as
`Owner__member__set`. The suffix is load-bearing: a getter and its setter carry the *same* Ball
function name (`main:Temperature.celsius`) and are told apart only by `metadata.is_getter` /
`is_setter`, while both impls have the one C# signature `BallValue(BallValue)` — Dart/TS emit
native `get`/`set` members and C++ overloads on arity, but C# can do neither, so without the
suffix the pair defines one method twice (CS0111).

**Properties (getter/setter) — `compiler/src/Accessors.cs`:** a property is never *called*; the IR
reaches it as a `field_access` (read) or an `std.assign` whose target is a `field_access` (write),
exactly like a plain field. Both lower to the synthesized top-level `BallAccessors` class
(`Get__x(obj)` / `Set__x(obj, value)`), which dispatches on the receiver's run-time `type_name` —
resolving through the `metadata.superclass` chain, so a subclass inherits the property — and falls
back to `BallRuntime.FieldGet`/`FieldSet` for any receiver that is *not* one of those classes (a
map, a proto message, a core value), which is exactly what a field access already emitted. It is
top-level (like `BallOneofs`) because a `field_access` carries no module, so one class is the only
place that can hold every owner of a name; that is also why a getter/setter impl is emitted
`public` while a plain method impl stays `private`. The setter accessor passes the assigned value
**positionally** (`{self, arg0}`), so the setter's single parameter binds whatever it is named
(#95, `341_setter_param_binding`). Only the getter joins the by-name method dispatcher (a
first-class reference to it still resolves); a setter merely reserves the dispatcher name, so a
stray by-name call fails loud instead of storing nothing.

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
- **Numeric value-semantics + map-key coercion (Rounds 10–12):** the sweep climbed **303 → 312 /
  320** (0 regressions; `hello_world`+`fibonacci` still byte-exact golden). Round 10 (PR #410)
  fixed inverted NaN/finiteness getters — `BallDouble` equality used `double.Equals`, which reports
  `NaN.Equals(NaN)` true and `(-0.0).Equals(0.0)` false, both backwards from IEEE-754 — plus the
  `num.remainder`/`toInt` scalar methods. Round 11 (PR #411) reimplemented
  `toStringAsFixed`/`Exponential`/`Precision` byte-exact against Dart (away-from-zero ties, minimal
  exponent, shortest mantissa). Round 12 fixed **non-string map-key coercion**: Ball maps are
  string-keyed (the C# backing is `OrderedDictionary<string, …>`, and `MapKeys` already returns
  every key as a `BallString`), but `MapGet`/`Set`/`Delete`/`ContainsKey`/`MapCreate`/
  `MapPutIfAbsent`/`.remove` demanded a `BallString` key via `AsStr` and threw on an int memo key
  (`95`/`391`). All now route through a `BallRuntime.MapKey` helper that stringifies a non-string
  key via its display form (int `5` → `"5"`, whole double → `"5.0"`) — mirrors
  `rust/shared/src/runtime.rs`'s `index_key` exactly (+2, `95`/`391`).
- **Catchable errors + JSON/DateTime built-ins (Rounds 13–14):** the sweep climbed **312 → 317 /
  320** (0 regressions). Round 13 (PR #417) surfaced Dart-catchable runtime errors — int-boundary
  `abs` wrapping (`230`), a typed `BallThrow` payload that is a `BallMessage` whose type name IS the
  exception type so `on FormatException`/`on RangeError` match (`275`/`199`). Round 14 (PR #419)
  implemented the `std_convert` JSON codec + `std_time` DateTime built-ins reached via `CallMethod`,
  and fixed a **map-literal comprehension splice** compiler gap (`CompileMapCreate` now splices
  `element` spread/collection_if/collection_for entries, the map analog of the Round-9 list splice)
  (`185`/`188`).
- **Full corpus parity (Round 15, this PR):** the informal `tests/conformance/*.ball.json` sweep is
  now at **320 passed / 320** (0 failed, 0 timeouts) — the compiled engine runs the WHOLE golden
  corpus at Dart parity (the 4 golden-less resource-limit/sandbox fixtures are documented carve-outs,
  as for every other self-host target). Three bounded root-cause categories closed the last residuals,
  each in `Ball.Shared`/`csharp/compiler` (never the generated file): (a) **bytes as `List<int>`** —
  a proto `bytes` field is a Dart `Uint8List`, so `AsList`/`SpreadIter` now view a `BallBytes` as an
  int list (`lit.bytesValue.toList()`, indexing, iteration; `399`); (b) the **two-variable
  `catch (e, stackTrace)` binding** — the compiler now binds the catch clause's `stack_trace`
  variable to `BallRuntime.CaughtStackTrace(__ballEx)` instead of leaving it an `UnresolvedReference`
  (`300`); (c) **`Map.addAll` merges in place** — `list_concat` on two maps now mutates the receiver
  and returns it (mirrors Rust's `ball_list_concat`), so a `logical_and`/`logical_or` pattern merging
  its sub-bindings back through the shared `bindings` map is observed by the caller instead of dropped
  into a fresh copy (`258`). The gated acceptance tests are `csharp/engine/test/SelfHostRunTests.cs`
  (SELF_HOST-gated: `hello_world`+`fibonacci` golden plus a byte-exact `[Theory]` over `399`/`300`/
  `258`); the full corpus harness is #384.
- **Fixes to compiled-engine behavior belong in `csharp/compiler/` or `Ball.Shared` (BallRuntime/
  BallProto)** — NEVER hand-edit `CompiledEngine.cs` (it is regenerated).

## Conformance harness (issue #384) — `csharp/engine/conformance/`

The Phase-7 harness formalizes the informal Round-15 sweep into a committed, CI-runnable runner —
`Ball.Engine.Conformance` (`csharp/engine/conformance/`), a **standalone console app**, not an
xunit test project. That choice is deliberate: CI needs a reliable `Results: N passed, M failed, T
total` line on real stdout regardless of pass/fail, and xunit's per-test console capture only
surfaces on failure by default, which would swallow the summary line on a fully-green run. Mirrors
`rust/engine/tool` in spirit (a deliberately separate project, referenced by `Ball.Engine` but
never included in its own compile items — `Ball.Engine.csproj` excludes `conformance/**/*.cs` the
same way it excludes `test/**/*.cs` and `tool/**/*.cs`) and `rust/engine/tests/
self_host_conformance.rs` in behavior (fixture discovery, carve-out handling, the `Results:` line
format, a capped failure listing).

Three legs, one runner, selected via `--leg=`:

- **`engine`** (the primary deliverable): every `tests/conformance/*.ball.json` with a golden runs
  through `BallEngine.FromJson(json).Run()` (needs `-p:SelfHost=true`, which propagates to the
  `Ball.Engine` project reference — same mechanism `Ball.Engine.Tests` uses), each on a watchdog
  `Task` with a 120s budget (mirrors the Rust runner's documented "a latent hang must not wedge the
  whole sweep, and a leaked worker thread is harmless for a measurement run"). Verified fresh
  (2026-07-11, after regenerating `CompiledEngine.cs` from `dart/self_host/engine.ball.pb` in this
  worktree): **`Results: 320 passed, 0 failed, 320 total (4 skipped carve-outs)`** — Dart parity,
  matching Round 15's informal count exactly. This is what closes #383's acceptance bar ("full
  corpus at Dart parity via the Phase-7 harness").
- **`compiler`**: every fixture compiles Ball → C# (`CSharpCompiler.Compile`), runs in-memory via
  Roslyn (a small `CSharpRunner` duplicated from `csharp/compiler/test/TestSupport.cs`'s technique,
  generalized to the whole corpus and returning outcomes instead of throwing so one fixture's
  failure never aborts the sweep), and diffs stdout. No `SelfHost` needed — never touches the
  self-hosted engine. Verified fresh: **`Results: 226 passed, 94 failed, 320 total`** — an honest
  measurement of the Phase-4 compiler's own documented scope gaps (`super`/inheritance dispatch,
  static members, enums-as-types, generics reification, generators/`yield`, `std_time`/
  `std_convert` gaps, a handful of `Message`-vs-native-collection built-in methods like `.generate`/
  `.fromEntries` — see the "Compiler" section above for the authoritative gap list).
- **`roundtrip`**: every fixture compiles Ball → C# → re-encodes that C# source back to Ball via
  the Roslyn encoder (`CSharpEncoder.Encode`) → runs the RE-ENCODED program on the **Dart reference
  engine** (`dart run dart/cli/bin/ball.dart run <file>`, ground truth — proves the C# pipeline
  round-trips, not merely that it agrees with itself) → diffs stdout. Verified fresh: **`Results: 0
  passed, 320 failed, 320 total`** — an honest, expected zero: the Phase-4 compiler emits a single
  flat class dispatching through `BallRuntime.*` static calls and `BallValue` types, which is not a
  shape the Phase-5 syntactic encoder's heuristics were built to recognize (`BallRuntime.Truthy(x)`
  parses as an unrecognized instance method call on an unknown receiver, `new BallList(...)` as an
  unknown-type construction, etc. — see the "Encoder" section's "Documented gaps" above). The
  serialize → subprocess → diff plumbing itself is verified independently: swapping in the
  *original* (un-re-encoded) fixture `Program` for one fixture end-to-end reproduces its golden
  through the real `dart run` subprocess, so a future encoder improvement that closes this gap will
  be measured by this leg, not blocked by it. On Windows, `dart` resolves to a `.bat` shim that
  `Process.Start` cannot launch directly (`CreateProcess` does not apply `PATHEXT`, a well-known
  .NET-on-Windows gap for batch-script tools like `npm`/`dart`) — the leg routes through `cmd.exe
  /c` on Windows only; every other platform (CI, `ubuntu-latest`) invokes `dart` directly.

**CI gating — the `compiler` leg is RATCHETED, not parity-gated (#452).** The `csharp-compiler`
row in `conformance-matrix.yml` runs the `compiler` leg on every push to `main` (plus the weekly
cron and `workflow_dispatch` — the matrix does NOT trigger on `pull_request`, same as every other
row in it), prints the honest count,
and fails **only if `passed` drops below `CSHARP_COMPILER_FLOOR`** (currently `226`, the number
above). This is deliberate. Gating it at full parity would just hold `main` red on 96 known gaps;
leaving it unrun — the status quo until #452 — left those gaps *unmeasured*, and an unmeasured gap
regresses silently. A ratchet gets the third thing: the number is visible on every run, it can
only go up, and the job prints the exact new floor to commit when it does. **Raise the floor in
the same PR that closes a family**, or the gain is not locked in. Never lower it to turn a red
build green — preventing precisely that is what a ratchet is for. The `engine` leg stays a true
parity gate (`failed == 0`), because it *is* at parity.

**Regen seam for CI (issue #386, implemented):** the harness does not regenerate
`CompiledEngine.cs` itself — same division of responsibility as `Ball.Engine.Tests`. A CI job
runs the regen steps documented in "Build & Test" below (`compile_engine_cpp.dart` to produce
`engine.ball.pb`, then `Ball.Engine.Regen`) before invoking the `engine` leg — both the `csharp`
job in `ci.yml` and the `csharp-engine` row in `conformance-matrix.yml` do this — exactly like the
`rust-engine` row in `conformance-matrix.yml` regenerates `compiled_engine.rs` before running
`self_host_conformance.rs`. `--fixture=<name>` (or the `BALL_FIXTURE` env var, matching the Rust
runner's convention) narrows any leg to one fixture with full actual-vs-expected detail, for
debugging a regression.

## CLI (issue #385) — `cli/`

The `ball` binary: `run`/`compile`/`encode`/`check` over `shared`/`compiler`/`encoder`/`engine`,
plus the self-hosted cli-core verbs `info`/`validate`/`tree`/`version` (epic #361 pattern,
mirroring `rust/cli` — see `rust/cli/AGENTS.md` — and `ts/cli`). This is the binary #369 ships to
NuGet. Argument parsing is **`System.CommandLine` 2.0.9** — verified the current stable release
on nuget.org 2026-07-11 (`api.nuget.org/v3-flatcontainer/system.commandline/index.json` lists 51
versions; highest non-preview is `2.0.9`, the newest overall is a `3.0.0-preview.*` deliberately
not used here). It went GA (stable `2.0.0`) 2025-11-11 after years of beta/RC — the "`Option<T>`
+ `Argument<T>` + `Command.SetAction(ParseResult -> int)` + `rootCommand.Parse(args).Invoke()`"
shape (not the older `SetHandler`/`InvocationContext` API from pre-beta5 docs).

### Exit-code contract (issue #385)

| Code | Meaning |
|------|---------|
| `0`  | success |
| `1`  | runtime error — a Ball program ran but failed (a `throw` that escaped `main`, or the engine itself reporting an error), or a cli-core verb needs a build the current binary doesn't have |
| `2`  | invalid/unparseable program — bad `.ball.json`/`.ball.bin` shape, C# source `encode` couldn't turn into a program, a loaded program was too malformed to compile, or `ball validate` found the program invalid |
| `3`  | file-not-found / other I/O error reading input or writing `--output` |

`CliError` (`src/CliError.cs`) is an exception hierarchy — `CliIoError`/`CliParseError`/
`CliRuntimeError` — each carrying its own `ExitCode`; `CliEntryPoint.Invoke` (in `Program.cs`)
catches it at the top level, prints `ball: <message>` to stderr, and returns the code.
`0` is simply the absence of a thrown `CliError`, never an explicit branch. Mirrors
`rust/cli/src/error.rs` exactly (including its Dart-vs-target `validate` exit-code adaptation —
Dart exits `1` generically on an invalid program; this CLI's own pre-existing contract reserves
`1` for a *runtime* failure, so `ValidateCommand` maps a failed validation to `CliParseError`
(exit `2`) instead, text unchanged).

### `.ball.bin` is `Any`-wrapped — a deliberate divergence from `rust/cli`

`Serialize.ProgramToBinary` (`ball encode --format binary`'s output) wraps the `Program` in a
`google.protobuf.Any` envelope (`Any.Pack(program).ToByteArray()`) — the **canonical** binary
ball-file shape (Dart's `encodeBallFileBinary`, and this CLI's own `Loader`/
`csharp/engine/src/Loader.cs`'s `ParseBinary`, both expect the `Any` wrapper). `rust/cli/src/
serialize.rs` writes a bare (unwrapped) `Program` instead — a Rust-target-only convention that
matches only `ball-lang-engine`'s own loader, not the Dart-canonical format. Do not copy that
choice here; verified by encoding a program to `--format binary` and round-tripping it through
`ball check`/`ball run` (a bare-`Program` encoding fails to load with a
"`Full type name for Program is ball.v1.Program; Any message's type url is …`" error — the
Any-vs-bare mismatch surfaces loudly, never silently).

### Two Windows-specific console fixes (`Program.cs`, `CliEntryPoint.Main`)

Both verified by running the whole `tests/conformance/*.ball.json` corpus (320 fixtures) through
`ball run` under `-p:SelfHost=true` and diffing against `*.expected_output.txt`:

- **UTF-8 output encoding.** The default Windows console codepage is not UTF-8, so non-ASCII
  stdout silently mangled to `?` (fixtures 190/191/193/247/249/250/255 — every Unicode/UTF-8
  fixture). Fixed with `Console.OutputEncoding = new UTF8Encoding(false)` at startup (guarded —
  can throw when there's no console handle at all on some hosts).
- **LF-only line endings.** `Console.WriteLine`'s terminator defaults to `Environment.NewLine`
  (`"\r\n"` on Windows), but every other Ball target (Dart's `print`/`IOSink.writeln`, per
  `BallRuntime.Print`'s own doc comment) always emits a bare `"\n"`. Fixed with
  `Console.Out.NewLine = Console.Error.NewLine = "\n"` at startup, so `ball run` output and
  cli-core report text stay byte-identical across OSes.

### cli-core adoption (issue #385, epic #361 pattern) — the `CliCore` MSBuild property

`dart/shared/lib/cli_core.dart` is a Ball-portable library of `Program -> String` report
functions (`versionLine`/`infoReport`/`validateOk`/`validateReport`/`treeReport` — plus
`auditReport`, **not** wired here, see below) — the single source of truth
`dart/cli/lib/src/runner.dart`'s `info`/`validate`/`tree`/`version` verbs already call natively.
`dotnet run --project csharp/cli/tool/Ball.Cli.Regen.csproj` compiles it via the Phase-4 compiler
in **library mode** into `src/CompiledCli.cs`: since `cli_core` is a plain function library (no
classes, no interpreter loop, unlike the self-hosted *engine*), `CSharpCompiler.Compile` already
skips `Main` emission (no function named `main` exists in `cli_core`'s `main` module) — no
runtime-driving wrapper like `BallEngine.RunSelfHosted` is needed; `Commands/{Info,Validate,Tree,
Version}Command.cs` calls the generated `BallProgram.infoReport`/etc. straight.

```bash
cd dart && dart run compiler/tool/gen_cli_json.dart        # regen dart/self_host/cli.ball.json(+.pb)
cd ../csharp && dotnet run --project cli/tool/Ball.Cli.Regen.csproj   # regen src/CompiledCli.cs
```

- `src/CompiledCli.cs` is **generated and gitignored** (`csharp/.gitignore`), same reasoning as
  `CompiledEngine.cs` — never hand-patch it; fix `dart/shared/lib/cli_core.dart` (then
  regenerate `cli.ball.json`) or `csharp/compiler/`.
- Gated behind `Ball.Cli.csproj`'s own `CliCore` MSBuild property, off by default for the same
  not-present-in-a-fresh-checkout reason as `SelfHost` — **independent** of `SelfHost`: cli-core's
  functions are pure data transforms, not the interpreter. `Ball.Cli.Tests.csproj` mirrors the
  same property so its gated test classes compile in under `-p:CliCore=true`.
  - **Default build:** `info`/`validate`/`tree` report an honest `CliRuntimeError` (exit `1`),
    never false success. `version` is the one exception: its whole logic is the one-line format
    `"ball " + version`, so `Commands/VersionCommand.cs` keeps a tiny always-on fallback.
  - **`-p:CliCore=true`** (after the two regen commands above): all four verbs produce output
    byte-identical to the Dart CLI — **compiled clean on the first regen attempt, 0 `csc`
    errors** (`cli_core` is a small library of report functions, unlike the whole-interpreter
    self-hosted engine's multi-round grind) — proven by the golden-fixture parity gate below.
- **`auditReport` is intentionally excluded** from `CompiledCli.cs` (issue #385, `#362` residual):
  it calls `capability_analyzer`/`termination_analyzer`, separate Dart files pulled in via
  `import` (not `part`), which `gen_cli_json.dart`'s `resolveDartLibrary` does not merge — the
  Dart encoder leaves them as **empty import-stub modules** in `cli.ball.json`. `csharp/cli/tool/
  Program.cs`'s `SkippedFunctions` filter drops `auditReport` from the loaded `Program` before
  compiling (mirrors `rust/cli/tool/src/main.rs`'s identical `SKIPPED_FUNCTIONS`) — a C#-target-only,
  well-documented workaround that touches neither `cli_core.dart` nor the compiler. No `ball audit`
  subcommand exists.

### Golden-fixture parity gate

`test/CliCoreParityTests.cs` compares the **built `ball` binary's** stdout (spawned via
`dotnet exec ball.dll …`, `CliProcess.cs`) for `info`/`validate`/`tree` against golden `.txt`
files checked into `test/golden/cli_core/`, generated once from the real Dart CLI (`dart run
dart/cli/bin/ball.dart <verb> <fixture>`) — the same 5-fixture set (`100_complex_control_flow`,
`101_simple_class`, `111_cascade_operator`, `116_map_iteration`, `118_set_operations`)
`rust/cli/tests/cli_core_parity.rs`/`dart/cli/test/cli_core_parity_test.dart` use. Verified
byte-identical (after `\r\n`/`\n` normalization — Windows' `core.autocrlf` mangles the checked-out
golden `.txt` files' embedded newlines, same caveat `SelfHostRunTests.cs`'s `ExpectedLines`
already works around) across all 15 fixture×verb combinations. `version` has no golden file — its
compiled-vs-fallback identity is checked directly by `CliGeneralTests`.

### Testing (`cli/test/`)

xUnit v3, black-box process-spawn style (mirrors `rust/cli/tests/*.rs`, not an in-process API —
`CliProcess.Run(args)` spawns the real built `ball.dll` and asserts on stdout/stderr/exit code):
`CliGeneralTests` (`--help`, `version`, usage errors), `CliRunTests` (`SelfHost`-gated real
execution + default-build honest degradation + I/O/parse exit codes), `CliCompileTests`,
`CliEncodeTests` (both `--format json|binary`), `CliCheckTests`, `CliCoreParityTests`
(`CliCore`-gated golden parity + default-build degradation). `ball.dll` is found next to the test
assembly — the test project's `ProjectReference` on `Ball.Cli.csproj` copies the referenced exe's
output there as an ordinary build dependency, no extra wiring needed.

```bash
dotnet test csharp/cli/test/Ball.Cli.Tests.csproj                                   # default: 22 tests
dotnet test csharp/cli/test/Ball.Cli.Tests.csproj -p:CliCore=true                    # 35 tests
dotnet test csharp/cli/test/Ball.Cli.Tests.csproj -p:SelfHost=true                   # 24 tests
dotnet test csharp/cli/test/Ball.Cli.Tests.csproj -p:CliCore=true -p:SelfHost=true   # 37 tests
```

### Known gaps

- No package-registry commands (`dart/cli`'s `init`/`add`/`resolve`/`publish`/`build`) — out of
  scope for issue #385, mirrors `rust/cli`.
- No `ball audit` — see "`auditReport` is intentionally excluded" above (issue #362 residual).
- `check` does not attempt to run the program — only compiler-shaped structural validation, plus
  an opt-in `--compile` dry-run. It never drives the self-hosted engine.

## CI/CD (issue #386)

- **`csharp` job** (`.github/workflows/ci.yml`) — gated on `needs.changes.outputs.csharp` (any
  `csharp/**` change) or `infra`; also fires whenever `needs.changes.outputs.self_host` is true
  (a `dart/engine/lib/**` edit cross-compiles into `CompiledEngine.cs`, same reasoning as the
  `cpp`/`rust` jobs — see the `changes` job's `self_host` computation in `ci.yml`). Mirrors the
  `rust` job's shape: `actions/setup-dotnet@v5` (`dotnet-version: "10.0.x"`, matching
  `csharp/global.json`'s `rollForward: latestFeature` floor of `10.0.100`) → `dotnet build
  Ball.slnx` → `dotnet test Ball.slnx` → `dotnet format Ball.slnx --verify-no-changes` → the
  self-host conformance sweep: `dart-lang/setup-dart` + `dart pub get` +
  `compiler/tool/compile_engine_cpp.dart` (tolerating its documented post-`.pb`-write C++-emit
  failure — see "Build & Test" above) to produce `engine.ball.pb`, `dotnet run --project
  engine/tool/Ball.Engine.Regen.csproj` to produce `CompiledEngine.cs`, `dotnet build
  engine/conformance/Ball.Engine.Conformance.csproj -c Release -p:SelfHost=true`, then `dotnet run
  ... --leg=engine` — parity-checked (`passed == total`, `failed == 0`) against the parsed
  `Results:` line rather than a hardcoded fixture count, mirroring the `rust`/`cpp`/`ts` jobs'
  identical gate so the corpus can grow without editing the workflow. Currently green at
  `Results: 320 passed, 0 failed, 320 total (4 skipped carve-outs)`.
- **`csharp-engine` row** (`.github/workflows/conformance-matrix.yml`) — same regen-then-run leg
  as the `ci.yml` job, wired into the `summary` job's `needs`, `print_row`, and both failure-check
  blocks exactly like `rust-engine`. `csharp/**` was also added to the workflow's `push.paths`
  filter.
- **Coverage** (`.github/workflows/coverage.yml`, `codecov.yml`) — `coverlet.collector` (already
  referenced by every `csharp/*/test/*.csproj`, pinned in `Directory.Packages.props`) is the VSTest
  `"XPlat Code Coverage"` data collector; `csharp/coverlet.runsettings` switches its output to lcov
  and excludes generated sources (`Ball.V1.*` — the buf-generated protobuf namespace — plus
  `CompiledEngine`/`CompiledCli`, mirroring `codecov.yml`'s `ignore:` list). `dotnet test
  Ball.slnx --collect:"XPlat Code Coverage" --settings coverlet.runsettings` instruments all 5
  default-build test projects in one invocation, each writing its own `coverage.info`; since
  VSTest integration doesn't merge multi-project runs or compute a summary (unlike coverlet's
  dotnet/msbuild integration), `dotnet-reportgenerator-globaltool` merges them into one `lcov.info`
  for Codecov and a `TextSummary` (`Line coverage: NN.N%`) the floor gate parses — the C# analog of
  the `cpp` job's `lcov --summary` and the `rust` job's `cargo llvm-cov report
  --fail-under-lines`. Floor is `60` (measured 65.3% locally 2026-07-12); raise toward 100% as
  tests land, per the same ratchet philosophy as the other four stacks. Codecov flag `csharp`,
  `paths: [csharp/]`, `carryforward: true` in both `coverage.yml`'s upload step and
  `codecov.yml`'s `flag_management`.
- **Dependabot** (`.github/dependabot.yml`) — a `nuget` ecosystem entry at `directory: "/csharp"`
  (Central Package Management via `Directory.Packages.props` resolves every `csharp/` package's
  versions from that one root, like the `pub`/`cargo` workspace-root entries above it), grouped
  `nuget-minor-patch` for minor/patch bumps.
- Out of scope for #386 (left for a future pass): regenerating `CompiledCli.cs` /
  `-p:CliCore=true` in CI, and running the conformance harness's `compiler`/`roundtrip` legs (both
  have documented non-parity gaps — see "Conformance harness" above — so they are not yet
  CI-gated pass/fail checks).

## Generated Files — NEVER Edit

- `csharp/shared/gen/` — protobuf bindings (`buf generate`, plugin
  `buf.build/protocolbuffers/csharp:v35.1`, see root `buf.gen.yaml`)
- `csharp/engine/src/CompiledEngine.cs` — the self-hosted engine, regenerated by
  `csharp/engine/tool` (gitignored; only in the build under `-p:SelfHost=true`)
- `csharp/cli/src/CompiledCli.cs` — the self-hosted CLI core, regenerated by `csharp/cli/tool`
  (gitignored; only in the build under `-p:CliCore=true`)

## Build & Test

```bash
# .NET 10 SDK is native on Windows — no WSL needed (unlike C++/Rust in this repo)
dotnet build csharp/Ball.slnx
dotnet test csharp/Ball.slnx
dotnet format csharp/Ball.slnx --verify-no-changes   # run `dotnet format` (no flag) to fix
dotnet run --project csharp/cli/Ball.Cli.csproj -- --help   # the real `ball` CLI (issue #385)

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

# Conformance harness (issue #384): three legs, one runner. Build once per
# SelfHost setting, then run with --no-build to skip re-resolving each time.
dotnet build csharp/engine/conformance/Ball.Engine.Conformance.csproj -c Release -p:SelfHost=true
dotnet run --project csharp/engine/conformance/Ball.Engine.Conformance.csproj \
  -c Release -p:SelfHost=true --no-build -- --leg=engine     # Results: 320 passed, 0 failed, 320 total
dotnet build csharp/engine/conformance/Ball.Engine.Conformance.csproj -c Release
dotnet run --project csharp/engine/conformance/Ball.Engine.Conformance.csproj \
  -c Release --no-build -- --leg=compiler                    # Results: 226 passed, 94 failed, 320 total
dotnet run --project csharp/engine/conformance/Ball.Engine.Conformance.csproj \
  -c Release --no-build -- --leg=roundtrip [--dart=dart]      # Results: 0 passed, 320 failed, 320 total
# --fixture=<name> (or env BALL_FIXTURE=<name>) narrows any leg to one fixture
# with full actual-vs-expected detail.

# Self-hosted cli-core (issue #385): regenerate, build, and run `ball` for real.
cd dart && dart run compiler/tool/gen_cli_json.dart                  # writes cli.ball.json(+.pb)
cd ../csharp && dotnet run --project cli/tool/Ball.Cli.Regen.csproj  # writes src/CompiledCli.cs
dotnet build cli/Ball.Cli.csproj -p:CliCore=true -p:SelfHost=true    # both features together
dotnet run --project cli/Ball.Cli.csproj -p:CliCore=true -p:SelfHost=true -- run \
  ../examples/hello_world/hello_world.ball.json                     # prints "Hello, World!"
dotnet test cli/test/Ball.Cli.Tests.csproj -p:CliCore=true -p:SelfHost=true   # 37 tests
```

## Publishing (nuget.org) — issue #369

`csharp/cli/Ball.Cli.csproj` packs as a **.NET global tool** (`PackAsTool=true`,
`ToolCommandName=ball`, `PackageId=Ball.Cli`) and ships to **nuget.org** via
`.github/workflows/publish-nuget.yml`. It is **tag-gated** — merging a PR never publishes; a
release only fires when a `csharp-nuget/vX.Y.Z` tag is pushed.

### Package identity

`PackageId` is `Ball.Cli` — verified available on nuget.org 2026-07-12 (`api.nuget.org/
v3-flatcontainer/ball.cli/index.json` returns 404: no version ever published; the nuget.org
search UI shows no exact-name match either). NuGet ids are case-insensitive, so this also
reserves `ball.cli`/`BALL.CLI`/etc. The bare id `ball` is *also* free on nuget.org (unrelated to
the pre-existing, unmaintained `ball` crate on crates.io — see `rust/AGENTS.md` — nuget.org is a
separate namespace with no such squatter), but `Ball.Cli` was chosen to match this project's
existing C# naming convention (`Ball.Shared`/`Ball.Compiler`/`Ball.Encoder`/`Ball.Engine`/
`Ball.Cli` are already the five assembly/namespace names).

### Trigger & tag namespace

```bash
git tag csharp-nuget/v0.1.0 && git push origin csharp-nuget/v0.1.0
```

The `csharp-nuget/` **slash** prefix mirrors `publish-crates.yml`'s (#375) `rust-crates/`
precedent: GitHub Actions tag filters treat `*` as "any char except `/`", so
`csharp-nuget/v0.1.0` does not match the Dart channel's `*-v[0-9]+.[0-9]+.[0-9]+*` filter
(`release-publish.yml`) or the Rust channel's `rust-crates/v*` filter — none of the release
channels cross-fire.

### Published feature shape (working `ball run` out of the box)

The committed csproj has neither `SelfHost` nor `CliCore` set, so a fresh-checkout `dotnet build`/
`dotnet pack` stays green without the Dart-regen dance — every gated verb honestly reports a
`CliRuntimeError` instead of silently doing nothing (see `Ball.Cli.csproj`'s doc comment). The
publish workflow regenerates `CompiledEngine.cs` + `CompiledCli.cs` from
`dart/self_host/{engine.ball.pb,cli.ball.json}` and then runs
`dotnet pack -p:SelfHost=true -p:CliCore=true`, so `dotnet tool install --global Ball.Cli` yields
a working `ball run` (self-hosted engine) plus `info`/`validate`/`tree`/`version` (cli-core) with
no extra flags — the same gitignored-generated-source packaging problem `publish-crates.yml`
(#375) solved for `ball-lang-cli`, solved the .NET way: unlike Cargo (which packages *source* and
needs an `include` glob to defeat gitignore-based file discovery), `dotnet pack` packages
*compiled build output* — building with the properties on is the whole fix, no manifest-level
include/exclude needed.

Before publishing, the workflow gates on the same acceptance bar as the `csharp` CI job and
`publish-crates.yml`: the self-hosted engine conformance sweep must show full parity
(`Results: N passed, 0 failed, N total`) and the cli-core golden-parity tests
(`CliCoreParityTests`) must pass.

### Version policy

The published package version is derived from the tag (`csharp-nuget/vX.Y.Z` → `X.Y.Z`), passed
to `dotnet pack` via `-p:Version=`, overriding `Ball.Cli.csproj`'s committed `<Version>0.1.0</
Version>` placeholder. `ball version` reports the informational version baked into the built
`ball` assembly (`IncludeSourceRevisionInInformationalVersion=false` keeps it a clean `ball
<version>` line, no `+<git-sha>` suffix) — the nuget.org package version, mirroring how each
target's CLI reports its own registry's version (crates.io for Rust, npm's semantic-release line
for TypeScript, the pubspec version for Dart — see `rust/AGENTS.md`'s "Version policy").

### Auth: nuget.org Trusted Publishing (OIDC) + API-key fallback

Auth uses [`NuGet/login@v1`](https://github.com/NuGet/login) (pinned to the v1.2.0 SHA): it
exchanges the GitHub OIDC token (`permissions: id-token: write`) for a short-lived (1-hour)
nuget.org API key exposed as `steps.login.outputs.NUGET_API_KEY`. That key is passed to
`dotnet nuget push` via an env var, falling back to a `NUGET_API_KEY` **secret** when the OIDC
exchange fails (`continue-on-error: true` on the login step) — e.g. before a Trusted Publishing
policy is configured, or before the `NUGET_USER` secret is set.

Unlike crates.io (RFC 3691, `rust/AGENTS.md`), nuget.org Trusted Publishing policies **can** be
created before a package's first publish (verified against
<https://learn.microsoft.com/en-us/nuget/nuget-org/trusted-publishing>, 2026-07-12) — a policy for
a not-yet-existing package id starts "temporarily active for 7 days" and becomes permanent on
first successful publish. So the token fallback here is a bridge until the policy is configured,
not specifically required for release #1 the way it is for crates.io.

### Maintainer setup (one-time, registry side) — required before the first tag

1. **Own a nuget.org account** (or organization) with publish rights, linked to the GitHub org.
2. **Reserve the package id** (optional but recommended): push once manually with a personal API
   key (`dotnet nuget push` from a local `dotnet pack -p:SelfHost=true -p:CliCore=true`), or skip
   straight to step 3 — a Trusted Publishing policy can target an id that doesn't exist yet.
3. **Configure Trusted Publishing**: nuget.org → your username → **Trusted Publishing** → add a
   policy — Repository Owner `Ball-Lang`, Repository `ball`, Workflow File `publish-nuget.yml`
   (file name only, no `.github/workflows/` path), Environment left blank. Owner: the account or
   org that will own the `Ball.Cli` package.
4. **Set the `NUGET_USER` repo secret** to that nuget.org account's profile username (not email) —
   consumed by the `NuGet/login` step's `user:` input.
5. **(Fallback) Set the `NUGET_API_KEY` repo secret**: nuget.org → API Keys → Create, scope Push,
   glob pattern `Ball.Cli` (or `Ball.*`), an expiry. Needed until step 3's policy is confirmed
   active (check the nuget.org UI after the first publish — a policy can silently expire after 7
   days if no publish happens in a private-repo scenario, though `Ball-Lang/ball` is public so this
   should activate on the first successful push).
6. **Push the first tag**: `git tag csharp-nuget/v0.1.0 && git push origin csharp-nuget/v0.1.0`.

## For AI Agents

- Status: Phases 1–5 complete — every package compiles; `shared` consumes the buf-generated
  bindings against a version-pinned `Google.Protobuf` runtime with binary AND JSON round-trip
  smoke tests and verified byte-identical regen discipline (#379); the runtime value model + std
  module builders + base-op helper layer with real tests (#380); the Ball → C# compiler with
  compile-and-run end-to-end tests (#381; see "Compiler" above); and the Roslyn C# → Ball encoder
  — 77 xunit tests, zero `csharp_std` modules, verified against the Dart reference engine (#382;
  see "Encoder" above). **Phase 6 (#383, CLOSED): the self-hosted engine** — the regen tool, the
  `Loader`/`BallEngine`/`BallProto` foundation with real tests, and the category grind that took the
  generated `CompiledEngine.cs` from 474 `csc` errors to **0 — it now COMPILES** under
  `-p:SelfHost=true`, and — after the Round-4 execution grind — **RUNS the WHOLE conformance corpus
  at Dart parity**: **320 passed / 320** (0 failed, 0 timeouts; `hello_world`+`fibonacci` byte-exact
  golden; the 4 golden-less resource-limit/sandbox fixtures are documented carve-outs) after the
  Rounds 5–15 bounded-category grind (Round 5: RegExp surface, core-collection copy/fill
  constructors, universal `toString` fallback; Round 6: the double-value-representation gap; Round
  7: live reassigned-instance-field read/write through `self` + loader JSON depth-cap lift; Round 8:
  first-class `Function.apply`/`fold` callbacks; Round 9: list-literal spread splice; Rounds 10–11:
  IEEE double equality + `num.remainder`/`toInt` + byte-exact `toStringAs*` formatting; Round 12:
  non-string map-key coercion; Round 13: Dart-catchable runtime errors; Round 14: JSON/DateTime
  built-ins + map-comprehension splice; Round 15: bytes-as-`List<int>`, two-variable
  `catch (e, stackTrace)`, in-place `Map.addAll` merge — see "Self-hosted engine" above and #383).
  **Phase 7 (#384): the conformance harness** (`csharp/engine/conformance/`) formalizes that sweep
  into a committed, CI-runnable runner printing the canonical `Results: N passed, M failed, T total`
  line — `engine` leg fresh-verified at `320 passed, 0 failed, 320 total` (Dart parity, closing
  #383's acceptance bar), plus a `compiler` leg (`226 passed, 94 failed, 320 total` — the Phase-4
  compiler's own honest scope-gap count) and a `roundtrip` leg (`0 passed, 320 failed, 320 total` —
  an honest, expected zero given the Phase-5 encoder's syntactic heuristics don't yet recognize
  compiler-emitted `BallRuntime.*` shapes; see "Conformance harness" above). The `cli` package is
  now complete (Phase 8, see below).
  **Phase 8 (#385) added the `ball` CLI**: `run`/`compile`/`encode`/`check` (via
  `System.CommandLine` 2.0.9, verified GA-stable on nuget.org) plus the self-hosted cli-core verbs
  `info`/`validate`/`tree`/`version` (epic #361 pattern — `CompiledCli.cs` compiled clean on the
  first regen attempt, 0 errors), both input formats (`.ball.json`/`.ball.bin`, the latter
  `Any`-wrapped per the Dart-canonical shape — see "CLI" above for why this deliberately diverges
  from `rust/cli`'s bare-`Program` `.ball.bin` convention), the full `0`/`1`/`2`/`3` exit-code
  contract, and a golden-fixture parity gate against the Dart CLI (`test/CliCoreParityTests.cs`).
  `ball run` (under `-p:SelfHost=true -p:CliCore=true`) executes the **whole** `tests/
  conformance/*.ball.json` corpus (320 fixtures) at Dart parity through the real built binary —
  the same two Windows console fixes (UTF-8 output encoding, forced LF line endings) that made
  that sweep byte-exact are documented in "CLI" above since they're easy to reintroduce
  accidentally (e.g. via a bare `Console.WriteLine` bypassing the configured `Console.Out`).
  **Phase 9 (#386) wired all of this into CI** — a `csharp` job in `ci.yml` (build/test/format +
  the regenerate-then-run self-hosted engine conformance sweep, `Results: 320 passed, 0 failed,
  320 total`), a `csharp-engine` row in `conformance-matrix.yml`, a coverlet→Codecov coverage
  flag/floor, and a `nuget` dependabot entry — see "CI/CD" above. **Phase 10 (#387) added
  documentation** — this file, `.claude/rules/csharp.md`, and the root `CLAUDE.md`/`AGENTS.md`
  status paragraphs (see below). This is the last phase in epic #377's phase table.
- The compiler emits calls into `BallRuntime.*` for base-function dispatch and builds
  lists/maps/messages with the reference-vs-value-semantics copy rules above — do not re-derive
  operator semantics as emitted text. Fixes to compiled-program behavior belong in the compiler
  (`compiler/src/`) or a `BallRuntime` helper, never in emitted text.
- With both #381 and #382 landed, re-verify the encoder's proof programs through the full C#
  pipeline (encode → compile → dotnet run) as part of the #384 conformance harness — today's
  encoder proof is Dart-engine-only.
- All 10 phases of `.claude/skills/new-ball-language/SKILL.md` are complete for C# — there are no
  remaining phases in epic #377.
- Central Package Management is on (`Directory.Packages.props`) — add new package versions there,
  not per-project `Version=` attributes.
- Verify maturity against CI (`.github/workflows/ci.yml`) — the `csharp` job and `csharp-engine`
  conformance-matrix row (#386) are the source of truth, not this prose.
- **NuGet packaging (issue #369) advances but does not close the registry epic (#361):**
  `csharp/cli/Ball.Cli.csproj` packs as a working .NET global tool (`PackageId=Ball.Cli`,
  `ToolCommandName=ball`) and `.github/workflows/publish-nuget.yml` is tag-gated on
  `csharp-nuget/v*` and proven locally (`dotnet pack -p:SelfHost=true -p:CliCore=true` +
  `dotnet tool install --global --add-source` + a real `ball run`/`info`/`validate`/`tree` against
  the conformance corpus) — but nothing has actually been pushed to nuget.org yet, which needs the
  maintainer registry setup in "Publishing (nuget.org)" above plus a first tag.
