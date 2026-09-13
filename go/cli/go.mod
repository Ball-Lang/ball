// The `ball` CLI (epic #426 Phase 5): a single binary with the four core verbs
// run / compile / encode / check over the Go engine, compiler, and encoder.
//
// Depends on go/engine (run), go/compiler (compile + the cli-core regenerator),
// go/encoder (encode), and go/shared (the ballv1 proto types) plus
// google.golang.org/protobuf for the Any/proto3-JSON (de)serialization `encode`
// and the loaders need. go/runtime (ballrt) is a DIRECT dependency since issue
// #570: the cli-core verbs pass the program's ballrt.Value view to the compiled
// report functions.
//
// NO build tags (issue #586). Go's registry IS the git tag: the module proxy
// serves the repository AT the tag and `go install` accepts no `-tags`, so a
// gitignored, tag-gated artifact can never reach a consumer. Both generated
// artifacts — go/cli/compiled/compiled_cli.go (the cli-core verbs
// info/validate/tree/version) and go/engine/compiled/compiled_engine.go (which
// `run` executes through) — are therefore COMMITTED and unconditional, kept
// honest by ci.yml's `Ball Artifact Freshness` regen-and-diff job. Rust and C#
// keep their `self_host`/`cli_core` gates only because crates.io and NuGet
// regenerate at publish time; Go has no such step.
module github.com/ball-lang/ball/go/cli

go 1.23

require (
	github.com/ball-lang/ball/go/compiler v0.2.0
	github.com/ball-lang/ball/go/encoder v0.2.0
	github.com/ball-lang/ball/go/engine v0.2.0
	github.com/ball-lang/ball/go/runtime v0.2.0
	github.com/ball-lang/ball/go/shared v0.2.0
	google.golang.org/protobuf v1.36.11
)
