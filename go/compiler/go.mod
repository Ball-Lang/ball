// The Ball → Go compiler: reads a Ball Program protobuf and emits Go source.
//
// Depends on `go/shared` for the generated `ballv1` proto types (the Program it
// walks) and `google.golang.org/protobuf` for proto3-JSON decoding. The Go it
// emits imports `go/runtime` (package ballrt) — the compiler itself does not,
// it only writes `ballrt.*` call strings.
module github.com/ball-lang/ball/go/compiler

go 1.23

require (
	github.com/ball-lang/ball/go/shared v0.0.0
	google.golang.org/protobuf v1.36.11
)

replace github.com/ball-lang/ball/go/shared => ../shared

replace github.com/ball-lang/ball/go/runtime => ../runtime
