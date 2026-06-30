---
name: new-ball-language
description: >
  End-to-end playbook for adding a new programming language to Ball. Covers directory scaffold,
  proto binding generation, compiler, encoder, self-hosted engine, package management, CLI
  integration, conformance tests, CI/CD, and documentation. USE FOR: bootstrapping a new
  language (e.g., Rust, Swift, Kotlin, Ruby), or auditing an incomplete language implementation
  against the checklist. DO NOT USE FOR: modifying an existing mature implementation (use the
  language-specific rule instead).
---

# Adding a New Language to Ball — Complete Playbook

This skill walks you through every step of adding full Ball support for a new programming
language. Follow the phases in order. Each phase has a checklist — complete every item before
moving to the next phase.

Throughout this guide, `<lang>` is the lowercase language name (e.g., `rust`, `swift`, `kotlin`)
and `<Lang>` is the title-case form (e.g., `Rust`, `Swift`, `Kotlin`).

---

## Phase 0: Prerequisites

Before starting, verify:

- [ ] Decide your protobuf strategy (detailed in Phase 1.2). Ball does NOT require your target
  language to have a protobuf library — if it lacks one, Ball compiles its OWN protobuf runtime to
  your language. Check [buf.build/plugins](https://buf.build/plugins) for an official or community
  plugin; if none exists you still never need a lossy JSON-only fallback.
- [ ] You have the language's toolchain installed locally (compiler, package manager, test runner).
- [ ] You understand the 5 core Ball invariants (see `CLAUDE.md` → "Core Invariants").
- [ ] You've read at least one existing implementation for reference:
  - **Dart** (most complete): `dart/compiler/`, `dart/encoder/`, `dart/engine/`
  - **TypeScript** (good second reference): `ts/compiler/`, `ts/encoder/`, `ts/engine/`
  - **C++** (shows systems-language patterns): `cpp/compiler/`, `cpp/encoder/`

---

## Phase 1: Directory Scaffold & Proto Bindings

> **Ball's headline capability — protobuf for languages that don't have it.** Ball does not depend on
> your target having a protobuf library. Ball ships its OWN complete protobuf runtime written in
> portable Dart that the encoder turns into a Ball program; any Ball program compiles to your target
> via the compiler you build in Phase 2. So even a language with zero protobuf support gets a working
> wire + JSON + gRPC runtime for free. There are two distinct layers — do not conflate them:
>
> 1. **`ball_protobuf`** — the FULL runtime (binary wire format, proto3 JSON, well-known types,
>    editions defaults, gRPC framing). Source `dart/ball_protobuf/lib/*.dart`; encoded into a Ball
>    program at `dart/shared/ball_protobuf.json` / `.bin` by `dart/encoder/bin/gen_ball_protobuf.dart`.
>    Descriptor-driven: messages are plain maps and a field-descriptor list drives `marshal()`
>    (map→bytes) and `unmarshal()` (bytes→map), with a parallel proto3-JSON codec.
> 2. **`ball_proto`** — the deterministic ACCESS-PATTERN compat module the self-hosted engine relies
>    on (46 base functions, no bodies — count is `len(functions)` in `dart/shared/ball_proto.json`): oneof discriminators (`whichExpr`…), presence checks
>    (`hasBody`…), Struct access (`getStructField`…), proto3 defaults (`ensureDefaults`…). Source
>    `dart/shared/lib/ball_proto.dart`; generated to `dart/shared/ball_proto.json` / `.bin` by
>    `dart/shared/bin/gen_ball_proto.dart`.
>
> Rule of thumb: `ball_protobuf` is HOW bytes/JSON are (de)serialized; `ball_proto` is HOW the
> self-hosted engine reads fields of an already-deserialized Ball program. You need `ball_proto` to
> run the self-hosted engine (Phase 4); you need `ball_protobuf` only if the target lacks a native
> protobuf library (decision tree in 1.2).

### 1.1 Create the directory structure

```
<lang>/
  shared/              # Protobuf bindings + shared types
    gen/               # Generated proto code (NEVER edit)
  compiler/            # Ball → <Lang> compiler
    src/
    test/
  encoder/             # <Lang> → Ball encoder
    src/
    test/
  engine/              # Ball interpreter OR self-hosted engine wrapper
    src/
    test/
  cli/                 # Ball CLI entry point for this language
    src/
  AGENTS.md            # Language-specific agent instructions
  <package-manifest>   # Cargo.toml / setup.py / go.mod / build.gradle / etc.
```

### 1.2 Choose a protobuf strategy

Pick the branch that matches your target language.

**(a) Language HAS an official or community buf plugin** (preferred). Add a plugin entry to the root
`buf.gen.yaml`, run `buf generate`, and verify bindings appear in `<lang>/shared/gen/`:

```yaml
  - remote: <plugin-path>          # see the plugin-path table below
    out: <lang>/shared/gen
    # opt: paths=source_relative   # language-specific options as needed
```

Plugin paths are **not** all under `protocolbuffers/` — verify each at
[buf.build/plugins](https://buf.build/plugins):

| Language | Plugin path |
|----------|-------------|
| Dart, Go, Java, Kotlin, Python, C++, C#, Ruby | `buf.build/protocolbuffers/<lang>` |
| TypeScript / JS | `buf.build/bufbuild/es` |
| Swift | `buf.build/apple/swift` |
| Rust | `buf.build/community/neoeinstein-prost` (community — there is no official `protocolbuffers/rust`) |

**(b) Language has a protobuf runtime but no buf plugin.** Add the community plugin to `buf.gen.yaml`
(`remote:` or `local:`), or depend on the language's protobuf runtime and hand-write only the thin
descriptor glue. You keep binary + JSON serialization.

**(c) Language has NO protobuf support at all.** This is exactly what Ball is built for — do NOT fall
back to lossy JSON-only parsing. Compile Ball's own protobuf runtime to your target and use it:

1. The committed artifact `dart/shared/ball_protobuf.json` / `.bin` is a **facade**
   `ball.v1.Module` (not a `Program`) whose `module_imports[]` inline the `ball_protobuf.*`
   runtime modules (`edition`, `wire_*`, `field_*`, `marshal`, `unmarshal`, `json_codec`,
   `well_known`, `editions`, `grpc_frame`, …). It has **no entry point** and does **not**
   bundle `std`/`std_collections` — those are pulled in by whatever program consumes it.
   Regenerate from `dart/` with
   `cd dart/encoder && dart run bin/gen_ball_protobuf.dart [out_dir]`.
2. Compile it to your language with your Phase-2 compiler:
   `<lang>/compiler/compile dart/shared/ball_protobuf.json -o <lang>/shared/ball_protobuf.<ext>`
3. You now have a native, full-fidelity runtime (binary wire + proto3 JSON + well-known types +
   editions defaults + gRPC framing) with no external dependency. Call `marshal(message, descriptor)`
   / `unmarshal(bytes, descriptor)`; the descriptor format is shared by both codecs, so you keep
   **both** binary and JSON — you do NOT lose binary serialization.

Option (c) gives you the wire/JSON runtime; the self-hosted engine (Phase 4) additionally needs the
`ball_proto` access-pattern module regardless of which branch you chose here (see Phase 1.4).

### 1.3 Initialize the package manifest

Create the language's package manifest with these dependencies:
- Protobuf runtime library for the language
- Test framework
- Any code-generation library needed by the compiler (equivalent of Dart's `code_builder`)

**Examples by language:**

| Language | Manifest | Protobuf Runtime | Test Framework |
|----------|----------|-----------------|----------------|
| Rust | `Cargo.toml` | `prost` | built-in `#[test]` |
| Go | `go.mod` | `google.golang.org/protobuf` | built-in `testing` |
| Python | `pyproject.toml` | `protobuf` | `pytest` |
| Kotlin/Java | `build.gradle.kts` | `com.google.protobuf:protobuf-java` | `junit` |
| Swift | `Package.swift` | `swift-protobuf` | `XCTest` |
| Ruby | `Gemfile` | `google-protobuf` | `rspec` |
| C# | `*.csproj` | `Google.Protobuf` | `xunit` |

### 1.4 Create shared utilities

In `<lang>/shared/`, create helper utilities that compiler, encoder, and engine all need:

1. **Ball value types** — runtime representation of Ball values:
   - `BallValue` — polymorphic value (int, double, string, bool, null, list, map, function)
   - `BallList` — ordered collection of BallValues
   - `BallMap` — **ordered** string-keyed map (use ordered map, NOT hash map)
   - `BallFunction` — callable that takes BallValue and returns BallValue

2. **Module builders** — functions that construct std module protobuf messages:
   - `buildStdModule()` — builds the `std` module with all 118 base function signatures
   - `buildStdCollectionsModule()` — 53 collection functions
   - `buildStdIoModule()` — 10 I/O functions
   - Reference: `dart/shared/lib/std.dart` has the canonical definitions

3. **Field extraction** — helper to extract named fields from a `MessageCreation` expression:
   ```
   extractFields(MessageCreation) → Map<String, Expression>
   ```

4. **Protobuf runtime + compat-module artifacts** — wire up these committed Ball artifacts per your
   1.2 choice:

   | Artifact (committed) | Source | Regenerate with | Purpose |
   |----------------------|--------|-----------------|---------|
   | `dart/shared/ball_protobuf.json` / `.bin` | `dart/ball_protobuf/lib/*.dart` | `melos run regen-protobuf` | Full protobuf runtime as a facade Ball `Module` (no entry point; `std` not bundled). Compile to your language ONLY if it lacks native protobuf (1.2 branch (c)). |
   | `dart/shared/ball_proto.json` / `.bin` | `dart/shared/lib/ball_proto.dart` | `cd dart/shared && dart run bin/gen_ball_proto.dart` | The `ball_proto` access-pattern module (oneof discriminators, presence checks, Struct access, proto3 defaults). ALWAYS needed to run the self-hosted engine; implement its 46 base functions (see `dart/shared/ball_proto.json`) per-platform in Phase 4. |

   The `ball_proto` base functions have `isBase: true` and no body — you supply native
   implementations. In Dart they map onto the protobuf-generated methods (`obj.whichExpr()`,
   `obj.hasBody()`); for a map-based representation implement them against your map type
   (`whichExpr(obj)` → the set oneof field name or `"notSet"`; `hasBody(obj)` → whether `body` is
   present and non-default; see the variant/field lists in `dart/shared/lib/ball_proto.dart`).

**Phase 1 checklist:**
- [ ] Directory structure created
- [ ] Protobuf strategy chosen via the 1.2 decision tree (buf plugin / community runtime / compile `ball_protobuf`)
- [ ] If a buf plugin is used: `buf.gen.yaml` updated and `buf generate` produces `<lang>/shared/gen/`
- [ ] If branch (c): `ball_protobuf.json` compiled to `<lang>/shared/` and a sample message round-trips (marshal → unmarshal)
- [ ] Package manifest created with protobuf runtime dependency
- [ ] BallValue / BallList / BallMap / BallFunction types defined
- [ ] Module builders created (or planned for later — at minimum `buildStdModule()`)
- [ ] Field extraction helper implemented
- [ ] `ball_proto` module accounted for (implemented in Phase 4 for the self-hosted engine)

---

## Phase 2: Compiler (Ball → Target Language)

The compiler reads a `Program` protobuf and emits target-language source code.

### 2.1 Core compiler structure

```
compile(Program) → String (or multiple files)
  1. Build lookup tables: types by name, functions by (module, name)
  2. Identify base modules: std, std_collections, std_io, std_memory
  3. Generate imports / preamble
  4. For each module (skip base modules):
     a. Generate types from typeDefs[]
     b. Generate functions (compile expression trees)
  5. Generate entry point: call entryModule.entryFunction
```

### 2.2 Expression compilation

Implement a recursive `compileExpression(Expression) → String` that handles all 7 types:

| Expression | Strategy |
|------------|----------|
| `literal` | Emit native literal (`42`, `"hello"`, `true`, `null`, `[1,2,3]`) |
| `reference` | Emit variable name; special-case `"input"` → function parameter name |
| `fieldAccess` | `compileExpr(object) + "." + fieldName` |
| `messageCreation` | Constructor call or struct/map literal with compiled field values |
| `call` (user fn) | `functionName(compileExpr(input))` |
| `call` (base fn) | **Dispatch table** — map to native operators/constructs (see 2.3) |
| `block` | Scoped block: let-bindings as variable declarations, statements, result expression |
| `lambda` | Anonymous function / closure capturing lexical scope |

### 2.3 Base function dispatch (CRITICAL)

This is the heart of the compiler. Create a dispatch function:

```
compileBaseCall(module, functionName, inputFields) → String
```

**Control flow functions MUST use lazy evaluation** — emit native control flow, NOT function calls:

| Function | Compilation Pattern |
|----------|-------------------|
| `std.if` | `if (condition) { then } else { else }` — NEVER evaluate both branches |
| `std.for` | `for (init; condition; update) { body }` |
| `std.while` | `while (condition) { body }` |
| `std.for_each` | `for (item in iterable) { body }` |
| `std.try` | `try { body } catch(e) { catch } finally { finally }` |
| `std.switch` | `switch (value) { case ...: ... }` |
| `std.and` | `left && right` (short-circuit) |
| `std.or` | `left \|\| right` (short-circuit) |

**Arithmetic / comparison / logic** — emit binary operators:

| Function | Pattern |
|----------|---------|
| `std.add` | `left + right` |
| `std.subtract` | `left - right` |
| `std.multiply` | `left * right` |
| `std.divide` | `left / right` |
| `std.modulo` | `left % right` |
| `std.equals` | `left == right` |
| `std.not_equals` | `left != right` |
| `std.less_than` | `left < right` |
| `std.greater_than` | `left > right` |
| `std.negate` | `-operand` |
| `std.not` | `!operand` |

**String / print / type ops** — emit method calls or built-in functions.

Reference: `dart/compiler/lib/compiler.dart` `_compileBaseCall()` has the complete dispatch for
all 118+ std functions.

### 2.4 Type emission

Read `metadata.kind` on each `TypeDefinition` to determine what to emit:

| `kind` | What to generate |
|--------|-----------------|
| `"class"` | Class with fields, constructors, methods |
| `"abstract_class"` | Abstract class / interface / protocol |
| `"enum"` | Enum type |
| `"mixin"` | Mixin / trait / protocol extension (if language supports it) |
| `"extension"` | Extension methods (if language supports it, otherwise static utils) |

Fields come from the `TypeDefinition.descriptor` (a protobuf `DescriptorProto`).
Methods are functions in the same module whose metadata has `is_method: true` and
`owner_type: "TypeName"`.

### 2.5 Multi-module output

For languages that use one-file-per-module (Go, Java, Kotlin, C#, Rust), implement:

```
compileAllModules(Program) → Map<String, String>  // moduleName → sourceCode
```

**Phase 2 checklist:**
- [ ] `compile(Program) → String` function implemented
- [ ] All 7 expression types handled recursively
- [ ] Base function dispatch covers at minimum: arithmetic (6), comparison (6), logic (3),
      `print`, `if`, `for`, `while`, `for_each`, `assign`, `index`, `try`, `return`,
      `break`, `continue`, `throw`
- [ ] Control flow uses lazy evaluation (NOT eager)
- [ ] Type emission handles class, enum, abstract_class at minimum
- [ ] Lambda compilation works (FunctionDefinition with empty name)
- [ ] `"input"` reference maps to function parameter
- [ ] Empty module in FunctionCall resolves to current module
- [ ] Tests pass for basic programs (hello_world, fibonacci, factorial)

---

## Phase 3: Encoder (Target Language → Ball)

The encoder reads source code and produces a Ball `Program` protobuf.

### 3.1 Parser strategy

Choose a parsing approach for the target language:

| Strategy | Examples | Pros | Cons |
|----------|---------|------|------|
| Official AST API | Dart (`analyzer`), TS (`ts-morph`), Rust (`syn`) | Accurate, maintained | Tight coupling to toolchain |
| Language server protocol | Any language with LSP | Standardized | Slow, complex setup |
| Compiler JSON AST | C++ (`clang -ast-dump=json`), Swift (`swiftc -dump-ast`) | Detailed | Fragile output format |
| Tree-sitter grammar | Most languages | Fast, universal | Less semantic info |

### 3.2 AST → Ball mapping

Walk the parsed AST and map each construct:

| Source Construct | Ball Expression |
|-----------------|-----------------|
| Binary operator `a + b` | `call(std, add, messageCreation({left: a, right: b}))` |
| Function call `f(x)` | `call(module, f, x)` |
| Variable declaration | `LetBinding` inside a `Block` |
| If statement | `call(std, if, messageCreation({condition, then, else}))` |
| For loop | `call(std, for, messageCreation({init, condition, update, body}))` |
| Class definition | `TypeDefinition` with `DescriptorProto` for fields |
| Method | `FunctionDefinition` with `is_method: true` in metadata |
| Lambda / closure | `FunctionDefinition` with name `""` |

### 3.3 Universal module architecture (no language-specific base modules)

Language-specific base modules (`dart_std`, `cpp_std`) have been eliminated from Ball.
All constructs must route through universal modules (`std`, `std_collections`, `std_io`,
`std_memory`). When the source language has constructs that don't map directly to a single
`std` call, the encoder should expand them into equivalent `std` expression trees at
encoding time. For example:
- Dart's `?.` (null-aware access) expands to `std.if(std.is_null(target), null, fieldAccess)`
- Dart's `..` (cascade) expands to a `Block` with a temp variable and sequential calls
- C++ pointer dereference inlines to `std_memory` operations or field access

Do NOT create `<lang>_std` base modules. This is a core design principle: encoders must
produce programs that any target compiler/engine can execute without language-specific handlers.

### 3.4 Metadata preservation

For round-trip fidelity, store cosmetic information in metadata:

- **Function metadata**: `visibility`, `is_async`, `is_static`, `is_abstract`, `annotations`,
  `return_type`, `type_parameters`
- **Type metadata**: `kind`, `superclass`, `interfaces`, `mixins`, `is_abstract`, `is_sealed`
- **Let-binding metadata**: `type`, `is_final`, `is_const`, `is_late`
- **Module metadata**: language-specific import/export info

### 3.5 Std module accumulation

As the encoder walks the AST, it tracks which std functions are referenced. After encoding,
call `buildStdModules()` to construct only the modules actually used by the program. This keeps
encoded programs minimal.

**Phase 3 checklist:**
- [ ] Parser chosen and integrated
- [ ] All major AST node types mapped to Ball expressions
- [ ] Operator mapping complete (arithmetic, comparison, logic, assignment)
- [ ] Control flow encoded as std function calls (if, for, while, etc.)
- [ ] Types encoded as TypeDefinitions with DescriptorProto fields
- [ ] All constructs route through universal `std` (no `<lang>_std` base modules)
- [ ] Metadata preserved for round-trip fidelity
- [ ] Std modules accumulated from actual usage
- [ ] Round-trip test: encode → compile → verify output matches original semantics

---

## Phase 4: Engine (Ball Interpreter / Self-Hosted Engine)

You have two options for the engine. **Option B (self-hosted) is strongly recommended** for new
languages — it gives you a working engine with minimal effort.

### Option A: Hand-written engine (tree-walking interpreter)

Implement from scratch. Required components:

1. **Scope chain**: Lexical scoping with parent pointers
   ```
   Scope { bindings: Map<String, BallValue>, parent: Scope? }
   lookup(name) → walk parent chain
   bind(name, value) → add to current scope
   set(name, value) → find and update in chain
   ```

2. **Expression evaluator**: Recursive `eval(Expression, Scope) → BallValue`

3. **Module handler interface**:
   ```
   interface BallModuleHandler {
     handles(moduleName: String) → bool
     call(functionName: String, input: BallValue, engine: BallCallable) → BallValue
   }
   ```

4. **Std module handler**: Dispatch all 118+ std functions to native implementations.
   Must implement lazy evaluation for control flow (if, for, while, etc.).

5. **Flow signals**: Break/continue/return propagate as special values up the call stack.
   ```
   FlowSignal { kind: "break"|"continue"|"return", label?: String, value?: BallValue }
   ```

6. **Virtual properties**: Built-in properties on native types (`.length`, `.isEmpty`, etc.)

### Option B: Self-hosted engine (RECOMMENDED)

The Dart reference engine is self-encoded as a Ball program at `dart/self_host/engine.ball.json`.
Compile it to your target language using your compiler from Phase 2:

```bash
cd <lang>/compiler
<lang-run-command> compile ../../dart/self_host/engine.ball.json -o ../engine/src/compiled_engine.<ext>
```

Then create a thin wrapper (`<lang>/engine/src/index.<ext>`) that:
1. Loads and deserializes Ball programs (proto3 JSON or binary)
2. Calls the compiled engine's entry point
3. Provides std function implementations that the compiled engine calls back into
4. Handles I/O (print, file ops, etc.) via platform-native code

Reference wrappers:
- TypeScript: `ts/engine/src/index.ts` — wraps `compiled_engine.ts`
- C++: `cpp/shared/include/ball_dyn.h` + `dart/self_host/lib/engine_rt.cpp`

**Self-host regeneration command** (add to your build tooling):
```bash
# Regenerate the self-hosted engine whenever the Dart engine changes
cd dart && dart run compiler/tool/compile_engine_<lang>.dart
# Or use your own compiler:
<lang>/compiler/compile ../../dart/self_host/engine.ball.json -o <lang>/engine/src/compiled_engine.<ext>
```

**Phase 4 checklist:**
- [ ] Engine can execute `hello_world.ball.json` and produce correct output
- [ ] Engine can execute `fibonacci.ball.json` correctly
- [ ] All control flow works: if/else, for, while, break, continue, return
- [ ] Scoping is correct: closures capture lexical scope
- [ ] Flow signals propagate correctly through nested expressions
- [ ] Virtual properties work on strings, lists, maps
- [ ] Engine passes **all** conformance tests in `tests/conformance/` (no tolerated failures — a partial pass rate is progress toward this bar, not completion)

---

## Phase 5: CLI Integration

### 5.1 CLI entry point

Create `<lang>/cli/` with a CLI that supports these subcommands:

| Command | Description |
|---------|-------------|
| `ball run <file.ball.json>` | Execute a Ball program |
| `ball compile <file.ball.json> -o <output>` | Compile Ball to target language |
| `ball encode <source-file> -o <output.ball.json>` | Encode source to Ball |
| `ball check <file.ball.json>` | Validate a Ball program (type-check, lint) |

### 5.2 Input formats

Support both:
- **Proto3 JSON** (`.ball.json`) — human-readable, used for examples and debugging
- **Binary protobuf** (`.ball.bin`) — compact, used for distribution

### 5.3 Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Runtime error (program threw an exception) |
| 2 | Compilation error (invalid Ball program) |
| 3 | I/O error (file not found, permission denied) |

**Phase 5 checklist:**
- [ ] `ball run` executes programs and prints output to stdout
- [ ] `ball compile` generates target-language source
- [ ] `ball encode` parses source and produces `.ball.json`
- [ ] Both `.ball.json` and `.ball.bin` inputs are supported
- [ ] Exit codes follow the convention above
- [ ] `--help` works for all subcommands

---

## Phase 6: Conformance Tests

### 6.1 Conformance test runner

Conformance tests live in `tests/conformance/`. Each is a `.ball.json` program with expected
output. Create a test runner that:

1. Discovers all `tests/conformance/*.ball.json` files
2. Runs each through the engine
3. Compares stdout output against `tests/conformance/*.expected` (or inline expected output)
4. Reports pass/fail with counts

**Output format** (for CI matrix parsing):
```
Results: <passed> passed, <failed> failed, <total> total
```

### 6.2 Compiler conformance

Additionally test the compiler path:
1. Compile each `.ball.json` to target language source
2. Execute the compiled source using the language's native toolchain
3. Compare output against expected

### 6.3 Round-trip conformance

For the encoder, test the round-trip:
1. Compile `.ball.json` → target language source
2. Encode that source back → `.ball.json`
3. Run the re-encoded program through the Dart reference engine
4. Verify output matches

**Phase 6 checklist:**
- [ ] Conformance test runner discovers all `tests/conformance/*.ball.json`
- [ ] Engine conformance: run each program, compare output
- [ ] Track pass/fail counts with `Results: N passed, M failed, T total` output format
- [ ] At least `hello_world`, `fibonacci`, `factorial`, `string_ops` pass
- [ ] Compiler conformance: compile → execute → compare
- [ ] Round-trip test exists (even if not all tests pass yet)

---

## Phase 7: CI/CD Integration

### 7.1 Add to `ci.yml`

Add a new job to `.github/workflows/ci.yml` following this template:

```yaml
  <lang>:
    name: <Lang>
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      # Setup language toolchain
      - name: Setup <Lang>
        uses: <official-setup-action>
        with:
          <lang>-version: <version>

      # Setup buf for proto generation (if needed at build time)
      - uses: bufbuild/buf-action@v1
        with:
          setup_only: true

      # Install dependencies
      - name: Install dependencies
        run: <package-install-command>

      # Build
      - name: Build
        run: <build-command>

      # Test
      - name: Run tests
        run: <test-command>

      # Conformance
      - name: Conformance tests
        run: <conformance-test-command>
```

Use the current setup action for the language (verified majors, May 2026 — `actions-rs/*` is
deprecated, do not use it):

| Language | Setup action (`uses:`) |
|----------|------------------------|
| Dart | `dart-lang/setup-dart@v1` |
| Node / TypeScript | `actions/setup-node@v6` |
| Python | `actions/setup-python@v6` |
| Go | `actions/setup-go@v6` |
| Java / Kotlin | `actions/setup-java@v5` (with `distribution: temurin`) |
| Rust | `dtolnay/rust-toolchain@stable` |
| Swift | `swift-actions/setup-swift@v3` |
| Ruby | `ruby/setup-ruby@v1` |

### 7.2 Add to `conformance-matrix.yml`

Add a new job and wire it into the summary matrix:

```yaml
  <lang>-engine:
    name: <Lang> Engine
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Setup <Lang>
        uses: <setup-action>
      - name: Install & build
        run: <build-commands>
      - name: Run conformance tests
        id: conformance
        run: |
          set +e
          output=$(<conformance-test-command> 2>&1)
          exit_code=$?
          echo "$output"

          passed=$(echo "$output" | grep -oP 'Results: \K\d+(?= passed)')
          failed=$(echo "$output" | grep -oP ', \K\d+(?= failed)')
          total=$(echo "$output" | grep -oP ', \K\d+(?= total)')

          echo "passed=${passed:-0}" >> "$GITHUB_OUTPUT"
          echo "failed=${failed:-0}" >> "$GITHUB_OUTPUT"
          echo "total=${total:-0}" >> "$GITHUB_OUTPUT"
          exit $exit_code
    outputs:
      passed: ${{ steps.conformance.outputs.passed }}
      failed: ${{ steps.conformance.outputs.failed }}
      total: ${{ steps.conformance.outputs.total }}
```

Then add the new engine to the `summary` job's `needs:` list, add a `print_row` call, and
include it in the failure check.

### 7.3 Package publishing (optional)

If the language has a public package registry, create a publish workflow:

Modern registries favor **OIDC trusted publishing** (tokenless, short-lived credentials) over
long-lived secrets. Any OIDC publish job needs `permissions: id-token: write`.

| Language | Registry | Auth Method (current → legacy fallback) |
|----------|----------|------------------------------------------|
| TypeScript | npm | OIDC trusted publishing (GA 2025-07-31) → `NODE_AUTH_TOKEN` |
| Rust | crates.io | OIDC trusted publishing (`rust-lang/crates-io-auth-action@v1`) → `CARGO_REGISTRY_TOKEN` |
| Python | PyPI | OIDC trusted publishing → API token |
| Go | proxy.golang.org | Auto (tag-based; no auth/upload) |
| Java/Kotlin | Maven Central | GPG signing + Sonatype **Central Portal** token (central.sonatype.com). NOTE: legacy OSSRH/s01.oss.sonatype.org was sunset 2025-06-30 — do not use it |
| C# | NuGet | OIDC trusted publishing (short-lived key) → `NUGET_API_KEY` |
| Ruby | RubyGems | OIDC trusted publishing (`rubygems/configure-rubygems-credentials`) → `GEM_HOST_API_KEY` |
| Swift | Swift Package Index | Auto (git-tag discovery; index, not a hosted registry — no auth) |

**Phase 7 checklist:**
- [ ] Job added to `ci.yml` — builds and tests on every PR
- [ ] Job added to `conformance-matrix.yml` — tracked in parity matrix
- [ ] Summary job updated with new engine row
- [ ] (Optional) Publish workflow created for the package registry
- [ ] All CI jobs pass on a clean checkout

---

## Phase 8: Documentation & Agent Configs

### 8.1 Create `<lang>/AGENTS.md`

Follow the pattern from `dart/AGENTS.md` or `ts/AGENTS.md`:

```markdown
# <Lang> Ball Implementation

## Packages
- `<lang>/shared/` — Protobuf bindings and shared types
- `<lang>/compiler/` — Ball → <Lang> compiler
- `<lang>/encoder/` — <Lang> → Ball encoder
- `<lang>/engine/` — Ball interpreter / self-hosted engine
- `<lang>/cli/` — CLI entry point

## Build & Test
<build and test commands>

## Generated Files — NEVER Edit
- `<lang>/shared/gen/` — Protobuf generated types
- `<lang>/engine/src/compiled_engine.<ext>` — Self-hosted engine (if applicable)

## Testing
- Conformance tests: `<conformance-test-command>`
- Unit tests: `<unit-test-command>`
- Prefer conformance tests over unit tests

## Architecture
<brief description of key design decisions>
```

### 8.2 Create `.claude/rules/<lang>.md`

```markdown
---
paths:
  - "<lang>/**"
---

# <Lang>-Specific Instructions

## Package Structure
<description of packages and their roles>

## Key Patterns
### Compiler
<compiler patterns>

### Encoder
<encoder patterns>

### Engine
<engine patterns>

## Generated Files — NEVER Edit
<list of generated files>

## Testing
<test commands and patterns>

## Dependencies
<key dependencies>
```

### 8.3 Update root `CLAUDE.md`

Add the new language to the "Build & Test" section and the "Architecture Big Picture" section.

### 8.4 Update root `AGENTS.md`

Add the new language to the "Project Context" section.

**Phase 8 checklist:**
- [ ] `<lang>/AGENTS.md` created
- [ ] `.claude/rules/<lang>.md` created
- [ ] Root `CLAUDE.md` updated with build/test commands
- [ ] Root `AGENTS.md` updated with new language in project context
- [ ] All existing documentation still accurate after changes

---

## Quality Gates

Before declaring a new language "complete", verify:

| Gate | Minimum | Target |
|------|---------|--------|
| Compiler: basic programs | hello_world, fibonacci, factorial | All examples/ compile |
| Engine: conformance | core programs (hello_world, fibonacci, factorial) run | 100% of `tests/conformance/` (parity with Dart) |
| Encoder: round-trip | 3+ programs round-trip correctly | All examples/ round-trip |
| CI: all jobs green | Build + test pass | Conformance matrix row added |
| Docs: agent-ready | AGENTS.md + rule file exist | Full CLAUDE.md integration |

## Reference Implementation Cross-Links

| Component | Dart Reference | TS Reference | C++ Reference |
|-----------|---------------|--------------|---------------|
| Compiler | `dart/compiler/lib/compiler.dart` | `ts/compiler/src/compiler.ts` | `cpp/compiler/src/compiler.cpp` |
| Encoder | `dart/encoder/lib/encoder.dart` | `ts/encoder/src/encoder.ts` | `cpp/encoder/src/encoder.cpp` |
| Engine | `dart/engine/lib/engine.dart` | `ts/engine/src/index.ts` | `dart/self_host/lib/engine_rt.cpp` |
| Std module | `dart/shared/lib/std.dart` | (generated from Dart) | `cpp/shared/include/ball_shared.h` (declares `build_std_module()`) |
| CLI | `dart/cli/` | `ts/cli/` | N/A |
| Tests | `dart/engine/test/` | `ts/engine/test/` | `cpp/test/` |
| Self-host | `dart/self_host/engine.ball.json` | `ts/engine/src/compiled_engine.ts` | `dart/self_host/lib/engine_rt.cpp` |
