# Embedding the Ball engine, per target

Verified against the Ball repo (`Ball-Lang/ball`). Every snippet below is grounded in real APIs — the constructor surfaces, defaults, and gaps are from source, not invented. Statuses drift; re-verify against the packages' current versions and the repo CI before shipping.

Two layers apply to every target:
- **Audit** (static, pre-execution) — see `audit-and-policy.md`.
- **Engine sandbox + limits + module allowlist** (run-time) — below.

They are complementary. The audit is a fast, provably-complete pre-filter over *known base functions*; the engine's fail-closed-on-unknown-handler behavior plus your `subset` allowlist is the actual boundary. **On TS the run-time allowlist does not exist (see below), so the audit is the whole gate there.**

---

## Dart — the reference target (`ball_engine` + `ball_base`, pub.dev)

Published packages; no `publish_to: none`. This is the only target with the full untrusted-input story: sandbox, all resource limits, `moduleHandlers`, and an **in-process** audit library.

> **Platform caveat.** `ball_engine` transitively imports `dart:io` (through `package:ball_resolver`, and its own `Platform`/`stderr` use) and **does not compile for Flutter/Dart web**. `ball_base` (the audit library) *does* support web. So a web client can audit a program on-device but must execute it on a non-web runtime (mobile/desktop/server, or a server-side Dart/Rust engine). Plan the split before committing to a web target.

### `BallEngine` constructor (`dart/engine/lib/engine.dart`)

```dart
BallEngine(
  Program program, {                     // NOTE: a Program, never a bare Module
  void Function(String)? stdout,        // default: print
  void Function(String)? stderr,        // default: io.stderr.writeln
  String Function()? stdinReader,       // null = no stdin
  String Function(String)? envGet,      // default: Platform.environment
  List<String>? args,                   // CLI-argv-shaped; NOT structured input
  bool enableProfiling = false,
  int maxRecursionDepth = 10000,        // nested non-base Ball calls
  int? timeoutMs,                       // null = unbounded (wall clock)
  int? maxMemoryBytes,                  // null = unbounded (approx allocations)
  int maxModules = 100,
  int maxExpressionDepth = 1000,
  int? maxProgramSizeBytes,             // null = OFF even for trusted runs (opt-in)
  bool sandbox = false,
  List<BallModuleHandler>? moduleHandlers,  // default: [StdModuleHandler()]
  ModuleResolver? resolver,             // ⚠ import/network vector — leave null for untrusted input
})
```

`run()` is `Future<Object?>` and returns the **entry function's return value** (a Ball value: `Map`/`List`/scalar). Program `std.print` output is delivered via the `stdout` callback, NOT via `run()`'s return (this diverges from TS/Rust, which capture and return stdout lines). To get a computed result back, read `run()`'s return value; to invoke a specific function with structured input, use `callFunction` (below).

### Untrusted-input embedding (verified API — copy this whole shape)

```dart
import 'dart:convert';
import 'package:ball_base/ball_base.dart' show decodeBallFileJson, BallProgramFile;
import 'package:ball_base/capability_analyzer.dart';
import 'package:ball_base/termination_analyzer.dart';
import 'package:ball_engine/engine.dart';

// Take the RAW received bytes, not a pre-decoded String.
Future<Object?> runUntrusted(List<int> rawBytes) async {
  // 0. Size-gate the RAW bytes BEFORE decoding. (String.length counts UTF-16
  //    code units — a CJK payload is ~3x its char count in real bytes and would
  //    slip a String-length check after the expensive UTF-8 decode already ran.)
  if (rawBytes.length > 512 * 1024) throw StateError('program too large');

  // 1. Decode ONCE. Audit and run THIS object (no re-decode → no TOCTOU).
  final file = decodeBallFileJson(jsonDecode(utf8.decode(rawBytes)));
  if (file is! BallProgramFile) throw StateError('expected a Program');
  final program = file.program;

  // 2. Audit — provably-complete over KNOWN base functions only.
  //    reachableOnly:false → audit EVERY function, including unreached branches
  //    (strict pre-filter; audit-and-policy.md explains the trade-off).
  final report = analyzeCapabilities(program, reachableOnly: false);
  final violations = checkPolicy(report, deny: {'fs', 'process', 'memory', 'concurrency'});
  if (violations.isNotEmpty) throw StateError('policy violation: ${violations.join(', ')}');
  final term = analyzeTermination(program);
  if (term.hasErrors) throw StateError('termination risk');

  // 2b. The audit is BLIND to custom/unknown isBase modules and to module_imports.
  //     Enforce your own allowlist + reject imports here (runnable, not a comment).
  const allowedModules = {
    'std', 'std_collections', 'std_convert',   // pure std you permit
    'ui',                                       // your own vetted handler(s)
  };
  for (final m in program.modules) {
    if (m.moduleImports.isNotEmpty) {
      throw StateError('rejected: module "${m.name}" declares module_imports');
    }
    for (final f in m.functions) {
      if (f.isBase && !allowedModules.contains(m.name)) {
        throw StateError('rejected isBase "${m.name}.${f.name}" outside allowlist');
      }
    }
  }

  // 3. Execute locked down. Wrap the CONSTRUCTOR too — maxProgramSizeBytes/maxModules
  //    validate in the constructor and throw synchronously (engine.dart:229/247).
  //    On Dart, subset() IS wired in via moduleHandlers → a real run-time allowlist.
  try {
    final std = StdModuleHandler.subset({'print', 'add', 'subtract', 'if', 'for_in', 'equals'});
    final engine = BallEngine(
      program,
      sandbox: true,               // blocks std_fs.* + std_io.exit/panic/env_get
      timeoutMs: 2000,
      maxMemoryBytes: 16 * 1024 * 1024,
      maxRecursionDepth: 500,      // default 10000
      maxExpressionDepth: 200,     // default 1000
      maxModules: 4,               // default 100  (throws in ctor if exceeded)
      maxProgramSizeBytes: 512 * 1024,
      moduleHandlers: [std],       // + your vetted app modules; NO std_fs/memory/concurrency
      // resolver: left null on purpose — do not resolve remote/inline imports.
      stdout: (line) => myLogger.log(line),
      stderr: (_) {},              // do not surface raw errors to UI/logs untriaged
    );
    return await engine.run();
  } on BallRuntimeError catch (e) {
    throw StateError('engine rejected program: $e');   // e.g. "Program too large", sandbox violation
  }
}
```

### Executing a delivered library `Module` (no entry point)

`BallEngine` only accepts a `Program`. To audit and run a bare `Module`:

```dart
import 'package:ball_base/capability_analyzer.dart';

// Audit a Module with the Module-typed API (analyzeCapabilities won't accept it).
// `imports` resolves cross-module references; pass the modules it depends on, or
// const [] if it is self-contained. (Reject non-empty module.moduleImports first,
// as above — do not fetch remote imports for untrusted input.)
final modReport = analyzeModuleCapabilities(untrustedModule, imports: const []);
// ... checkPolicy(modReport, deny: {...}) + your isBase-allowlist walk ...

// Wrap it into a runnable Program with an entry point you choose.
final program = Program(
  name: 'wrapped',
  modules: [untrustedModule],
  entryModule: untrustedModule.name,
  entryFunction: 'main',           // a function you require the Module to expose
);
final engine = BallEngine(program, sandbox: true, /* + limits + moduleHandlers */);
await engine.run();
```

If the client drives the UI loop itself, skip the entry point and invoke vetted functions directly with `callFunction(untrustedModule.name, 'render', input)` on an engine constructed around a minimal wrapper `Program`.

### `BallModuleHandler` — the vetted-surface seam (`dart/engine/lib/engine_types.dart:403`)

```dart
abstract class BallModuleHandler {
  bool handles(String module);      // NEVER `=> true` — that defeats fail-closed
  FutureOr<Object?> call(String function, Object? input, BallCallable engine);
  void init(BallEngine engine) {}   // called once at construction, before any statement runs
}
```

- `BallCallable engine` lets a handler call back into other Ball functions (e.g. a `ui.button` handler re-invoking a user `onTap`) without holding a raw `BallEngine`.
- `StdModuleHandler` `handles()` is a fixed switch over exactly the eight `std*` modules — you **cannot** add a new module name through it; that always needs your own handler.
- `StdModuleHandler()` = full built-ins. `StdModuleHandler.subset({fns})` = allow-list (anything else throws at call time). `.register`/`.registerComposer`/`.unregister` tweak individual functions, still confined to `std*` names.

### Structured input / output

```dart
// callFunction(module, function, input) → Future<Object?>  (engine.dart:244)
final decision = await engine.callFunction('rules', 'evaluate', {
  'cartTotal': 42.0, 'tier': 'gold',            // structured context IN
});
// decision is a Ball value (Map/List/scalar) OUT — e.g. {'discount': 0.1}
```

### In-process audit (Dart only)

`package:ball_base/capability_analyzer.dart` exports `analyzeCapabilities`, `analyzeModuleCapabilities`, `checkPolicy`, `formatCapabilityReport`; `.../termination_analyzer.dart` exports `analyzeTermination`. No subprocess needed. This is the one target where a client can audit on-device before constructing an engine.

---

## TypeScript — `@ball-lang/engine` (npm)

```ts
import { BallEngine } from '@ball-lang/engine';

interface BallEngineOptions {
  stdout?: (msg: string) => void;
  stderr?: (msg: string) => void;
  timeoutMs?: number | null;          // default null (unbounded)
  maxMemoryBytes?: number | null;     // default null (unbounded)
  maxModules?: number;                // default 1_000_000  (NOT Dart's 100)
  maxExpressionDepth?: number;        // default 1_000_000  (NOT Dart's 1000)
  maxProgramSizeBytes?: number | null;// default null (unchecked)
  sandbox?: boolean;                  // default false
  maxRecursionDepth?: number;         // default 100_000    (NOT Dart's 10000)
  // NOTE: there is NO `moduleHandlers` field — see gaps below.
}
class BallEngine {
  constructor(program: any, options?: BallEngineOptions);
  run(): Promise<string[]>;   // captures std.print lines when no custom stdout given
  getOutput(): string[];
}
```

**The permissive defaults are the trap** — you MUST pass explicit tight values; do not assume the defaults sandbox anything.

### Full gated flow (the TS equivalent of `runUntrusted` — do not ship the bare constructor)

Because TS has **no** in-process capability library and **no** run-time std allowlist, your gate is: size-check → parse → your own module-allowlist walk + reject imports → construct (in try/catch) → run.

```ts
import { BallEngine } from '@ball-lang/engine';

async function runUntrusted(rawBytes: Uint8Array): Promise<string[]> {
  // 0. Size-gate the RAW bytes before decoding.
  if (rawBytes.byteLength > 512 * 1024) throw new Error('program too large');

  // 1. Decode once; audit and run THIS object.
  const text = new TextDecoder().decode(rawBytes);
  const parsed = JSON.parse(text);
  const program = parsed?.['@type'] ? stripAtType(parsed) : parsed;   // unwrap Any envelope if present

  // 2. Own allowlist walk (the ONLY structural gate on TS). Proto field names:
  //    program.modules[].name / .functions[].isBase / .moduleImports (camelCased).
  const allowed = new Set(['std', 'std_collections', 'std_convert', 'ui']);
  for (const m of program.modules ?? []) {
    if ((m.moduleImports ?? []).length > 0) throw new Error(`module "${m.name}" declares imports`);
    for (const f of m.functions ?? []) {
      if (f.isBase && !allowed.has(m.name)) throw new Error(`isBase ${m.name}.${f.name} not allowlisted`);
    }
  }
  // (Optionally ALSO shell out to `ball audit` — see the subprocess recipe below.)

  // 3. Construct in try/catch (maxProgramSizeBytes/maxModules throw from the CTOR,
  //    not run() — an oversized payload otherwise crashes the process).
  let engine: BallEngine;
  try {
    engine = new BallEngine(program, {
      sandbox: true,
      timeoutMs: 2000,
      maxMemoryBytes: 16 * 1024 * 1024,
      maxModules: 4,
      maxExpressionDepth: 200,
      maxRecursionDepth: 500,
      maxProgramSizeBytes: 512 * 1024,
    });
  } catch (e) {
    throw new Error(`rejected at construction: ${e}`);
  }
  return await engine.run();
}
```

### Gaps to design around (verified, current)

- **No run-time std restriction, and no custom modules.** `new BallEngine(...)` always constructs a fresh, full `StdModuleHandler` internally (`ts/engine/src/index.ts:83`) and passes a hard-coded handler list (`[methodHandler, stdHandler]`, `:114`). `BallEngineOptions` has no `moduleHandlers` field and there is **no injection point** — a `StdModuleHandler.subset({...})` you construct is *never wired in*, so it does nothing (verified: `std_concurrency.mutex_create` runs fine under `sandbox:true` with an ignored `subset({'print'})` sitting next to it). Consequence: on TS every implemented `std_*` function stays reachable at run time; `sandbox:true` still blocks `std_fs.*` + `std_io.exit`/`panic`/`env_get`, but nothing trims `std_concurrency` or the rest. **Your audit/allowlist walk is the only thing keeping those out — it is not optional.** Treat custom-native-module dynamic UI (`ui.render`) as a Dart-only story until this lands.
- **No in-process audit library.** `@ball-lang/cli`'s package `exports` map exposes only the CLI entrypoint; `capability_analyzer.js` ships in the tarball but importing it fails with `ERR_PACKAGE_PATH_NOT_EXPORTED`. Audit by (a) your own `program.modules[]` walk above, and/or (b) spawning the CLI as a subprocess.
- **Subprocess audit is file-based and `ball` is not on PATH.** `ball audit` has **no stdin mode** (`ball audit -` / `/dev/stdin` both fail "File not found"), so you must pass a file — and after `npm install @ball-lang/cli` the binary is `node_modules/.bin/ball` (a Windows-shell-dependent shim), not a global `ball`. Portable invocation: `npx ball audit <file>` or spawn `node_modules/.bin/ball` by explicit path. **To preserve "audit the exact bytes you execute" (TOCTOU):** write the received bytes to one temp file, `ball audit` *that* file, and load *that same file* into the engine — never audit a serialization you re-derive.

---

## Rust — `ball-engine` (NOT published; vendor from git)

> **⚠ `cargo add ball-engine` installs the wrong crate.** The name `ball-engine` on crates.io is an unrelated **2D physics engine** (`v0.1.1`, `github.com/parth2152012/ball-engine`, Macroquad-based), and `ball-shared`/`ball-lang` do not exist there (404). No Ball-Lang Rust crate is currently published to crates.io. Depend on the repo directly and verify provenance:

```toml
# Cargo.toml — vendor from git, not crates.io
[dependencies]
ball-engine = { git = "https://github.com/Ball-Lang/ball", package = "ball-engine" }
```

The git checkout has the `self_host` feature **off** by default, so a bare build returns `SelfHostPending` from `run()` until the generated `compiled_engine.rs` exists — see `rust/engine/AGENTS.md` for the `cargo run -p ball-engine-regen` + `--features self_host` regeneration workflow. (A future crates.io publish job is wired in `publish-crates.yml` to flip that default and include the generated file, but it has not run — do not assume a published crate exists.)

```rust
use ball_engine::BallEngine;

let engine = BallEngine::from_json(&program_json)?;  // or ::from_binary(&bytes)
let lines: Vec<String> = engine.run()?;              // captured stdout
```

```rust
pub enum EngineError { Parse(String), Runtime(String), SelfHostPending(String) }
```

### Gap: trusted programs only

`run(&self)` takes **no arguments** — there is no public `sandbox`, `timeoutMs`, `maxMemoryBytes`, or `moduleHandlers`. Internally it hard-codes one full `StdModuleHandler`, `maxRecursionDepth: 100_000`, unlimited everything else, `sandbox: false`. **Embedding untrusted programs safely via this crate is not possible yet** — you cannot restrict the std surface, set a timeout, or add a custom module from outside the crate. Use Rust for trusted programs (it matches Dart output); do untrusted-input audit/sandboxing on Dart.

---

## C++ — `engine_rt` (vendored, no package)

There is no C++ engine package (no vcpkg/Conan artifact; `cpp/AGENTS.md`: "prototype-quality code, not production-ready"). The engine is `dart/self_host/lib/engine_rt.cpp`, a **generated, gitignored** artifact. To embed it you must vendor the Ball repo, run the Dart toolchain to regenerate it (`dart run compiler/tool/compile_engine_cpp.dart --monolithic`), and literally `#include "engine_rt.cpp"` into a translation unit (as `cpp/cli/src/cli_run.cpp` does).

Embedding is raw struct manipulation (real code from `cmd_run`), abbreviated:

```cpp
#include "engine_rt.cpp"   // generated self-hosted engine, ball_rt namespace
BallEngine engine;
engine.program = BallDyn(programAny);
engine._types = BallDyn(BallMap{});
// ... several more internal fields zero-initialized ...
engine.stdout_ = BallDyn(BallFunc([](std::any a) -> std::any {
  std::cout << ball_to_string(a) << "\n"; return std::any{};
}));
auto stdDispatch = engine._buildStdDispatch();
StdModuleHandler handler(BallMap{{"_dispatch", std::any(stdDispatch)}});
engine.moduleHandlers = BallDyn(BallList{std::any(BallDyn(handler))});
engine._buildLookupTables();
engine._initTopLevelVariables();
engine.run();
```

No `sandbox`/`timeoutMs`/`maxMemoryBytes` is surfaced in this pattern — it runs fully trusted programs only. The least mature embedding target.

---

## C# — not embeddable yet

`csharp/engine/src/CompiledEngine.cs` is generated only under `-p:SelfHost=true`, and even then does not reach golden output (per `csharp/AGENTS.md`: still short of `hello_world`/`fibonacci`). The default-build wrapper's `BallEngine.Run` throws `SelfHostPendingException`. No C# CI job exists yet. There is no working `.Run()` today.

What IS real and usable from C#: `Ball.Shared` (proto bindings + `BallValue`/`BallList`/`BallMap`/`BallMessage`/`BallFunction`) and the C#→Ball encoder (`csharp/encoder/`) — useful for *authoring/encoding* Ball programs from C# source, not for running them in a C# host. (Directories such as `csharp/engine/` and `csharp/cli/` exist on the branch but are mid-bootstrap; verify against CI, not prose.)

---

## Transport: `.ball.bin` vs `.ball.json`

Both are self-describing `google.protobuf.Any` envelopes wrapping exactly one top-level message — `Program` (has `entryModule`/`entryFunction`) or a library `Module` (an API surface, no entry point). The `@type`/`type_url` discriminates them, so one decode path serves both.

- **JSON**: `{"@type": "type.googleapis.com/ball.v1.Program", …}` — human-readable, larger.
- **Binary** (`.ball.bin`): real protobuf `Any` — smaller, faster to parse, opaque; good for gRPC/WebSocket binary frames.

Loader strictness differs and matters:

| Loader | Bare `Program` (no `@type`)? | `.ball.bin`? |
|---|---|---|
| **Dart CLI/engine** (`decodeProgramJson`) | **Rejected** — `@type` is mandatory. | Yes (audit/encode verbs; `run`/`compile` are JSON-only). |
| **Rust engine** | Tolerated (strips `@type` if present). | Yes (engine + CLI). |
| **TS engine** | Tolerated (`unwrapBallFile`). | No binary path in the public constructor (JSON/object only). |
| **C++ `ball run`** | Tolerated. | **No** — text/JSON only, no `.bin` branch. |

So: an app on a non-Dart engine may serve a bare `Program` JSON; an app on the Dart CLI/engine must send the `{"@type": …}` wrapper. Binary transport is solid on Dart (audit/encode) and Rust (engine + CLI), but is not wired into the C++ `run` command or the TS engine constructor. There is no repo-recommended size threshold for choosing JSON vs binary — the only size knob is the engine's opt-in `maxProgramSizeBytes`, orthogonal to wire format. Regardless of format, apply your own **raw-byte** size gate at the transport layer first (see the Dart/TS snippets). For "dynamic UI," a `Module` (vetted, entry-point-free UI functions) fits when the client drives the loop; a `Program` fits when the server dictates control flow — remember a `Module` must be wrapped into a `Program` to run (Dart snippet above).
