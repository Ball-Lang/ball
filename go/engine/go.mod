// The self-hosted Ball Go engine (Phase 4 of epic #426): runs Ball programs by
// compiling the reference engine (dart/self_host/engine.ball.pb) through the Go
// compiler into a gitignored compiled_engine.go, then driving it with a thin
// native wrapper. The Go sibling of rust/engine, csharp/engine, ts/engine.
//
// Depends on go/shared for the proto types, go/runtime (ballrt) for the value
// model + base-op helpers the compiled engine calls, go/compiler for the
// regeneration tool, and go/encoder for the conformance round-trip leg
// (conformance/roundtrip.go). The compiled engine artifact lives under compiled/
// and is built only under the `selfhost` build tag (see engine/AGENTS.md).
module github.com/ball-lang/ball/go/engine

go 1.23

require (
	github.com/ball-lang/ball/go/compiler v0.1.0
	github.com/ball-lang/ball/go/encoder v0.1.0
	github.com/ball-lang/ball/go/runtime v0.1.0
	github.com/ball-lang/ball/go/shared v0.1.0
	google.golang.org/protobuf v1.36.11
)
