<!-- Parent: ../AGENTS.md -->

# C++ Implementation Agents

When working in the C++ codebase. The C++ implementation is a **prototype** — Dart is the reference. C++ runs the **self-hosted** engine (`dart/self_host/lib/engine_rt.cpp`, generated from the Dart engine); there is no native C++ engine.

## Critical Context

- The C++ build produces the compiler (`ball_cpp_compile`) and encoder (`ball_cpp_encode`); the engine is the self-hosted `dart/self_host/lib/engine_rt.cpp`
- Tests exist across compiler, encoder, and self-host conformance (see `cpp/test/`)
- Several features are STUBBED or have silent-correctness gaps — tracked in `docs/SELF_HOST_STATUS.md`
- This is prototype-quality code, not production-ready

## Build & Test

Commands: see CLAUDE.md → Build & Test (canonical) and `.claude/rules/cpp.md` for the self-host build/regeneration flow.

**Prefer conformance tests over unit tests.** The conformance suite validates against shared `.ball.json` fixtures — the same programs tested across the Dart, C++ (self-hosted), and TS engines. Unit tests should be minimal.

```bash
cd cpp/build && cmake .. && cmake --build . && ctest --output-on-failure
# Self-host conformance (highest value — validates the self-hosted engine
# against shared fixtures). Use per-fixture isolated runs for a reliable count:
BALL_TEST_FILTER="01_hello_world" ./test/Debug/test_selfhost_conformance.exe
# Compiler / encoder unit tests (use sparingly):
ctest -R compiler_tests
ctest -R encoder_tests
```
- Test files: `cpp/test/test_*.cpp` — each compiles as standalone executable
- Conformance fixtures live in `tests/conformance/*.ball.json`
- Stack sizes: compiler 128MB, encoder 256MB, engine memory 65KB
- Snapshot tests rewrite baselines with `BALL_UPDATE_SNAPSHOTS=1`

## Buf CLI Integration

- `cpp/cmake/BufGenerate.cmake` — CMake module for buf CLI operations
- When buf is available, CMake regenerates C++ protos from ball.proto on change
- #18 Stage 5: the C++ build is libprotobuf-free — no `cpp/shared/gen/`, no protobuf FetchContent, no `google.protobuf` in any TU
- Extra targets: `buf_lint`, `buf_breaking`, `buf_format`, `buf_check`

## Known Broken/Stubbed Features

The authoritative, kept-current list of C++/self-host gaps and pass counts lives in
`docs/SELF_HOST_STATUS.md`; the strict all-green CI gates are in `.github/workflows/regression-gates.yml`.
The compiler/encoder/runtime-emit citations below are stable references into the C++
toolchain (the engine itself is the self-hosted `engine_rt.cpp`, not native C++).

**Compiler (`cpp/compiler/src/compiler.cpp`) — silent-correctness gaps:**
- `for`/`while` in expression context whose body contains `return` or a labeled
  break/continue → stubbed (`// for loop`), dropping the loop. Break/continue-only
  and jump-free bodies emit real loops (~1438). Not currently hit by the
  self-hosted engine, but a latent limitation for arbitrary programs.
- Bytes literals → empty `std::vector<uint8_t>{}` (~437).
- Unknown base functions → emit `/* std.fn */ 0` or a comment (wrong value, no
  error) (module dispatchers ~2018+).
- `string_split`/`string_replace`/`string_replace_all` ARE implemented (~1624/1639/1647).
- `std_concurrency` is NO LONGER in this list (#606/#607). `compile_concurrency_call`
  emitted declaration STATEMENTS where a value was expected (`std::thread
  _thread(<body>)`, `std::mutex _mtx`), so the declared `-> int` of
  `thread_spawn`/`mutex_create` could not be honoured, and it implemented three
  functions no builder declares (`thread_detach`, `unique_lock`,
  `atomic_fetch_add`). Every declared function now lowers to a `_ball_<op>(...)`
  helper over the single-threaded handle tables spliced into the preamble, with
  the same semantics as the Dart reference engine; the three undeclared ones are
  deleted, and `cpp/test/check_declared_base_functions.py` (ci.yml's always-on
  `proto` job) keeps this dispatch and the canonical builders in sync.
  `tests/conformance/476_std_concurrency_handles` is the cross-target guard.

**Runtime stubs (compile, produce wrong/fake results):**
- `jsonEncode`/`toProto3Json` are not real JSON (`ball_emit_runtime.h`).
- Filesystem ops (`existsSync`, dir list/create/exists, `writeAsBytesSync`,
  append-mode `writeAsStringSync`) now do real `std::filesystem`/`std::ofstream`
  work (issues #307/#308/#310) — no longer no-ops.
- `await`/`yield`/`yield_each` are synchronous pass-throughs (no event loop).
- Generic proto `hasXxx`→false, `whichXxx`→"notSet" fallbacks.

**Encoder (`cpp/encoder/src/encoder.cpp`):**
- Silently drops unhandled AST nodes (~880, depth-limit ~781).

**Conformance harness:**
- `cpp/test/test_selfhost_conformance.cpp` returns a real exit code
  (`return tests_failed > 0 ? 1 : 0;`) and has NO skip-list — every conformance
  fixture must pass, so self-host failures DO fail the target. CTest isolates
  each fixture in its own process (a crash/hang fails only that fixture).

## Architecture Notes

- `BallValue` = `std::any` for runtime polymorphism
- Maps use `std::map` (ordered), NOT `std::unordered_map`
- Encoder uses Clang JSON AST (via `clang -Xclang -ast-dump=json`)
- Encoder inlines C++ pointer ops to universal std/std_memory during encoding (no separate normalizer)
- Compiler stack size: 128MB, Encoder: 256MB, Engine memory: 65KB
- Memory.hpp: typed linear buffer for C/C++ interop
- Ball files (`.ball.json`/`.ball.bin`) are self-describing `google.protobuf.Any` envelopes, but the loader is now libprotobuf-free (JSON via `ball::ir`/nlohmann; binary via Ball's own `ball_rt_decode.cpp`). Ball files are self-describing `google.protobuf.Any`
  envelopes (JSON form carries an `@type` key). Read them via
  `cpp/shared/include/ball_file.h` (`ball::LoadProgram(path)` / `LoadModule(path)`
  / `DecodeProgram(path, content)`), which mirrors `dart/shared/lib/ball_file.dart`.
  NEVER parse a ball file directly into a `Program`/`Module` — the envelope's
  type URL discriminates Program vs Module. Exception: `dart/self_host/engine.ball.pb`
  is a raw (non-Any) `Program` pipeline artifact, read directly by the self-host build.

### Dart's `StateError`: typed AND readable (issue #616)

#597/#604 settled that `std_collections.list_find`'s no-match THROWS and that the throw is
typed. Neither settled what the program then OBSERVES — conformance fixture
`463_list_find_no_match` prints a hardcoded literal from its catch bodies — and every target
answered differently. Measured on `origin/main` before the fix, one program printing
`to_string(e)` from its catch: the Dart reference engine `Bad state: No element` (which is also
real Dart's `StateError('No element').toString()`), the TS self-hosted engine
`{message: No element}`, the Go self-hosted engine `main:StateError`.

The contract now has two halves at EVERY site that raises Dart's `StateError` — an empty
`.first`/`.last`/`.single`/`removeLast`/`reduce`, or a `firstWhere` with no match:

1. **TYPED** — the thrown value carries the type name `StateError`, so a program's own
   `on StateError catch` matches it. Several sites used to raise an untyped native fault that
   the compiled `try` could not see at all.
2. **OBSERVABLE** — it stringifies as Dart's own `StateError.toString()`, `Bad state: <message>`,
   so `to_string(e)` in the catch body reads the same here as on the Dart reference engine.

`tests/conformance/465_state_error_message` is the cross-target guard (it prints the caught
value for `list_find`'s no match AND `list_first` on an empty list — never a hardcoded string).
Per-target details are in `.claude/rules/<lang>.md`; the gap class is
`docs/TESTING_STRATEGY.md` §5b.

### Rendering a CAUGHT exception (issue #640)

`catch (e) { print('caught: $e'); }` lowers to `ball_to_string(e)`, and the catch variable is
bound two different ways by the `try` lowering in `cpp/compiler/src/compiler.cpp`:

| `try` shape | binding | renderer |
|---|---|---|
| at least one TYPED clause | `const BallException& e = __ball_e;` | `ball_to_string(const BallException&)` |
| all clauses untyped | `auto e = _ball_caught_to_dyn(__ball_e);` | `BallDyn::operator std::string()` over the reified map |

Both must print Dart's `toString()`, and they must agree. The single renderer is
`_ball_dart_error_to_string(type_name, message)` in `cpp/shared/include/ball_emit_runtime.h`
— #616's closed table, matching `dartErrorToString` (`go/runtime/ops.go`),
`DartErrorToString` (`csharp/shared/src/BallValue.cs`), `dart_error_to_string`
(`rust/shared/src/value.rs`), `__ball_err_prefix` (`ts/compiler/src/preamble.ts`) and
`_dartErrorPrefix` (`dart/engine/lib/engine_std.dart`) row for row: `StateError` →
`Bad state`, `FormatException` → `FormatException`, `RangeError` → `RangeError`,
`ArgumentError` → `Invalid argument(s)` (#658 — neither its own name nor empty), and
**nothing else**, so a user class that happens to declare a `message` field is never
re-rendered. Same rows, same module-prefix stripping.

`TypeError` is the one row this table deliberately omits, and it is an omission rather than a
gap: C++ raises `TypeError` through the 2-argument, no-`fields` ctor (`ball_cast_assert`,
`cpp/compiler/src/compiler.cpp`), so the THROWER already carries the canonical string and the
`message` lookup correctly misses. `tools/check_error_rendering_tables.py` models exactly that
(`coverage_exempt`), and it holds every row this table DOES carry to the same agreement check as
every sibling's — an exemption from coverage is not an exemption from being right.

The two throw shapes carry the string in different places, and the renderer keys on that
difference rather than on the type name:

- a LITERAL throw (`throw StateError('boom')`) lowers to
  `BallException("StateError", "StateError", {{"message", "boom"}})` — the ctor argument is a
  `fields` entry and `what()` is the bare TYPE NAME. Rendering `what()` printed `StateError`
  where Dart prints `Bad state: boom`;
- a RUNTIME-raised one (`_ball_make_exception`) already carries its canonical `toString()`
  string as the payload and has no fields, so prefixing it again would read
  `Bad state: Bad state: No element`.

`_ball_exception_to_dyn` follows the same split: `value` (what `print(e)`/`'$e'` reads) is the
rendered string, `message` is the ctor ARGUMENT — the same thing the typed binding's
`e.fields.at("message")` gives a catch body, and what conformance 146/464 read.

Guards: `cpp/test/test_ball_dyn.cpp`'s `caught_builtin_dart_error_renders_dart_to_string` and
`…_reified_as_dyn_renders_dart_to_string` pin both bindings (and, by existing at all, pin the
overload itself — without it the generic `ball_to_string(T)` template instantiates
`std::to_string(BallException&)`, which does not compile, so the program is a BUILD error
rather than a wrong answer). `464_typed_catch_clause_dispatch`'s untyped fallback arm
interpolates its exception, which is the corpus's only arm that puts a typed-dispatch catch
variable in a value position, so the C++ Compiled matrix row compiles that shape on every PR.

A USER-thrown built-in error printed in a value position is portable since #658, and
`473_caught_user_thrown_builtin_error` is the fixture that proves it — the one this note used to
say could not exist, because the Dart reference engine printed the bare ctor argument (`boom`)
where Dart prints `Bad state: boom`. It prints a caught `StateError`/`FormatException`/
`ArgumentError` through an untyped catch, a typed `on T catch`, and a non-matching typed clause
that falls through, and reads `.message` alongside `'$e'`: the two are DIFFERENT strings, and a
"fix" that stored the prefixed form would pass one half and break the other. C++ needed only the
`ArgumentError` row — #640's `arg0` → `message` rename in the throw lowering had already put this
target ahead of every sibling.
