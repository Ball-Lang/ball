# Upstream protobuf conformance (Editions)

This directory wires **ball_protobuf** into the official protobuf
[conformance suite](https://github.com/protocolbuffers/protobuf/tree/main/conformance),
so our descriptor-driven, Editions-feature-aware codecs are validated against
the same test vectors the reference implementations use.

## How it works

```
                                      stdin  (ConformanceRequest, size-prefixed)
  conformance_test_runner  ───────────────────────────────▶  ball_conformance
  (protobuf, C++, POSIX)   ◀───────────────────────────────  (tool/conformance_main.dart)
                                      stdout (ConformanceResponse, size-prefixed)
```

1. **`tool/conformance_main.dart`** builds a descriptor *registry* from a
   checked-in `FileDescriptorSet` (`tests/editions/descriptors/test_messages.fds.binpb`)
   via **`tool/descriptor_bridge.dart`**. The bridge resolves every field's
   Editions `FeatureSet` (field presence, message/enum encoding, UTF-8
   validation, …) using the same resolver the rest of `ball_protobuf` uses, and
   folds in `extend` blocks (extensions are wire-indistinguishable from regular
   fields, so they are appended to their extendee under a `[fully.qualified]`
   key).
2. The shared loop in **`lib/conformance.dart`** reads each size-prefixed
   `ConformanceRequest`, looks the message type up in the registry, runs it
   through `unmarshal`/`marshal` (or the JSON codec), and writes back a
   `ConformanceResponse`. Unknown message types return `skipped`.
3. The runner compares our output against the reference and reports
   pass/skip/fail. `failure_list_ball.txt` lists the tests we expect to fail.

## Scope

Registered: the `TestAllTypes*` messages of all three conformance families —
`protobuf_test_messages.{proto2,proto3,editions}` (plus nested types and
extensions). Text-format tests and other message types are reported `skipped`.

As of the proto2/proto3 expansion: **2513 tests pass, 194 are expected failures**
(listed in `failure_list_ball.txt`). The expected failures are tracked
follow-ups — chiefly Well-Known-Type JSON mapping (Any, Struct/Value, Timestamp,
Duration, wrappers, FieldMask), oneof membership tracking, recursive message
merge, unknown-field retention, and a few remaining parse/serialize strictness
checks. The header of `failure_list_ball.txt` documents the categories.

## Running locally

The runner is POSIX-only (`fork`/pipes), so build and run it on Linux/macOS
(or WSL). From the repo root:

```bash
# 1. Build the runner once (FetchContent pulls protobuf + abseil).
cmake -S cpp -B cpp/build-conformance -Dprotobuf_BUILD_CONFORMANCE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build-conformance --target conformance_test_runner -j

# 2. Compile our conformance program to a native exe.
cd dart && dart pub get && cd ..
dart compile exe dart/ball_protobuf/tool/conformance_main.dart -o ball_conformance

# 3. Run. The program walks up from the CWD to find the FileDescriptorSet, so
#    invoke it from the repo root (the runner takes the program as its final
#    positional arg — no `--` separator on current builds).
runner=$(find cpp/build-conformance -name conformance_test_runner -type f | head -1)
"$runner" --maximum_edition 2023 \
  --failure_list dart/ball_protobuf/conformance/failure_list_ball.txt \
  ./ball_conformance
```

CI runs exactly this on Ubuntu (job **Upstream Conformance (Editions)** in
`.github/workflows/ci.yml`).

## Regenerating the descriptor set

`tests/editions/descriptors/test_messages.fds.binpb` is produced by `protoc`
(pinned to a version that supports edition 2023) from the protobuf source the
C++ build fetches. Regenerate with `tools/gen_conformance_descriptors.sh`
(or `.ps1` on Windows); pass `--check`/`-Check` to drift-check.
