# ball_protobuf_gen

Consumer-model code-generator support for the [`ball_protobuf`](../ball_protobuf)
runtime. This package owns:

- the **descriptor bridge** (`lib/src/descriptor_bridge.dart`) — turns a
  protoc-emitted `FileDescriptorSet` into the resolved, Editions-aware `Map`
  field descriptors that `ball_protobuf`'s codecs consume;
- the **generator** (`lib/src/{gen_model,dart_emitter,generator}.dart`) — a
  target-independent front end (`GenModelBuilder`) plus a Dart emitter that
  produces `.pb.dart` models; and
- **`protoc-gen-ball`** (`bin/protoc_gen_ball.dart`) — the protoc/buf plugin
  that reads a `CodeGeneratorRequest` from stdin and writes a
  `CodeGeneratorResponse` to stdout.

It legitimately depends on both `ball_base` (the generated `descriptor.pb.dart`
types) and `ball_protobuf` (the runtime + editions resolver), so — unlike the
`ball_protobuf` runtime `lib/` — it is **not** Ball-portable.

> Status: Phase 2. `protoc-gen-ball` emits real `.pb.dart` models (mutable
> classes over a `Map<String, Object?>` backing store, per
> `docs/PROTOBUF_CODEGEN_PLAN.md` §4.3) that round-trip through the
> `ball_protobuf` runtime. Services + extensions + C++/TS targets land in later
> phases.

## Generated model shape

Per message, the generator emits a mutable class wrapping the dynamic backing
`Map`, with typed getters/setters honouring the resolved Editions presence
(EXPLICIT fields get `hasX()`/`clearX()`; IMPLICIT fields fall back to the type
default), repeated `List`s, `Map` fields, nested messages, enums, and oneof
`whichX` discriminants. Each class embeds the resolved `ball_protobuf`
descriptor (Editions features baked in) and delegates `toBytes()`/`fromBytes()`
to `marshal`/`unmarshal` and `toProto3Json()`/`fromProto3Json()` to
`messageToJson`/`messageFromJson`. No wire/JSON logic is generated — the
conformance-pinned runtime does it all. Enums are emitted as int-backed wrapper
classes so open enums preserve unknown integer values.

## Golden test + regeneration

`test/golden/test_messages.pb.dart` is a single self-contained file holding the
generated models for every message + enum in the conformance
`FileDescriptorSet` (proto2, proto3, edition2023 `TestAllTypes` plus the
well-known types). Regenerate it with:

```sh
cd dart/ball_protobuf_gen
dart run tool/gen_golden.dart
```

`test/message_roundtrip_test.dart` imports the golden directly and proves, for
representative messages, that building via generated setters and serializing
equals the dynamic codec, that decoding restores the same values, and that JSON
agrees — across scalars, repeated, map, oneof, nested, enum, group, and
optional/presence. A drift-guard test fails if the committed golden differs
from a fresh regeneration.

## The plugin: `protoc-gen-ball`

A protobuf code-generator plugin is just a program that reads a serialized
`google.protobuf.compiler.CodeGeneratorRequest` from stdin and writes a
serialized `CodeGeneratorResponse` to stdout. The whole request→response core
lives in `lib/src/plugin.dart` (`decodeRequest` / `generate` / `encodeResponse`,
combined as `runPlugin`) so it is unit-testable without spawning a process;
`bin/protoc_gen_ball.dart` is a thin stdin/stdout wrapper.

### Decode approach

`ball_base` ships generated bindings for `descriptor.proto` but **not** for
`compiler/plugin.proto`, so there is no generated `CodeGeneratorRequest` /
`CodeGeneratorResponse` to reuse. Rather than add a protoc-dart codegen step for
two messages, the plugin **dogfoods the `ball_protobuf` runtime**: it
hand-authors the small `Map` field descriptors for the plugin messages (only the
fields it needs) and decodes/encodes them with `unmarshal`/`marshal` — the same
descriptor-driven path the runtime is conformance-tested on. `proto_file` entries
are decoded as raw `FileDescriptorProto` bytes; `generate` re-wraps them into a
`FileDescriptorSet` and feeds them to the generator (which decodes them via
`ball_base`).

### Capabilities advertised

The response sets:

- `supported_features = FEATURE_PROTO3_OPTIONAL | FEATURE_SUPPORTS_EDITIONS` (3);
- `minimum_edition = EDITION_PROTO2` (998) and `maximum_edition = EDITION_2023`
  (1000) — `ball_protobuf`'s golden-verified span (see `docs/EDITIONS_SPEC.md`).

### Build

```sh
cd dart/ball_protobuf_gen
dart compile exe bin/protoc_gen_ball.dart -o protoc-gen-ball
```

### Invoke with protoc

`protoc` discovers a plugin named `protoc-gen-NAME` on PATH and invokes it for
`--NAME_out`:

```sh
protoc --plugin=protoc-gen-ball=./protoc-gen-ball \
       --ball_out=./out \
       --ball_opt=some=option \
       path/to/your.proto
```

### Invoke with buf

Add a local plugin entry to `buf.gen.yaml`:

```yaml
version: v2
plugins:
  - local: ./dart/ball_protobuf_gen/protoc-gen-ball
    out: gen
    # opt: some=option
```

then run `buf generate`.

## Testing

```sh
cd dart/ball_protobuf_gen
dart test
```

`test/plugin_smoke_test.dart` builds a real `CodeGeneratorRequest` by wrapping
the checked-in `tests/editions/descriptors/test_messages.fds.binpb`
FileDescriptorSet, runs it through the core transform, and asserts the response
parses, carries the correct feature flags and edition range, and contains one
output file per requested input.
