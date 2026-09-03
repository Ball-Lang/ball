// The Go Tier A coverage-study harness (issue #493).
//
// DELIBERATELY OUTSIDE go/ AND OUT OF go/go.work. The six modules under go/ are
// published module paths (go/<module>/v0.1.0 tags) and `tools/go-module-proxy/
// smoke.sh` sweeps `go/*/` building each one standalone off a synthesized
// proxy — a seventh module there would become a seventh thing to tag and
// publish. This is an internal measuring instrument, not a shipped module, so
// it lives here with plain `replace` directives (which `go install` rejects,
// and which is exactly why no published module may carry them).
module github.com/ball-lang/ball/tools/coverage-study

go 1.23

require (
	github.com/ball-lang/ball/go/compiler v0.1.0
	github.com/ball-lang/ball/go/encoder v0.1.0
	github.com/ball-lang/ball/go/shared v0.1.0
	google.golang.org/protobuf v1.36.11
)

replace (
	github.com/ball-lang/ball/go/compiler => ../../../go/compiler
	github.com/ball-lang/ball/go/encoder => ../../../go/encoder
	github.com/ball-lang/ball/go/runtime => ../../../go/runtime
	github.com/ball-lang/ball/go/shared => ../../../go/shared
)
