# ball_protobuf_gen

Consumer-model code-generator support for the [`ball_protobuf`](../ball_protobuf)
runtime — the protoc/buf plugins that turn a `.proto` into typed Dart models and
service stubs bound to that runtime. This package owns:

- the **descriptor bridge** (`lib/src/descriptor_bridge.dart`) — turns a
  protoc-emitted `FileDescriptorSet` into the resolved, Editions-aware `Map`
  field descriptors that `ball_protobuf`'s codecs consume;
- the **generator** (`lib/src/{gen_model,dart_emitter,generator}.dart`) — a
  target-independent front end (`GenModelBuilder` → an intermediate `GenModel`
  tree) plus a Dart emitter that produces `.pb.dart` message models;
- the **service emitters** (`lib/src/{service_common,connect_emitter,grpc_emitter}.dart`)
  — produce `.connect.dart` / `.grpc.dart` typed clients that delegate to a
  [`ball_rpc`](../ball_rpc) transport; and
- the three **plugin binaries** — `protoc-gen-ball`
  (`bin/protoc_gen_ball.dart`, messages + enums + extensions),
  `protoc-gen-ball-connect` (`bin/protoc_gen_ball_connect.dart`), and
  `protoc-gen-ball-grpc` (`bin/protoc_gen_ball_grpc.dart`) — each reading a
  `CodeGeneratorRequest` from stdin and writing a `CodeGeneratorResponse` to
  stdout.

It legitimately depends on both `ball_base` (the generated `descriptor.pb.dart`
types) and `ball_protobuf` (the runtime + editions resolver), so — unlike the
`ball_protobuf` runtime `lib/` — it is **not** Ball-portable.

> **Status: Dart target shipped (plan Phases 0–4).** The plugins emit real
> `.pb.dart` models (mutable classes over a `Map<String, Object?>` backing
> store, per `docs/PROTOBUF_CODEGEN_PLAN.md` §4.3) covering Editions / oneof /
> map / nested / WKT / Any, plus extensions + registries and gRPC + Connect
> service stubs, all round-tripping through the `ball_protobuf` runtime. C++/TS
> *library* targets remain roadmap — see `docs/PROTOBUF_CODEGEN_PLAN.md`,
> "Multi-target status & roadmap". `dart test` from this package dir runs 63
> tests.

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

## Extensions

`protoc-gen-ball` emits, per `extend` field, a `$pb.Extension` handle (carrying
the extendee FQN, the bracketed `[fqn]` storage key, the field number/type, and
— for message extensions — the embedded field descriptor) plus typed
`getX / setX / hasX / clearX` top-level helpers that read and write the
extension's `[fqn]` key in the extended message's backing map. Every generated
file also emits a per-file `$extensionRegistry` (`$pb.ExtensionRegistry`) that
registers the file's extensions and merges imported siblings' registries, so
custom-option and Any-in-JSON resolution can find extension types. As with
messages, no wire/JSON logic is generated — the helpers delegate to the runtime
via the extendee's descriptor.

## Services: `protoc-gen-ball-connect` and `protoc-gen-ball-grpc`

Service codegen is split from message codegen (plan §8 / §13.2): the two service
plugins emit *only* their service files, and a message-only `.proto` produces no
output from them. Per service:

- a `$svc.ServiceDescriptor` const (`<Service>ServiceDescriptor`) — a
  transport-agnostic list of `MethodDescriptor`s (name, input/output FQN,
  streaming `MethodKind`, idempotency) from the `ball_protobuf` runtime; and
- a typed client class — `<Service>Client` (`.connect.dart`) /
  `<Service>GrpcClient` (`.grpc.dart`) — wrapping a [`ball_rpc`](../ball_rpc)
  `RpcTransport`. Each method marshals its request via the generated message
  `toBytes`, calls the matching `RpcTransport` method (`unary` / `serverStream` /
  `clientStream` / `bidiStream`) on the full `/{package}.{Service}/{Method}`
  path, and decodes the response via `fromBytes`. Unary returns a `Future`;
  streaming returns a `Stream`. The transport (Connect over HTTP/1.1 or
  gRPC-over-HTTP/2) and the `ball_protobuf` runtime handle all framing — the
  generated client contains no wire logic.

The two emitters share almost everything (`lib/src/service_common.dart`): the
same resolved service model, the same descriptor const, and the same method
bodies. The only differences are the file extension, the client class name, and
the default-transport doc comments. Consumers wire a generated client to a
concrete transport from `ball_rpc` (`ConnectTransport`, `GrpcTransport`, or
`FakeTransport` for tests).

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

## The plugins

A protobuf code-generator plugin is just a program that reads a serialized
`google.protobuf.compiler.CodeGeneratorRequest` from stdin and writes a
serialized `CodeGeneratorResponse` to stdout. This package ships three:

- **`protoc-gen-ball`** — message + enum + extension models (`.pb.dart`);
- **`protoc-gen-ball-connect`** — Connect service stubs (`.connect.dart`);
- **`protoc-gen-ball-grpc`** — gRPC service stubs (`.grpc.dart`).

The whole request→response core for messages lives in `lib/src/plugin.dart`
(`decodeRequest` / `generate` / `encodeResponse`, combined as `runPlugin`;
the service cores are `runConnectPlugin` / `runGrpcPlugin`) so it is
unit-testable without spawning a process; each `bin/*.dart` is a thin
stdin/stdout wrapper.

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

`dart compile exe` produces a self-contained native executable per plugin (named
`protoc-gen-NAME`, the name `protoc`/`buf` look for on PATH):

```sh
cd dart/ball_protobuf_gen
dart compile exe bin/protoc_gen_ball.dart         -o protoc-gen-ball
dart compile exe bin/protoc_gen_ball_connect.dart -o protoc-gen-ball-connect
dart compile exe bin/protoc_gen_ball_grpc.dart    -o protoc-gen-ball-grpc
```

(You can also run a plugin unbuilt via `dart run bin/protoc_gen_ball.dart`, but
the compiled executable is what `protoc`/`buf` expect on PATH.)

### Invoke with protoc

`protoc` discovers a plugin named `protoc-gen-NAME` on PATH and invokes it for
`--NAME_out`. Generate messages and (optionally) services in one invocation,
each writing to the same `--*_out` tree:

```sh
protoc \
  --plugin=protoc-gen-ball=./protoc-gen-ball \
  --plugin=protoc-gen-ball-connect=./protoc-gen-ball-connect \
  --plugin=protoc-gen-ball-grpc=./protoc-gen-ball-grpc \
  --ball_out=./out \
  --ball-connect_out=./out \
  --ball-grpc_out=./out \
  path/to/your.proto
```

(`--ball_opt=key=value` passes plugin options; drop the service plugins for a
message-only build.)

### Invoke with buf

List the local plugins in `buf.gen.yaml`; `buf generate` runs them in order into
the same `out` directory:

```yaml
version: v2
plugins:
  - local: ./dart/ball_protobuf_gen/protoc-gen-ball
    out: gen
    # opt: key=value
  - local: ./dart/ball_protobuf_gen/protoc-gen-ball-connect
    out: gen
  - local: ./dart/ball_protobuf_gen/protoc-gen-ball-grpc
    out: gen
```

> Note: this is a *separate* `buf.gen.yaml` for consumer codegen — do **not**
> add these plugins to the repo's root `buf.gen.yaml`, which generates Ball's own
> language bindings and is guarded by the "Proto Checks" CI job.

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
