# Announcing Ball 0.2.0 — A Programming Language Where Every Program Is a Protobuf Message

> **We encoded the top 20 Dart pub packages into Ball, compiled them back to Dart, and `dart analyze` passed on 7 of them with zero errors. The other 13 have 75% fewer errors than our first attempt. All 269 modules round-tripped.**

## What Ball is

Ball is a polyglot programming language IR where every program is a Protocol Buffer message. There is no text syntax and no parser — a Ball program is structured data defined by a single `.proto` schema, compiled to Dart / C++ / more, or executed directly by one of three runtime engines (Dart, C++, TypeScript).

Because programs are data, you get capabilities that are awkward or impossible in text-based languages: **provably complete security auditing**, lossless round-trips, zero-ambiguity transport over gRPC, and `git diff`s that operate on the AST instead of whitespace.

Try it in your browser right now: **[ball-lang.dev/playground](https://ball-lang.dev/playground)**.

---

## The hook: real-world round-trips

We took the top 20 Dart packages on pub.dev, encoded each one into Ball (via the Dart analyzer), compiled the Ball back to Dart source, and ran `dart analyze` on the output.

| Packages encoded | Modules round-tripped | `dart analyze` clean | Total errors remaining |
|---|---|---|---|
| **20 / 20** | **269 / 269** | **7 / 20** | **346** (down ~75% from the first attempt) |

That result is the single most honest measure of how far Ball has come in this release. A year ago, round-tripping a single non-trivial Dart file produced hundreds of errors. Today, seven of the most widely used packages in the Dart ecosystem survive the round-trip with zero analyzer complaints.

---

## Why this matters

### Programs are structured data

A Ball program is a `Program` protobuf message. If it deserializes, it's syntactically valid. There is no grammar, no parser, no "unexpected token." Every mutation is an edit on a tree. Every diff is semantic.

### Provably complete security auditing

Because the only way to perform a side effect is to call a named base function, `ball audit` is exhaustive. There is no `eval`, no FFI, no macro system, no `unsafe` escape hatch.

```bash
$ ball audit my_program.ball.json --deny fs,network
FAIL — 3 capabilities denied:
  std_fs.file_write    (main.save_config:14)
  std_fs.file_read     (main.load_config:22)
  std_net.http_get     (main.fetch_updates:31)
```

A GitHub Action ships with the repo that runs `ball audit` on every PR touching `.ball.json` files and blocks merges that introduce unauthorized capabilities.

### Three engines, one semantics

| Engine | State | Notable |
|---|---|---|
| **Dart** | Reference implementation | True non-blocking async — every evaluator is `async`, `await` suspends via native `Future` |
| **C++** | Production prototype | Fast, embeddable, 65 KB linear memory for `std_memory` interop |
| **TypeScript** | [`@ball-lang/engine`](https://www.npmjs.com/package/@ball-lang/engine) | Runs in the browser, OIDC trusted publishing |

**565 tests green across the three engines.**

---

## Show, don't tell

Hello world, as a Ball program:

```json
{
  "name": "hello_world",
  "entryModule": "main",
  "entryFunction": "main",
  "modules": [
    {
      "name": "main",
      "imports": ["std"],
      "functions": [{
        "name": "main",
        "body": {
          "call": {
            "module": "std", "function": "print",
            "input": { "messageCreation": { "typeName": "PrintInput", "fields": [
              { "name": "message", "value": { "literal": { "stringValue": "Hello, World!" } } }
            ]}}
          }
        }
      }]
    }
  ]
}
```

Compiled to Dart:

```dart
void main() {
  print('Hello, World!');
}
```

Compiled to C++:

```cpp
#include <iostream>
int main() {
  std::cout << "Hello, World!" << std::endl;
  return 0;
}
```

Every computation in Ball is exactly one of seven expression node types: `call`, `literal`, `reference`, `fieldAccess`, `messageCreation`, `block`, `lambda`. Control flow (`if`, `for`, `while`) is itself a call to a base function with lazy evaluation — keeping the IR completely uniform.

---

## Quick start

**In the browser** (no install): [ball-lang.dev/playground](https://ball-lang.dev/playground)

**TypeScript / Node**:

```bash
npm install @ball-lang/engine
```

```typescript
import { BallEngine } from '@ball-lang/engine';
import fs from 'node:fs';

const program = JSON.parse(fs.readFileSync('hello_world.ball.json', 'utf-8'));
await new BallEngine().run(program);
```

**Dart CLI**:

```bash
git clone https://github.com/ball-lang/ball && cd ball/dart && dart pub get
dart run ball_cli:ball run ../examples/hello_world/hello_world.ball.json
dart run ball_cli:ball compile ../examples/hello_world/hello_world.ball.json
dart run ball_cli:ball encode my_app.dart
dart run ball_cli:ball audit my_app.ball.json
```

---

## What's new in 0.2.0

### Object-oriented programming, end-to-end

- Classes, methods, constructors, constructor tear-offs
- Inheritance with a `__super__` chain resolved at runtime
- Instance method dispatch via `__type__` with implicit `self` binding
- Type checks (`is` / `as`), enums, operator overloading on class instances
- Null safety: `??=` on fields and indexes, `null_check` error propagation
- Getter / setter dispatch with setter-returns-new-value semantics

Every one of these is mirrored across the Dart engine, C++ engine, and TypeScript engine.

### Package management

`ball add` now resolves dependencies from real registries:

| Source | Example |
|---|---|
| pub.dev | `ball add pub:http@^1.0.0` |
| npm | `ball add npm:lodash@^4.17.0` |
| NuGet, Cargo, PyPI, Maven | `ball add nuget:Newtonsoft.Json@^13` |
| HTTP / Git | `ball add https://example.com/mod.ball.json` |

Resolution produces a `ball.lock.json`; `ball tree` prints the dependency graph.

### True async in the Dart engine

Every expression evaluator is now `async`. `await` suspends execution through Dart's native `Future` mechanism instead of the old `BallFuture` simulation. `sleep_ms` uses `Future.delayed` instead of blocking `dart:io` sleep. Programs that previously wrapped their return values in `BallFuture` still work — the wrapper is kept for backward compatibility.

### Web playground + CI

- **Playground** deployed at [ball-lang.dev/playground](https://ball-lang.dev/playground) — the TypeScript engine runs entirely in-browser.
- **`ball-audit` GitHub Action** runs on every PR that touches `.ball.json`, blocking unauthorized capabilities.
- **OIDC trusted publishing** for `@ball-lang/engine` — no long-lived npm tokens.
- **Melos v7** monorepo setup with pub workspace integration for the Dart packages.

### Key stats for this release

| Metric | Value |
|---|---|
| co19 conformance tests encoded (eligible) | **100%** |
| Engine execution match on co19 | 71.4% with **zero output mismatches** (the rest are skipped / unsupported features) |
| Top 20 pub packages encoded | **20 / 20** |
| Modules round-tripped | **269 / 269** |
| `dart analyze` fully clean | 7 / 20 |
| Remaining errors across the other 13 | 346 (≈75% reduction) |
| Tests passing across Dart + C++ + TS engines | **565** |

---

## What doesn't work yet

Being honest about the gaps:

- **C++ engine `async`/`await` is a synchronous simulation.** `async` wraps a `BallFuture`, `await` unwraps. There is no event loop, no microtask queue, no coroutines. The Dart and TypeScript engines are the real thing; C++ is not.
- **346 `dart analyze` errors remain across 13 of the top-20 packages.** The remaining failures are deep encoder gaps — complex pattern destructuring, some generic bounds, a few cascade corner cases.
- **co19 skip rate is 67%.** Most skips are because co19 tests rely on shared helpers (`Expect`, `StaticTypeHelper`, `DynamicCheck`) that we partially inline; some tests need language features we don't cover yet. Of the tests we do run, output matches byte-for-byte 71.4% of the time with zero output mismatches on the passing set.
- **Dart packages are not yet on pub.dev.** `dart pub get` from a checkout works; `pub add ball_cli` does not. We are preparing for publication in 0.3.
- **Go / Python / Java / C# currently ship proto bindings only.** No compiler, encoder, or engine in those languages yet.
- **Labeled `break`/`continue` in C++ engine is partially implemented.** Simple loops work; labeled flow across nested scopes has bugs.

---

## Architecture, in one paragraph

The single source of truth is [`proto/ball/v1/ball.proto`](https://github.com/ball-lang/ball/blob/main/proto/ball/v1/ball.proto). Everything deserializes from it. Metadata is cosmetic — stripping all metadata never changes what a program computes. Semantic content lives in the expression tree, function signatures, type descriptors, and module structure. The standard library is organized as modules (`std` ≈ 73 functions, `std_collections` ≈ 43, `std_io` ≈ 10, `std_memory` ≈ 30 for C/C++ interop, `dart_std` ≈ 18 for Dart-specific constructs). Base functions have no body — their implementation is supplied per-platform by the target compiler or engine. This is the single extensibility mechanism, and it is how a Flutter / Unity / embedded backend would plug in.

---

## Links

- **Repo:** [github.com/ball-lang/ball](https://github.com/ball-lang/ball)
- **Website:** [ball-lang.dev](https://ball-lang.dev)
- **Playground:** [ball-lang.dev/playground](https://ball-lang.dev/playground)
- **npm:** [@ball-lang/engine](https://www.npmjs.com/package/@ball-lang/engine)
- **Proto schema on Buf:** [buf.build/ball-lang/ball](https://buf.build/ball-lang/ball)
- **Roadmap:** [`docs/ROADMAP.md`](./ROADMAP.md)
- **Std library coverage:** [`docs/STD_COMPLETENESS.md`](./STD_COMPLETENESS.md)
- **Implementing a new compiler:** [`docs/IMPLEMENTING_A_COMPILER.md`](./IMPLEMENTING_A_COMPILER.md)

License: MIT.

---

## Thanks

To everyone who filed encoder bugs while staring at unreadable Ball JSON diffs, to the Dart analyzer team for a library good enough to power a whole encoder, to Buf for schema tooling that made seven-language bindings trivial, and to the folks who asked "but why would you do this?" often enough to sharpen every answer in this post.

---

## Twitter / X thread (short version)

> 1/5
> Announcing Ball 0.2.0 — a programming language where every program is a Protocol Buffer message.
>
> No parser. No syntax errors. `ball audit` tells you every filesystem / network call, provably. 3 engines: Dart, C++, TypeScript (runs in the browser).
>
> https://ball-lang.dev/playground

> 2/5
> The hook: we encoded the top 20 Dart pub packages, compiled them back to Dart, and `dart analyze` passed on 7/20 with zero errors. 269/269 modules round-tripped. Remaining 13 packages have ~75% fewer errors than our first attempt.
>
> Real code, not toys.

> 3/5
> New in 0.2.0:
> - Full OOP: classes, inheritance, operator overloading, null safety
> - True async Dart engine (native `Future` suspension, not simulation)
> - `ball add pub:pkg` / `npm:pkg` / `nuget:pkg` / `cargo:pkg` / `pypi:pkg` / `maven:pkg`
> - Web playground
> - `ball audit` GitHub Action

> 4/5
> Honest about gaps:
> - C++ engine async is still synchronous simulation
> - 346 analyze errors across 13 packages — deep encoder gaps
> - co19: 100% encode, 71.4% engine match w/ zero output mismatches, 67% skip rate
> - Dart packages not on pub.dev yet (0.3)

> 5/5
> `npm install @ball-lang/engine` or play at https://ball-lang.dev/playground
>
> 565 tests green across 3 engines. MIT. Proto schema on buf.build/ball-lang/ball.
>
> Feedback, issues, and "why would you do this?" all welcome.
