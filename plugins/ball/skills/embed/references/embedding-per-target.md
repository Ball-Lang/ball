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
import 'dart:typed_data';
import 'package:ball_base/ball_base.dart' show decodeBallFileJson, BallProgramFile;
import 'package:ball_base/capability_analyzer.dart';
import 'package:ball_base/termination_analyzer.dart';
import 'package:ball_engine/engine.dart';
// e.g. package:cryptography or package:pinenacl for the signature primitive.

// Take the RAW received bytes, not a pre-decoded String. `signature` is a
// detached signature over EXACTLY those bytes.
Future<Object?> runUntrusted(Uint8List rawBytes, Uint8List signature) async {
  // 0. AUTHENTICITY FIRST — verify the signature over the EXACT raw bytes,
  //    before any decode/audit/execute. Ball never authenticates payloads;
  //    sandboxing bounds what a program DOES, not whether it is the one your
  //    server sent (a compromised CDN/cache or a replayed, revoked version is
  //    still structurally valid + audited + sandboxed). `trustedPublicKey` is
  //    pinned in the app; verify the same bytes you will decode below.
  if (!verifyEd25519(rawBytes, signature, trustedPublicKey)) {
    throw StateError('signature verification failed — rejecting payload');
  }

  // 1. Size-gate the RAW bytes BEFORE decoding. (String.length counts UTF-16
  //    code units — a CJK payload is ~3x its char count in real bytes and would
  //    slip a String-length check after the expensive UTF-8 decode already ran.)
  if (rawBytes.length > 512 * 1024) throw StateError('program too large');

  // 2. Decode ONCE. Audit and run THIS object (no re-decode → no TOCTOU).
  final file = decodeBallFileJson(jsonDecode(utf8.decode(rawBytes)));
  if (file is! BallProgramFile) throw StateError('expected a Program');
  final program = file.program;

  // 3. Audit — provably-complete over KNOWN base functions only.
  //    reachableOnly:false → audit EVERY function, including unreached branches
  //    (strict pre-filter; audit-and-policy.md explains the trade-off).
  //    {fs,process,memory,concurrency} is the security-critical core. For a
  //    PURE computation (a rules engine returning a decision, no console output)
  //    widen to {fs,process,memory,concurrency,io,time,random} — the canonical
  //    pure-decision deny-set; permit `io` back only if the program legitimately
  //    prints, `time`/`random` only if it genuinely needs a clock/RNG.
  final report = analyzeCapabilities(program, reachableOnly: false);
  final violations = checkPolicy(report, deny: {'fs', 'process', 'memory', 'concurrency'});
  if (violations.isNotEmpty) throw StateError('policy violation: ${violations.join(', ')}');
  final term = analyzeTermination(program);
  if (term.hasErrors) throw StateError('termination risk');

  // 3b. The audit still can't see custom/unknown isBase-module DECLARATIONS or
  //     module_imports (the #402 fix only closes call-site module *spoofing* of
  //     real base fns). Enforce your own allowlist + reject imports here
  //     (runnable, not a comment).
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

  // 4. Execute locked down. Wrap the CONSTRUCTOR too — maxProgramSizeBytes/maxModules
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

### Rules engine: verify → audit → structured decision (one combined flow)

`runUntrusted` above ends in `run()` (entry-function return / injected stdout). A rules engine wants a *structured decision from a named function*, so use `callFunction` instead of `run()` — same gate, different last line. This is the end-to-end shape the "server sends dynamic instructions" scenario needs; do not stop at the `run()` snippet and improvise.

```dart
/// Returns the business decision, or throws if the payload is rejected.
/// `context` is the structured input, e.g. {'cartTotal': 142.50, 'tier': 'gold'}.
Future<Map<String, Object?>> evaluateRule(
  Uint8List rawBytes,
  Uint8List signature,
  Map<String, Object?> context,
) async {
  // Steps 0–3 are IDENTICAL to runUntrusted: verify signature over the exact
  // bytes → size-gate → decode ONCE → audit. Use the PURE-decision deny-set,
  // since a rules engine should be deterministic (no io/time/random):
  if (!verifyEd25519(rawBytes, signature, trustedPublicKey)) {
    throw StateError('signature verification failed');
  }
  if (rawBytes.length > 512 * 1024) throw StateError('program too large');
  final file = decodeBallFileJson(jsonDecode(utf8.decode(rawBytes)));
  if (file is! BallProgramFile) throw StateError('expected a Program');
  final program = file.program;

  final report = analyzeCapabilities(program, reachableOnly: false);
  final violations = checkPolicy(
    report,
    deny: {'fs', 'process', 'memory', 'concurrency', 'io', 'time', 'random'},
  );
  if (violations.isNotEmpty) throw StateError('policy violation: $violations');
  if (analyzeTermination(program).hasErrors) throw StateError('termination risk');
  // ... + the same module_imports reject + isBase-allowlist walk as runUntrusted ...

  try {
    final std = StdModuleHandler.subset({'greater_than', 'and', 'equals', 'if'});
    final engine = BallEngine(
      program,
      sandbox: true,
      timeoutMs: 1000,
      maxMemoryBytes: 8 * 1024 * 1024,
      maxRecursionDepth: 100,
      maxExpressionDepth: 100,
      maxModules: 2,
      maxProgramSizeBytes: 512 * 1024,
      moduleHandlers: [std],       // ONLY the pure std subset the rule needs
      stdout: (_) {},              // a pure rule has no reason to print
      stderr: (_) {},
    );
    // callFunction(module, function, input) → the structured decision channel.
    // A fresh engine per evaluation — never reuse one across requests.
    final decision =
        await engine.callFunction('rules', 'evaluate', context);
    return (decision as Map).cast<String, Object?>();  // e.g. {'discount': 0.1}
  } on BallRuntimeError catch (e) {
    throw StateError('engine rejected program: $e');
  }
}
```

The `rules` module here holds ordinary (non-`isBase`) interpreted functions, so it does **not** go in your isBase-allowlist (that walk gates only `isBase` declarations). Do not add it there "defensively" — that only tempts a later, unnecessary native handler under the same name.

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

### Authoring the content: producing `ui.text(...)` calls (server side)

The receive/audit/execute half above assumes a program that already contains calls into your `ui` module. Two things a first reader gets stuck on: the `ui` module must be **declared** in the program (so your isBase-allowlist walk can see it), and the calls into it must be **produced somehow**. The **source encoders (`ball_encoder` / `@ball-lang/encoder`) can't do this** — they route every construct through universal `std`/`std_collections` and have no convention that emits a call to a custom `ui` module. So author custom-module programs with the **proto builders**, not the source encoder.

```dart
// SERVER side. Build the Program with package:ball_base proto types.
import 'package:ball_base/ball_base.dart';   // Program, Module, FunctionDefinition,
                                              // Expression, FunctionCall, Literal, etc.

Expression _str(String s) => Expression(literal: Literal(stringValue: s));
Expression _uiCall(String fn, List<FieldValuePair> args) => Expression(
      call: FunctionCall(
        module: 'ui',
        function: fn,
        input: Expression(messageCreation: MessageCreation(fields: args)),
      ),
    );

final program = Program(
  name: 'home_screen',
  entryModule: 'app',
  entryFunction: 'render',
  modules: [
    // The vetted `ui` module: isBase stubs, NO body — your allowlist walk keys
    // off exactly these declarations, and your UiModuleHandler implements them.
    Module(name: 'ui', functions: [
      FunctionDefinition(name: 'text', isBase: true),
      FunctionDefinition(name: 'button', isBase: true),
      FunctionDefinition(name: 'column', isBase: true),
    ]),
    // The interpreted content: a `render` body that calls into `ui`.
    Module(name: 'app', functions: [
      FunctionDefinition(
        name: 'render',
        body: _uiCall('column', [
          FieldValuePair(
            name: 'children',
            value: Expression(literal: Literal(listValue: ListLiteral(elements: [
              _uiCall('text', [FieldValuePair(name: 'value', value: _str('Hello'))]),
              _uiCall('button', [
                FieldValuePair(name: 'label', value: _str('Tap me')),
                // Event handler = a {module, function} NAME PAIR, not a closure.
                FieldValuePair(
                  name: 'onTap',
                  value: Expression(messageCreation: MessageCreation(fields: [
                    FieldValuePair(name: 'module', value: _str('app')),
                    FieldValuePair(name: 'function', value: _str('onTap')),
                  ])),
                ),
              ]),
            ]))),
          ),
        ]),
      ),
      FunctionDefinition(name: 'onTap', body: _str('tapped')),
    ]),
  ],
);
// Serialize for transport: program.writeToBuffer() (.ball.bin) or
// program.toProto3Json() (.ball.json). In TS, build the same shape with
// create(ProgramSchema, {...}) / fromJson from @ball-lang/shared.
```

The wire shape (proto3-JSON) of a single call is exactly what the audit walks — `{"call": {"module": "ui", "function": "text", "input": {"messageCreation": {"fields": [{"name": "value", "value": {"literal": {"stringValue": "Hello"}}}]}}}}`. On the client, your isBase-allowlist walk permits `{'std', 'ui'}`, the audit reports `ui.*` calls as pure (a custom module — hence the walk is mandatory), and `UiModuleHandler` renders them. Keep that handler **rendering-only** (no `ui.open_url`/`ui.http_get`) and treat every string it receives as **untrusted** (escape it; native widget, never a WebView) — the audit can never see inside a custom module, so its safety is entirely your handler's discipline.

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

### Bound host-side dispatch for long-lived UI loops

`timeoutMs`/`maxRecursionDepth`/`maxMemoryBytes` bound **one** `run()`/`callFunction()`. For a dynamic-UI screen the host calls `callFunction` on every tap/re-render, and nothing in the engine bounds *that* cadence — a handler that always signals "re-render" livelocks your app while each individual call finishes well under `timeoutMs`. Add a host-level budget:

```dart
int _rerendersThisSecond = 0;
DateTime _windowStart = DateTime.now();

Future<void> dispatch(BallEngine engine, String module, String function, Object? input) async {
  final now = DateTime.now();
  if (now.difference(_windowStart) > const Duration(seconds: 1)) {
    _windowStart = now;
    _rerendersThisSecond = 0;
  }
  if (++_rerendersThisSecond > 30) return;   // drop, don't crash
  await engine.callFunction(module, function, input);
}
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

Because TS has **no** run-time std allowlist and **no** in-process capability library, your gate is: verify signature → size-check → parse → subprocess `ball audit` **on the same bytes** + your own module-allowlist walk + reject imports → construct (in try/catch) → run.

```ts
import { BallEngine } from '@ball-lang/engine';
import { writeFileSync, unlinkSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

// Windows-safe: invoke the real JS entry via `node`. Do NOT spawn the
// extensionless node_modules/.bin/ball shim — it throws ENOENT under
// child_process without shell:true on Windows. This is also the only stable
// programmatic entry (the exports map is "."-only).
const BALL_ENTRY = require.resolve('@ball-lang/cli/dist/index.js');

async function runUntrusted(rawBytes: Uint8Array, signature: Uint8Array): Promise<string[]> {
  // 0. AUTHENTICITY FIRST — verify the signature over the EXACT raw bytes.
  if (!verifyEd25519(rawBytes, signature, TRUSTED_PUBLIC_KEY)) {
    throw new Error('signature verification failed');
  }

  // 1. Size-gate the RAW bytes before decoding.
  if (rawBytes.byteLength > 512 * 1024) throw new Error('program too large');

  // 2. Decode once; audit and run THIS object.
  const text = new TextDecoder().decode(rawBytes);
  const parsed = JSON.parse(text);
  const program = parsed?.['@type'] ? stripAtType(parsed) : parsed;   // unwrap Any envelope if present

  // 3a. Subprocess audit on the SAME bytes (TOCTOU-safe): write once, audit that
  //     file. The self-hosted CLI (#362) categorizes call-level module spoofing
  //     of base fns since #402, so `--deny concurrency` now catches a spoofed
  //     {module:"harmless", function:"mutex_create"}. TS `--deny` returns exit 1
  //     directly (no --exit-code flag); execFileSync throws on a non-zero exit.
  const tmp = `./tmp_audit_${randomUUID()}.ball.json`;
  writeFileSync(tmp, rawBytes);
  try {
    execFileSync(process.execPath,
      [BALL_ENTRY, 'audit', tmp, '--deny', 'fs,process,memory,concurrency'],
      { stdio: 'pipe' });
  } finally {
    unlinkSync(tmp);
  }

  // 3b. Own allowlist walk (still needed — audit is blind to custom isBase-module
  //     DECLARATIONS and to module_imports). Proto field names are camelCased.
  const allowed = new Set(['std', 'std_collections', 'std_convert', 'ui']);
  for (const m of program.modules ?? []) {
    if ((m.moduleImports ?? []).length > 0) throw new Error(`module "${m.name}" declares imports`);
    for (const f of m.functions ?? []) {
      if (f.isBase && !allowed.has(m.name)) throw new Error(`isBase ${m.name}.${f.name} not allowlisted`);
    }
  }

  // 4. Construct in try/catch (maxProgramSizeBytes/maxModules throw from the CTOR,
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

- **No run-time std restriction, and no custom modules.** `new BallEngine(...)` always constructs a fresh, full `StdModuleHandler` internally (`ts/engine/src/index.ts:83`) and passes a hard-coded handler list (`[methodHandler, stdHandler]`, `:114`). `BallEngineOptions` has no `moduleHandlers` field and there is **no injection point** — a `StdModuleHandler.subset({...})` you construct is *never wired in*, so it does nothing (verified: `std_concurrency.mutex_create` runs fine under `sandbox:true` with an ignored `subset({'print'})` sitting next to it). Consequence: on TS every implemented `std_*` function stays reachable at run time; `sandbox:true` still blocks `std_fs.*` + `std_io.exit`/`panic`/`env_get`, but nothing trims `std_concurrency` or the rest. **Your audit is the only thing keeping those out — it is not optional.** As of #402 the audit *is* a real call-site capability gate (it denies a base call even under a spoofed `call.module`), so a passing `--deny concurrency` audit is now meaningful on TS — but because the run-time surface stays full, keep the audit mandatory and minimal-input, and treat custom-native-module dynamic UI (`ui.render`) as a Dart-only story until run-time registration lands.
- **The audit is now self-hosted, but there is still no importable in-process library.** Since #362/#398 the TS `audit` command compiles from the same `cli_core.dart` into `compiled_cli.ts` (the old hand-ported `capability_analyzer.ts`/`capability_table.ts` are gone), so it inherits the #402 spoofing fix and runs termination analysis in its default text report — byte-identical to the Dart CLI's default. But `@ball-lang/cli`'s package `exports` map is still `"."`-only, so you **cannot** `import` its analyzer from your app (it fails `ERR_PACKAGE_PATH_NOT_EXPORTED`). Audit by (a) your own `program.modules[]` walk above, and/or (b) spawning the CLI as a subprocess.
- **Subprocess audit is file-based; invoke it via `node`, not the `.bin/ball` shim.** `ball audit` has **no stdin mode** (`ball audit -` / `/dev/stdin` both fail "File not found"), so you must pass a file. After `npm install @ball-lang/cli` the binary is `node_modules/.bin/ball` — an **extensionless POSIX shim that throws `ENOENT`** under `child_process` (`execFileSync`/`spawnSync`) without `shell: true` on Windows. The portable, verified invocation is `execFileSync(process.execPath, [require.resolve('@ball-lang/cli/dist/index.js'), 'audit', file, '--deny', …])` (see the snippet above); `npx ball audit <file>` works only from a real shell, not the `execFileSync` shape a server uses. Flags: `--deny <csv>` (returns exit 1 on violation — there is **no** `--exit-code` flag), `--reachable-only`, `--output <path>`, `--json`. **To preserve "audit the exact bytes you execute" (TOCTOU):** write the received bytes to one temp file, audit *that* file, and load *that same file* into the engine — never audit a serialization you re-derive.

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
