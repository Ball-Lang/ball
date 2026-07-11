// The Go → Ball encoder (Phase 3 of epic #426): parses Go source with the
// standard library's `go/parser` + `go/ast` + `go/token` and walks the AST,
// emitting a Ball `Program` protobuf whose every construct routes through the
// universal `std` base module (no `go_std` — mirrors the Rust encoder's
// "no rust_std" invariant).
//
// Depends on `go/shared` for the generated `ballv1` proto types it builds, and
// (test-only, for the round-trip conformance proof) on `go/compiler` to compile
// the encoded Ball back to Go and `go run` it. The Go runtime the compiled
// output imports (`go/runtime`) is wired by the round-trip test's throwaway
// module via a local `replace`, so it is not a direct dependency here.
module github.com/ball-lang/ball/go/encoder

go 1.23

require (
	github.com/ball-lang/ball/go/compiler v0.0.0
	github.com/ball-lang/ball/go/shared v0.0.0
	google.golang.org/protobuf v1.36.11
)

replace github.com/ball-lang/ball/go/shared => ../shared

replace github.com/ball-lang/ball/go/compiler => ../compiler

replace github.com/ball-lang/ball/go/runtime => ../runtime
