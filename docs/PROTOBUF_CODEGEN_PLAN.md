# Consumer Model Codegen for `ball_protobuf` — Design Plan

> Status: PLAN — for review before any code is written.
> Sources cited inline; all repo paths verified against the tree; all external
> protocol facts verified against primary sources (protobuf `plugin.proto`,
> connectrpc.com, buf docs) rather than recalled.

---

## 1. Executive Summary

`ball_protobuf` is today a **descriptor-driven protobuf *runtime*** — binary +
proto3-JSON codecs, the full Editions feature model, WKT/Any, gRPC framing —
authored in Ball-portable Dart and **conformance-tested at 2769/2769** against
the upstream `conformance_test_runner`. What it has **no** path for is the thing
every other protobuf ecosystem ships: **a code generator that turns a `.proto`
into typed model classes (and service stubs) bound to that runtime.** A consumer
who wants typed Dart/C++/TS models today must either use the stock plugins
(which bind to `package:protobuf` / `@bufbuild/protobuf` / `libprotobuf`, *not*
`ball_protobuf`) or hand-roll the dynamic `Map` API.

This plan specifies that generator. The central decision, justified in §3, is to
follow the **modern "thin schema + descriptor-driven runtime" model**
(protobuf-es v2, protobuf-go `dynamicpb`, `hyperpb`) — **not** the classic
"fat generated code" model (C++/Java/C#/`protoc-gen-dart`). Generated code stays
thin (a typed view + an embedded descriptor); all encoding is delegated to the
already-validated `ball_protobuf` runtime. The generator is **authored once in
Ball-portable Dart and compiled by Ball's own toolchain to every target**, so a
single source emits Dart, C++, and TS models — directly realizing Ball's
portability thesis. The plan covers messages, **Editions**, **extensions**,
**gRPC**, and **Connect RPC** as first-class concerns.

---

## 2. Background: the universal plugin contract (verified)

Every protobuf model generator — `protoc-gen-go`, `protoc-gen-java`,
`protoc-gen-dart`, `protoc-gen-es`, … — is the same kind of program: an
executable named `protoc-gen-<NAME>` that reads a **`CodeGeneratorRequest`** from
stdin and writes a **`CodeGeneratorResponse`** to stdout. It is invoked by
`protoc --<NAME>_out=…` or by `buf generate` (local or remote plugin). The
contract, verified from the repo's own
[`plugin.proto`](../cpp/build3/_deps/protobuf-src/src/google/protobuf/compiler/plugin.proto):

**`CodeGeneratorRequest`**
| field | # | meaning |
|---|---|---|
| `file_to_generate` | 1 | the `.proto` files the user explicitly asked to generate (not imports) |
| `parameter` | 2 | the `opt=…` string passed on the command line |
| `proto_file` | 15 | `repeated FileDescriptorProto` — every file + all transitive imports |
| `source_file_descriptors` | 17 | source-retention descriptors for `file_to_generate` |
| `compiler_version` | 3 | protoc/buf version |

**`CodeGeneratorResponse`**
| field | # | meaning |
|---|---|---|
| `error` | 1 | non-empty ⇒ generation failed |
| `supported_features` | 2 | bitset: `FEATURE_PROTO3_OPTIONAL=1`, `FEATURE_SUPPORTS_EDITIONS=2` |
| `minimum_edition` / `maximum_edition` | 3 / 4 | edition range the plugin supports |
| `file[]` | 15 | each `{name, content, insertion_point?, generated_code_info?}` |

The request is itself a protobuf message — which `ball_protobuf` can decode with
its own runtime (see §4.2, "dogfooding"). Boilerplate (option parsing, request
decode, file assembly) is abstracted by frameworks: Go's `protogen`
([pkg.go.dev/.../protogen](https://pkg.go.dev/google.golang.org/protobuf/compiler/protogen)),
TS's `@bufbuild/protoplugin`. We will provide the equivalent thin harness for our
plugin.

---

## 3. The two design models, and our decision

| | **Classic "fat codegen"** | **Modern "thin schema + descriptor-driven runtime"** |
|---|---|---|
| Examples | C++ `libprotobuf`, `protobuf-java`, C# `Google.Protobuf`, [`protoc-gen-dart`](https://protobuf.dev/reference/dart/dart-generated/) | [protobuf-go reflection path] + [`dynamicpb`](https://pkg.go.dev/google.golang.org/protobuf/types/dynamicpb), [**protobuf-es v2**](https://buf.build/blog/protobuf-es-v2), [**hyperpb**](https://github.com/bufbuild/hyperpb-go) |
| Per message | a class with bespoke typed accessors | a plain type/struct **+ a schema/descriptor object** |
| Serialization | inlined in generated code (C++/Java/C#) or delegated to the runtime via embedded metadata (Dart's `GeneratedMessage`+`BuilderInfo`) | a **generic runtime** walks the descriptor; codegen contains **no** serialize logic |
| Generated size | large | small, tree-shakeable |
| Runtime-loaded schemas | no | yes |
| Performance | fast | competitive — `hyperpb` is 10× faster than `dynamicpb` and **2–3× faster than generated Go code** |

Verified specifics:
- **protobuf-es v2** *"no longer generate[s] classes… Instead, we generate a
  schema object and an associated TypeScript type definition for each message."*
  The runtime fns take **(schema, plain object)**: `create(UserSchema, {…})`,
  `toBinary(UserSchema, msg)`, `fromBinary(UserSchema, bytes)`,
  `toJson`/`fromJson`. Rationale: framework friendliness, ESM/tree-shaking,
  conformance. ([buf.build/blog/protobuf-es-v2](https://buf.build/blog/protobuf-es-v2))
- **`dynamicpb`** is a `proto.Message` **backed by a descriptor + a map of
  field→value**, no codegen, full `proto.Marshal/Unmarshal` via reflection.
- **`hyperpb`** is a table-driven VM proving the descriptor-driven path is not a
  performance compromise.

**Decision: adopt the modern model.** This is not a stylistic preference — it is
the lowest-risk, highest-leverage choice *for Ball specifically*:

1. **`ball_protobuf` is already the runtime half of this design.** `marshal(msg,
   descriptor)` / `unmarshal(bytes, descriptor)` over `Map<String,Object?>` is the
   exact analog of `dynamicpb` and protobuf-es's runtime — and it is
   conformance-tested. Generated code that delegates to it **cannot drift from
   spec**, and the upstream suite covers consumers transparently.
2. Fat codegen would mean re-emitting (and re-verifying) serialization logic per
   target language — throwing away the 2769/2769 investment.
3. The thin model keeps generated output small and matches where the ecosystem is
   heading.

**We keep one thing from the classic model: a typed view.** Pure-dynamic gives up
compile-time field types and ergonomics. protobuf-es's lesson is to generate
typed accessors *on top of* a generic runtime — DX **and** correctness, not a
trade-off. So per message we generate a typed shell whose accessors read/write an
internal `Map`, plus an embedded descriptor; the runtime does the bytes/JSON.

---

## 4. Architecture

### 4.1 Layers

```
.proto ──(protoc | buf, the frontend)──▶ CodeGeneratorRequest
                                              │
                                   protoc-gen-ball  (this plan)
                                   ├─ decode request (via ball_protobuf itself)
                                   ├─ descriptor_bridge: FileDescriptorProto
                                   │   + resolved Editions FeatureSet ─▶ ball descriptors
                                   └─ emit per target:
                                        • <file>.pb.<lang>     (messages + enums + embedded descriptors)
                                        • <file>.connect.<lang> / <file>.grpc.<lang>  (service descriptors)
                                              │
                       generated code  ──delegates──▶  ball_protobuf runtime
                                                        (marshal / unmarshal / json / framing)
```

The generator never re-implements the wire format. It is a **descriptor
transformer + a typed-view emitter**.

### 4.2 Dogfooding the request decode

`CodeGeneratorRequest`, `FileDescriptorProto`, and `descriptor.proto` are
ordinary protobuf messages. We register their descriptors once and decode the
plugin's stdin with `ball_protobuf` itself — no third-party protobuf dependency
in the generator. The existing
[`tool/descriptor_bridge.dart`](../dart/ball_protobuf/tool/descriptor_bridge.dart)
already turns a `FileDescriptorSet` into `ball_protobuf` Map descriptors with
resolved FeatureSets and folded-in extensions; it is the front half of the
plugin. **It imports `package:ball_base` (the protoc descriptor types), so it is
*not* Ball-portable and must not live in `ball_protobuf/lib/` (which is pure
`dart:core`/`convert`/`typed_data`, `ball_base` being only a dev-dependency).**
Therefore the bridge's logic moves into the **new `ball_protobuf_gen` package**
(§13.1), which legitimately depends on both `ball_base` (descriptor types) and
`ball_protobuf` (runtime). The green conformance harness in
`ball_protobuf/tool/` keeps its existing copy untouched.

### 4.3 Generated message shape (Dart, the first target)

For `message User { string first_name = 1; bool active = 3; }`:

```dart
// user.pb.dart  (generated — do not edit)
import 'package:ball_protobuf/ball_protobuf.dart';

/// Embedded ball_protobuf descriptor (carries resolved Editions features).
const List<Map<String, Object?>> _userDescriptor = [
  {'name': 'first_name', 'number': 1, 'type': 'TYPE_STRING', 'jsonName': 'firstName'},
  {'name': 'active',     'number': 3, 'type': 'TYPE_BOOL'},
];

class User {
  final Map<String, Object?> $fields;          // the dynamic backing store
  User([Map<String, Object?>? fields]) : $fields = fields ?? {};

  String get firstName => ($fields['first_name'] as String?) ?? '';
  set firstName(String v) => $fields['first_name'] = v;

  bool get active => ($fields['active'] as bool?) ?? false;
  set active(bool v) => $fields['active'] = v;

  List<int> toBytes() => marshal($fields, _userDescriptor);
  static User fromBytes(List<int> b) => User(unmarshal(b, _userDescriptor));

  Object? toProto3Json() => messageToJson($fields, _userDescriptor);          // §11 gap
  static User fromProto3Json(Object? j) => User(messageFromJson(j, _userDescriptor));
}
```

- Typed getters/setters give DX; the backing `Map` + descriptor give the runtime
  everything it needs. **No serialization code is generated.**
- C++ emits a struct wrapping an ordered `BallMap` with the same delegation; TS
  emits a `type` + a schema const exactly like protobuf-es. The *generator logic*
  is shared (§9); only the emission templates differ per target.

---

## 5. Editions (first-class)

`ball_protobuf` already resolves FeatureSets (`editions.dart` + `edition.dart`),
and the codecs already honour `field_presence`, `enum_type`,
`repeated_field_encoding`, `message_encoding`, `utf8_validation`, `json_format`
when a descriptor carries a `'features'` map. The generator's job is to **resolve
features at generation time and bake them into each emitted descriptor** so the
runtime behaves identically across proto2 / proto3 / edition 2023:

- Drive **everything** off the resolved `FeatureSet` — never branch on
  `syntax == proto2/proto3` in templates. `descriptor_bridge` already does the
  canonical resolution; reuse it unchanged.
- **Presence:** EXPLICIT fields generate `hasX()`/`clearX()`; IMPLICIT fields
  generate plain getters with type-default fallback (as in the §4.3 example).
  LEGACY_REQUIRED is validated on `toBytes`.
- **Closed enums:** generate the enum but route out-of-range values to unknowns
  (runtime already does this); open enums accept any int.
- Advertise `FEATURE_SUPPORTS_EDITIONS | FEATURE_PROTO3_OPTIONAL` in the
  `CodeGeneratorResponse`, and set `minimum_edition`/`maximum_edition` to the
  range `ball_protobuf` supports (proto2 … edition 2023).

This makes Ball one of the few toolchains whose *generated* code is Editions-correct on every target, since the single runtime is shared.

---

## 6. Extensions (first-class)

Extensions are wire-indistinguishable from regular fields; `descriptor_bridge`
already folds `extend` blocks into the extendee keyed by `[fully.qualified.name]`
(avoiding simple-name collisions). Codegen adds the typed surface:

- Emit an **extension handle** per extension: `final userEmail = Extension<String>('[acme.user_email]', _descriptor)`.
- Emit `getExtension(msg, ext)` / `setExtension(msg, ext)` helpers that read/write
  the `[fqn]` key in the backing `Map` via the runtime.
- Emit an **extension registry** per file and a `mergeRegistries(...)` helper, so
  Any-in-JSON and option resolution can find extension types (mirrors
  protobuf-es's registry API and protobuf-go's `protoregistry`).
- Custom options (which are themselves extensions on `*Options` messages) are
  retained in descriptors and reachable through the same registry.

---

## 7. Well-Known Types, Any, oneofs, maps, nested types

All already handled by the runtime (conformance-proven); codegen only emits typed
views:
- **WKT** (`Timestamp`, `Duration`, `FieldMask`, wrappers, `Struct`/`Value`/
  `ListValue`): generate thin typed wrappers whose JSON delegates to the runtime's
  WKT path; binary is the generic path.
- **Any:** generate `pack<T>(msg)` / `unpackTo<T>()` helpers; JSON `@type`
  resolution uses the generated file registry wired into the runtime's
  `anyTypeResolver` hook (already present in `json_codec.dart`).
- **oneofs:** generate a `whichX` discriminant getter + per-member setters that
  clear siblings (runtime already enforces last-wins + always-serialize-set).
- **maps / repeated / nested messages:** typed `Map`/`List` getters over the
  backing store; runtime marshals map entries and packed/expanded repeats per
  resolved features.

---

## 8. Services: gRPC + Connect (first-class)

### 8.1 Shared model — separate service codegen from message codegen

Verified best practice from connect-es: **message codegen produces schemas;
service codegen produces a *service descriptor*** (method name, input/output
schema refs, streaming kind, idempotency) **that a generic, pluggable transport
consumes**. The same service definition then works over gRPC, gRPC-Web, and
Connect — `createClient(serviceDescriptor, transport)`. We mirror this:

```dart
const elizaService = ServiceDescriptor('acme.Eliza', [
  MethodDescriptor('Say',     input: SayRequest.descriptor,  output: SayResponse.descriptor, kind: MethodKind.unary),
  MethodDescriptor('Converse',input: ConverseRequest.descriptor, output: ConverseResponse.descriptor, kind: MethodKind.bidiStreaming),
]);
// client = createClient(elizaService, GrpcTransport(...) | ConnectTransport(...));
```

`grpc_frame.dart` already provides `extractServiceMethods()` (pulls
name/input/output/clientStreaming/serverStreaming from a service descriptor) — the
seed of `ServiceDescriptor`. We generate the typed wrapper around it.

### 8.2 gRPC transport (HTTP/2)

- Framing already exists: `grpc_frame.dart` (`grpcEncodeFrame` / decode) —
  1 flag byte + 4-byte big-endian length + message bytes, per
  `grpc/doc/PROTOCOL-HTTP2.md`.
- Transport responsibilities: path `/{package}.{service}/{method}`,
  `content-type: application/grpc+proto`, `grpc-status`/`grpc-message` trailers,
  the four method kinds. Message bytes come from the runtime.

### 8.3 Connect transport (verified against [connectrpc.com/docs/protocol](https://connectrpc.com/docs/protocol/))

- **Unary:** HTTP POST, body = a single serialized message
  (`application/proto` or `application/json`); side-effect-free methods
  (`idempotency_level = NO_SIDE_EFFECTS`) may use GET with the message in query
  params. Errors = **non-200** + JSON `{code, message, details[]}`.
- **Streaming:** `application/connect+proto` / `application/connect+json`;
  enveloped as **1 flag byte + 4-byte big-endian length + payload** — *the same
  layout as a gRPC frame*, except **flag bit 1 = end-of-stream**; the final
  enveloped message is an `EndStreamResponse` JSON carrying error + trailing
  metadata. Streaming errors return HTTP 200 with the error in that final frame.
- **Headers:** `connect-protocol-version: 1`, `connect-timeout-ms`,
  `content-encoding`/`connect-content-encoding`, `-bin` base64 custom headers.
- **Reuse:** extend `grpc_frame.dart`'s flag-byte handling to expose the
  end-of-stream bit; the same encode/decode serves Connect streaming. The 16
  canonical Connect error codes map 1:1 to gRPC status codes — one shared
  `RpcError`/`Code` enum serves both transports.

### 8.4 What the generator emits for services

- A `ServiceDescriptor` const per service (methods + I/O descriptor refs + kind +
  idempotency).
- A typed client interface (`Future<SayResponse> say(SayRequest)` for unary;
  `Stream`-based signatures for streaming) bound to a transport.
- Optionally a server handler interface (a typed dispatch the user implements).
- These are emitted by **separate plugins** (`protoc-gen-ball-connect` /
  `protoc-gen-ball-grpc`, §13.2) into `*.connect.dart` / `*.grpc.dart`, so
  message-only consumers never invoke them and pay nothing. Both reuse the
  message plugin's generated descriptors + the shared `ServiceDescriptor` types.

---

## 9. Authoring strategy: one generator, all targets

Per Ball's thesis and your steer, the generator itself is **authored in
Ball-portable Dart** and compiled by Ball's existing compilers to Dart, C++, and
TS. A target is then a set of **emission templates** (string-building per the
target's syntax) sharing one front end (request decode → resolved descriptors →
an intermediate "GenModel" tree). This:
- emits Dart **and** C++ **and** TS models from a single source of truth;
- means the generator runs anywhere Ball runs;
- dogfoods both `ball_protobuf` (request decode) and the Ball compiler (the
  generator is itself a Ball program).

Risk: the Ball compiler/encoder must handle a program this size and string-heavy.
Mitigation: build and validate the **Dart-native generator first** (plain Dart in
`dart/ball_protobuf_gen/`), prove the model end-to-end, *then* port the front end
to Ball-portable Dart and add C++/TS templates. This de-risks the novel part
without blocking the deliverable.

---

## 10. Runtime API gaps to close (small)

The runtime is feature-complete for bytes; codegen needs a couple of **public**
entry points it can delegate to (today some are private/field-level):
1. **Message-level proto3-JSON:** expose `messageToJson(map, descriptor)` /
   `messageFromJson(json, descriptor)` (the `_marshalToMap` / `_unmarshalFromMap`
   logic in `json_codec.dart` is currently private).
2. **`ServiceDescriptor` / `MethodDescriptor` / `MethodKind`** value types in
   `lib/` (generalising `extractServiceMethods`).
3. **Connect end-of-stream flag** accessor on the frame codec (§8.3).
4. **Extension / registry** value types (§6).

None require schema changes; all are additive to `ball_protobuf`'s public API.

---

## 11. Phased build plan

| Phase | Deliverable | Gate |
|---|---|---|
| 0 | Scaffold `ball_protobuf_gen` package; move `descriptor_bridge` into it (depends on `ball_base`+`ball_protobuf`); add the §10 public runtime entry points to `ball_protobuf` | unit tests; analyze/format clean; conformance harness still green |
| 1 | `protoc-gen-ball` skeleton (Dart-native): decode `CodeGeneratorRequest` via `ball_protobuf`, emit empty `CodeGeneratorResponse` with correct feature flags | runs under `protoc` and `buf generate` |
| 2 | **Message codegen, Dart target** — enums, messages, oneofs, maps, nested, WKT views (mutable-over-Map, §4.3) | new conformance: generated-model round-trips for proto2/proto3/edition2023 |
| 3 | **Extensions + registries** (Dart) | extension round-trips; Any-in-JSON via generated registry |
| 4 | **Services** (separate plugins, §13.2): `ServiceDescriptor` + `protoc-gen-ball-connect` (unary + streaming), then `protoc-gen-ball-grpc` | echo/streaming integration tests against a reference server |
| 5 | Port the generator front end to **Ball-portable Dart**; add **C++ and TS** emission templates | same `.proto` → models on Dart/C++/TS; cross-target golden tests |
| 6 | `buf.gen.yaml` wiring, docs (`<lang>/AGENTS.md`, README), CI job | CI green on all targets |

Each phase is independently shippable and leaves the tree green.

---

## 12. Testing & conformance

- **Reuse the upstream descriptor set** (`tests/editions/descriptors/test_messages.fds.binpb`):
  generate models for `TestAllTypes*`, then round-trip generated-model →
  bytes/JSON → generated-model and compare to the dynamic runtime (which is
  already conformance-pinned). Any divergence is a codegen bug, not a codec bug.
- **Golden generated files** checked in per target; a CI drift-guard regenerates
  and diffs (mirrors the existing editions golden guard).
- **Service tests:** stand up a tiny reference handler; exercise Connect unary +
  streaming and gRPC unary + streaming, including the end-of-stream/error paths.

---

## 13. Resolved decisions (reviewer-approved)

1. **Package layout — DECIDED: new package `dart/ball_protobuf_gen/`.** Keeps the
   runtime dependency-light; the generator and its plugin binaries are a separate
   publishable package depending on `ball_base` + `ball_protobuf`.
2. **Service plugin split — DECIDED: separate plugins.** `protoc-gen-ball`
   (messages/enums/extensions) + `protoc-gen-ball-connect` + `protoc-gen-ball-grpc`,
   following the connect-es precedent of decoupled service plugins. Message-only
   consumers never pull service code.
3. **Typed-view ergonomics — DECIDED: mutable plain object over a `Map` (§4.3).**
   This is also current best practice: Go, protobuf-es v2, and C# all use mutable
   plain objects; only Java retains immutable+builder.
4. **gRPC-Web** — deferred to a follow-up (transport-only delta over gRPC); not in
   the initial phases.

---

## 14. Out of scope

- Re-implementing the wire format in generated code (the whole point is *not* to).
- A native `.proto` text parser (we rely on `protoc`/`buf` as the frontend, as
  every plugin does; a Ball-portable `.proto` parser is a separable future effort).
- Migrating `proto/ball/v1/ball.proto` itself to editions.

---

## 15. Sources

- protoc plugin contract — repo [`plugin.proto`](../cpp/build3/_deps/protobuf-src/src/google/protobuf/compiler/plugin.proto); [Go `protogen`](https://pkg.go.dev/google.golang.org/protobuf/compiler/protogen)
- modern model — [protobuf-es v2](https://buf.build/blog/protobuf-es-v2); [protobuf-es repo](https://github.com/bufbuild/protobuf-es); [`dynamicpb`](https://pkg.go.dev/google.golang.org/protobuf/types/dynamicpb); [hyperpb-go](https://github.com/bufbuild/hyperpb-go)
- classic model — [Dart generated code](https://protobuf.dev/reference/dart/dart-generated/)
- Connect protocol — [connectrpc.com/docs/protocol](https://connectrpc.com/docs/protocol/); [connect-es](https://github.com/connectrpc/connect-es)
- repo runtime — `dart/ball_protobuf/lib/{marshal,unmarshal,json_codec,grpc_frame,editions,edition}.dart`, `tool/descriptor_bridge.dart`
