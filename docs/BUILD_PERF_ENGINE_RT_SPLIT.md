# engine_rt multi-TU + Ninja (build perf #5)

## Feasibility (confirmed)

- **ball_cpp_compile** previously emitted one string → one `.cpp`. It now supports
  `--split <dir> [--shards N]` with out-of-line method bodies in namespace `ball_rt`.
- **compile_engine_cpp.dart** defaults to multi-TU (`dart/self_host/lib/engine_rt/`).
  Pass `--monolithic` for the legacy single `engine_rt.cpp`.
- **Ninja**: use CMake preset `ninja-release` (`cpp/CMakePresets.json`) or
  `cmake --preset ninja-release` then `cmake --build --preset ninja-release`.

## Layout

| File | Role |
|------|------|
| `engine_rt_common.hpp` | Includes, runtime embed, type/method declarations |
| `engine_rt_shard_XX.cpp` | Out-of-line definitions (round-robin by emit order) |
| `engine_rt_link.hpp` | `using` aliases for tests (`BallEngine`, `BallDyn`, …) |

## CMake

- `cpp/cmake/BallSelfhostEngine.cmake` — `ball_add_selfhost_engine_target()`
- `test_selfhost_conformance` links `$<TARGET_OBJECTS:ball_selfhost_engine>` when present.

## Recompile speedup

MSVC `/MP` parallelizes **translation units**, not lines within one TU. With ~8 shards
of ~800–1200 lines each (vs ~10k monolithic), incremental rebuild after a small
engine change should touch **one shard** → near-linear speedup vs full monolithic compile.

Measure locally:

```powershell
# Monolithic (baseline)
Measure-Command { cmake --build cpp/build3 --target test_selfhost_conformance --config Release }

# After touch one shard
# (edit dart/engine, regen, rebuild)
```

## Blockers / follow-ups

- Full link of latest `engine.ball.pb` regen currently fails on MSVC with
  `std::any_cast<BallOrderedMap&>` in embedded `ball_dyn` (same failure for monolithic
  and multi-TU until that codegen/runtime issue is fixed).
- Very large **header** (`engine_rt_common.hpp`) is still parsed by every shard;
  further win: move BallDyn/runtime to a precompiled preamble object or split
  common.hpp into runtime vs declarations.
- `compile_module()` remains single-file; only full-program `compile_split` is wired.
