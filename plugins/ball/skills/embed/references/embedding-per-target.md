# Embedding the Ball engine, per target

Verified against the Ball repo (`Ball-Lang/ball`). Every snippet below is grounded in real APIs — the constructor surfaces, defaults, and gaps are from source, not invented. Statuses drift; re-verify against the packages' current versions and the repo CI before shipping.

Two layers apply to every target:
- **Audit** (static, pre-execution) — see `audit-and-policy.md`.
- **Engine sandbox + limits + module allowlist** (run-time) — below.

They are complementary. The audit is a fast, provably-complete pre-filter over *known base functions*; the engine's fail-closed-on-unknown-handler behavior plus your `subset` allowlist is the actual boundary.

---

## Dart — the reference target (`ball_engine` + `ball_base`, pub.dev)

Published packages; no `publish_to: none`. This is the only target with the full untrusted-input story: sandbox, all resource limits, `moduleHandlers`, and an **in-process** audit library.

### `BallEngine` constructor (`dart/engine/lib/engine.dart`)

```dart
BallEngine(
  Program program, {
  void Function(String)? stdout,        // default: print
  void Function(String)? stderr,        // default: io.stderr.writeln
  String Function()? stdinReader,       // null = no stdin
  String Function(String)? envGet,      // default: Platform.environment
  List<String>? args,
  bool enableProfiling = false,
  int maxRecursionDepth = 10000,        // nested non-base Ball calls
  int? timeoutMs,                       // null = unbounded (wall clock)
  int? maxMemoryBytes,                  // null = unbounded (approx allocations)
  int maxModules = 100,
  int maxExpressionDepth = 1000,
  int? maxProgramSizeBytes,             // null = OFF even for trusted runs (opt-in)
  bool sandbox = false,
  List<BallModuleHandler>? moduleHandlers,  // default: [StdModuleHandler()]
  ModuleResolver? resolver,
})
```

`run()` is `Future<Object?>` and returns the **entry function's return value**. Program `std.print` output is delivered via the `stdout` callback, NOT via `run()`'s return (this diverges from TS/Rust, which capture and return stdout lines). To get a computed result back, either read `run()`'s return value or have the program `print` a JSON string you parse.

### Untrusted-input embedding (verified API)

```dart
import 'dart:convert';
import 'package:ball_base/ball_base.dart' show decodeBallFileJson, BallProgramFile;
import 'package:ball_base/capability_analyzer.dart';
import 'package:ball_base/termination_analyzer.dart';
import 'package:ball_engine/engine.dart';

Future<void> runUntrusted(String programJson) async {
  // 0. Size-gate the RAW string before parsing (maxProgramSizeBytes fires post-decode).
  if (programJson.length > 512 * 1024) throw StateError('program too large');

  final file = decodeBallFileJson(jsonDecode(programJson));
  if (file is! BallProgramFile) throw StateError('expected a Program');
  final program = file.program;

  // 1. Audit — provably-complete over KNOWN base functions only.
  final report = analyzeCapabilities(program, reachableOnly: true);
  final violations = checkPolicy(report, deny: {'fs', 'process', 'memory', 'concurrency'});
  if (violations.isNotEmpty) throw StateError('policy violation: ${violations.join(', ')}');
  final term = analyzeTermination(program);
  if (term.hasErrors) throw StateError('termination risk');

  // 1b. Audit can't see custom/unknown isBase modules — reject them yourself.
  //     (walk program.modules; reject any isBase function whose module is not allowlisted)

  // 2. Execute locked down: subset allowlist (stronger than sandbox alone) + all limits.
  final std = StdModuleHandler.subset({'print', 'add', 'subtract', 'if', 'for_in', 'equals'});
  final engine = BallEngine(
    program,
    sandbox: true,               // blocks std_fs.* + std_io.exit/panic/env_get
    timeoutMs: 2000,
    maxMemoryBytes: 16 * 1024 * 1024,
    maxRecursionDepth: 500,      // default 10000
    maxExpressionDepth: 200,     // default 1000
    maxModules: 4,               // default 100
    maxProgramSizeBytes: 512 * 1024,
    moduleHandlers: [std],       // + your vetted app modules; NO std_fs/memory/concurrency
    stdout: (line) => myLogger.log(line),
    stderr: (_) {},              // do not surface raw errors to UI/logs untriaged
  );
  await engine.run();
}
```

### `BallModuleHandler` — the vetted-surface seam (`dart/engine/lib/engine_types.dart:403`)

```dart
abstract class BallModuleHandler {
  bool handles(String module);
  FutureOr<Object?> call(String function, Object? input, BallCallable engine);
  void init(BallEngine engine) {}   // called once at construction, before any statement runs
}
```

- `BallCallable engine` lets a handler call back into other Ball functions (e.g. a `ui.button` handler re-invoking a user `onTap`) without holding a raw `BallEngine`.
- `StdModuleHandler` `handles()` is a fixed switch over exactly the eight `std*` modules — you **cannot** add a new module name through it; that always needs your own handler.
- `StdModuleHandler()` = full built-ins. `StdModuleHandler.subset({fns})` = allow-list (anything else throws at call time). `.register`/`.registerComposer`/`.unregister` tweak individual functions, still confined to `std*` names.

### In-process audit (Dart only)

`package:ball_base/capability_analyzer.dart` exports `analyzeCapabilities`, `analyzeModuleCapabilities`, `checkPolicy`, `formatCapabilityReport`; `.../termination_analyzer.dart` exports `analyzeTermination`. No subprocess needed. This is the one target where a client can audit on-device before constructing an engine.

---

## TypeScript — `@ball-lang/engine` (npm)

```ts
import { BallEngine, StdModuleHandler } from '@ball-lang/engine';

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
}
class BallEngine {
  constructor(program: any, options?: BallEngineOptions);
  run(): Promise<string[]>;   // captures std.print lines when no custom stdout given
  getOutput(): string[];
}
```

```ts
const engine = new BallEngine(programJson, {
  sandbox: true,
  timeoutMs: 2000,
  maxMemoryBytes: 16 * 1024 * 1024,
  maxModules: 4,
  maxExpressionDepth: 200,
  maxRecursionDepth: 500,
});
const lines = await engine.run();
```

**The permissive defaults are the trap** — you MUST pass explicit tight values; do not assume the defaults sandbox anything.

### Gaps to design around (verified, current)

- **No `moduleHandlers` option.** `BallEngineOptions` has no field for it; the constructor hard-codes its handler list. There is no supported public way to register a custom `ui`/`db` module. `StdModuleHandler` IS exported and DOES carry `.register`/`.registerComposer`/`.unregister`/`static subset` (same semantics as Dart, still `std*`-only) — so you can trim/extend the `std` surface cleanly, but a wholly new module name is not supported today. Treat custom-native-module dynamic UI as a Dart-only story until this lands.
- **No in-process audit library.** `@ball-lang/cli`'s package `exports` map exposes only `"."` (the CLI entrypoint, which runs on import). `analyzeCapabilities`/`checkPolicy` are not importable. Audit by spawning `ball audit … --json` as a **subprocess**, or do your own `program.modules[]` allowlist walk in-process.

---

## Rust — `ball-engine` (crates.io)

The **published crate** ships with the `self_host` feature on by default (the publish workflow regenerates `compiled_engine.rs`, flips `default = ["self_host"]`, and includes the generated file), and the publish job gates on full conformance parity. So `cargo add ball-engine` from crates.io gives a working, conformance-verified engine with no Dart toolchain required. (A bare `cargo build` of the *git checkout* has `self_host` off and `run()` returns `SelfHostPending` — that's a dev-repo detail, not the published crate.)

```rust
use ball_engine::BallEngine;

let engine = BallEngine::from_json(&program_json)?;  // or ::from_binary(&bytes)
let lines: Vec<String> = engine.run()?;              // captured stdout
```

```rust
pub enum EngineError { Parse(String), Runtime(String), SelfHostPending(String) }
```

### Gap: trusted programs only

`run(&self)` takes **no arguments** — there is no public `sandbox`, `timeoutMs`, `maxMemoryBytes`, or `moduleHandlers`. Internally it hard-codes one full `StdModuleHandler`, `maxRecursionDepth: 100_000`, unlimited everything else, `sandbox: false`. **Embedding untrusted programs safely via the public crate is not possible yet** — you cannot restrict the std surface, set a timeout, or add a custom module from outside the crate. Use Rust for trusted programs (it matches Dart output); do untrusted-input audit/sandboxing on Dart/TS.

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

So: an app on a non-Dart engine may serve a bare `Program` JSON; an app on the Dart CLI/engine must send the `{"@type": …}` wrapper. Binary transport is solid on Dart (audit/encode) and Rust (engine + CLI), but is not wired into the C++ `run` command or the TS engine constructor. There is no repo-recommended size threshold for choosing JSON vs binary — the only size knob is the engine's opt-in `maxProgramSizeBytes`, orthogonal to wire format. For "dynamic UI," a `Module` (vetted, entry-point-free UI functions) fits when the client drives the loop; a `Program` fits when the server dictates control flow.
