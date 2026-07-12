// The `ball` CLI (epic #426 Phase 5): a single binary with the four core verbs
// run / compile / encode / check over the Go engine, compiler, and encoder.
//
// Depends on go/engine (run), go/compiler (compile), go/encoder (encode), and
// go/shared (the ballv1 proto types) plus google.golang.org/protobuf for the
// Any/proto3-JSON (de)serialization `encode` and the loaders need. go/runtime
// (ballrt) is pulled in transitively by engine/compiler, hence the replace.
//
// `run` executes via the self-hosted engine, which is gated behind the
// `selfhost` build tag (go/engine's run_selfhost.go / run_stub.go). Because Go
// build tags propagate through the build, `go build -tags selfhost ./...` here
// pulls in the real engine; a plain build gets the stub, and `run` reports a
// clear "rebuild with -tags selfhost" error instead of failing to compile — the
// Go analog of the Rust CLI's `self_host` cargo feature and C#'s
// `-p:SelfHost=true` MSBuild property.
module github.com/ball-lang/ball/go/cli

go 1.23

require (
	github.com/ball-lang/ball/go/compiler v0.0.0
	github.com/ball-lang/ball/go/encoder v0.0.0
	github.com/ball-lang/ball/go/engine v0.0.0
	github.com/ball-lang/ball/go/shared v0.0.0
	google.golang.org/protobuf v1.36.11
)

require github.com/ball-lang/ball/go/runtime v0.0.0 // indirect

replace github.com/ball-lang/ball/go/shared => ../shared

replace github.com/ball-lang/ball/go/runtime => ../runtime

replace github.com/ball-lang/ball/go/compiler => ../compiler

replace github.com/ball-lang/ball/go/encoder => ../encoder

replace github.com/ball-lang/ball/go/engine => ../engine
