// Package conformance drives the self-hosted Go engine over the whole
// tests/conformance corpus and diffs each fixture's stdout against its golden
// (epic #426 Phase 4) — the same corpus, comparison, and carve-out handling as
// the Dart/Rust/C#/C++ runners, so a pass here is Dart-identical output.
//
// Nothing here is build-tag-gated: since #586 compiled/compiled_engine.go is a
// committed artifact, so a plain `go test ./conformance/` in a fresh checkout
// runs the real sweep. Use `go test -v` — without it `go test` caches and
// discards a passing test's stdout, and the `Results:` line CI parses is a plain
// fmt.Printf.
package conformance
