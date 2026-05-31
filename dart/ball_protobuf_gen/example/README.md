# Wiring the Ball codegen plugins with `buf`

This directory shows how a **consumer** generates Ball-runtime-bound model and
service code from their own `.proto` files using
[`buf generate`](https://buf.build/docs/generate/overview) and the three
`ball_protobuf_gen` plugins:

| Plugin | Emits | Purpose |
|---|---|---|
| `protoc-gen-ball` | `<file>.pb.dart` | messages, enums, oneofs, maps, nested types, extensions |
| `protoc-gen-ball-connect` | `<file>.connect.dart` | Connect-protocol service client + `ServiceDescriptor` |
| `protoc-gen-ball-grpc` | `<file>.grpc.dart` | gRPC-over-HTTP/2 service client + `ServiceDescriptor` |

The template is [`buf.gen.ball.yaml`](./buf.gen.ball.yaml). It declares the three
plugins as **local** plugins — `buf` runs a local plugin by spawning a named
executable, so you compile each plugin to a native binary first.

> This is a standalone example, separate from the repo-root `buf.gen.yaml`
> (which generates the standard bindings for `proto/ball/v1/ball.proto`). Copy
> `buf.gen.ball.yaml` next to your own `.proto` tree and adjust the `local:`
> paths.

## 1. Compile the plugins (`dart compile exe`)

A protobuf code-generator plugin is just an executable that reads a
`CodeGeneratorRequest` from stdin and writes a `CodeGeneratorResponse` to
stdout. Compile each `bin/` entry point to a native executable:

```sh
cd dart/ball_protobuf_gen
dart compile exe bin/protoc_gen_ball.dart         -o protoc-gen-ball
dart compile exe bin/protoc_gen_ball_connect.dart -o protoc-gen-ball-connect
dart compile exe bin/protoc_gen_ball_grpc.dart    -o protoc-gen-ball-grpc
```

On Windows these produce `protoc-gen-ball.exe`, `protoc-gen-ball-connect.exe`,
and `protoc-gen-ball-grpc.exe`; `buf` resolves the `.exe` suffix automatically,
so the template paths need no change.

(You can run the plugins unbuilt with `dart run bin/<plugin>.dart`, but `buf`
expects a single executable on each `local:` line — the compiled binary is the
form `buf` invokes.)

## 2. Generate (`buf generate`)

From the directory `buf` treats as the workspace root — here, the repo root, so
the `./dart/ball_protobuf_gen/...` paths in the template resolve — point `buf` at
this template:

```sh
buf generate --template dart/ball_protobuf_gen/example/buf.gen.ball.yaml
```

`buf generate` operates on the `.proto` files in the current
[buf module/workspace](https://buf.build/docs/reference/inputs); you can also
pass an explicit input (a directory, `buf.yaml` workspace, or image), e.g.
`buf generate path/to/protos --template .../buf.gen.ball.yaml`. Each plugin
writes into the `out: gen` directory; running `protoc-gen-ball` together with a
service plugin in the same template puts the `.pb.dart` and `.connect.dart` /
`.grpc.dart` files side by side so the service files can import their message
types.

## 3. What you get & runtime dependencies

Generated `.pb.dart` files import `package:ball_protobuf` and delegate all
wire/JSON encoding to that conformance-pinned runtime — no serialization code is
generated. Generated `.connect.dart` / `.grpc.dart` service files additionally
import `package:ball_rpc` (the transport runtime). Add the dependencies your
generated code uses to the consuming project's `pubspec.yaml`:

```yaml
dependencies:
  ball_protobuf: ^0.3.0   # required by every .pb.dart
  ball_rpc: ^0.3.0        # required only if you generate .connect.dart / .grpc.dart
```

Keeping only the plugin(s) you need (drop `protoc-gen-ball-connect` and/or
`protoc-gen-ball-grpc` from the template) keeps message-only consumers from
pulling in any service code.
