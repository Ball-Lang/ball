// Package conformance drives the self-hosted Go engine over the whole
// tests/conformance corpus and diffs each fixture's stdout against its golden
// (epic #426 Phase 4) — the same corpus, comparison, and carve-out handling as
// the Dart/Rust/C#/C++ runners, so a pass here is Dart-identical output.
//
// The runner + its test live behind the `selfhost` build tag (they need the
// generated, gitignored compiled_engine.go). This untagged file keeps the
// package non-empty so a fresh checkout's plain `go build ./...` / `go test
// ./...` stays green without the compiled engine.
package conformance
