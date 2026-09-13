// Package engine is the self-hosted Ball Go engine (epic #426 Phase 4): it runs
// Ball programs by compiling the reference engine (dart/self_host/engine.ball.pb)
// through the Ball → Go compiler into compiled/compiled_engine.go, then driving
// it with this thin native wrapper. The Go sibling of rust/engine,
// csharp/engine, and ts/engine.
//
// The wrapper supplies what compiled Ball cannot express natively: loading a
// target program and viewing it as the canonical proto3-JSON value the compiled
// engine reads (loader.go), and the ball_proto access-pattern functions it calls
// to inspect that program (in package ballrt).
//
// compiled/compiled_engine.go is a TRACKED generated artifact (issue #586), and
// the driver carries no build constraint: `go install` accepts no `-tags`, so
// the engine a registry consumer receives has to be in the module at the tag.
// Regenerate it with `go run ./cmd/regen` — `Ball Artifact Freshness` in CI
// regenerates and diffs it, exactly as it does ts/engine's compiled_engine.ts.
package engine

import (
	compiler "github.com/ball-lang/ball/go/compiler"
	compiled "github.com/ball-lang/ball/go/engine/compiled"
	ballrt "github.com/ball-lang/ball/go/runtime"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
)

// BallEngine is a loaded Ball program ready to run.
type BallEngine struct {
	Program *ballv1.Program

	// TimeoutMs, when > 0, bounds execution via the compiled engine's
	// cooperative execution-timeout guard (checked on every expression eval): a
	// runaway program self-aborts with an "Execution timeout exceeded" error
	// instead of spinning forever, so the driver goroutine exits (Go cannot kill
	// a goroutine — issue #436). 0 (the default) leaves execution unbounded. Set
	// it before calling Run.
	TimeoutMs int64

	view   ballrt.Value
	output []string
}

// FromJSON loads a program from proto3-JSON .ball.json source (the @type Any
// envelope is stripped) plus its canonical BallValue view.
func FromJSON(data []byte) (*BallEngine, error) {
	program, err := compiler.LoadProgramJSON(data)
	if err != nil {
		return nil, err
	}
	return newEngine(program)
}

// FromBinary loads a program from binary protobuf .ball.pb bytes (a
// google.protobuf.Any envelope wrapping the ball.v1.Program).
func FromBinary(data []byte) (*BallEngine, error) {
	// Prefer the Any-wrapped shape (the CLI/self-host canonical binary form);
	// fall back to a bare Program for a plainly-marshaled input.
	var any anypb.Any
	if err := proto.Unmarshal(data, &any); err == nil {
		var program ballv1.Program
		if err := any.UnmarshalTo(&program); err == nil {
			return newEngine(&program)
		}
	}
	program, err := compiler.LoadProgramBinary(data)
	if err != nil {
		return nil, err
	}
	return newEngine(program)
}

func newEngine(program *ballv1.Program) (*BallEngine, error) {
	view, err := buildView(program)
	if err != nil {
		return nil, err
	}
	return &BallEngine{Program: program, view: view}, nil
}

// ProgramValue returns the loaded program's canonical proto3-JSON BallValue
// view — the exact tree the compiled self-hosted engine reads, and the input
// every compiled cli_core report function takes (issue #570).
//
// Exported so go/cli's info/validate/tree verbs can hand the view to the
// compiled CLI core without rebuilding it (the Go analog of rust/engine's
// `program_value()`, which rust/cli's cli-core commands call). The returned tree
// is the engine's own — treat it as read-only.
func (e *BallEngine) ProgramValue() ballrt.Value { return e.view }

// Run executes the program through the compiled self-hosted engine and returns
// its captured stdout lines: the compiled engine's BallEngine constructor + run
// method, fed this program's view and an stdout callback capturing into
// e.output. Mirrors rust/engine's run_self_hosted and csharp/engine's
// RunSelfHosted.
func (e *BallEngine) Run() ([]string, error) {
	e.output = e.output[:0]
	if err := compiled.RunProgram(e.view, func(line string) {
		e.output = append(e.output, line)
	}, e.TimeoutMs); err != nil {
		return e.output, err
	}
	return e.output, nil
}
