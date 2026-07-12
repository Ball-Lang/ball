// Package compiled holds the self-hosted Ball engine compiled from
// dart/self_host/engine.ball.pb through the Ball → Go compiler (epic #426
// Phase 4).
//
// The generated compiled_engine.go is a gitignored build artifact (regenerated
// by `go run ./cmd/regen`, mirroring rust/engine's compiled_engine.rs and
// csharp/engine's CompiledEngine.cs). Both it and the hand-written driver.go are
// behind the `selfhost` build tag, so on a fresh checkout — where
// compiled_engine.go is absent — this package is just this doc file and a
// default `go build ./...` stays green.
package compiled
