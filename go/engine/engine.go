// Package engine is the self-hosted Ball Go engine (epic #426 Phase 4): it runs
// Ball programs by compiling the reference engine (dart/self_host/engine.ball.pb)
// through the Ball → Go compiler into a gitignored compiled_engine.go, then
// driving it with this thin native wrapper. The Go sibling of rust/engine,
// csharp/engine, and ts/engine.
//
// The wrapper supplies what compiled Ball cannot express natively: loading a
// target program and viewing it as the canonical proto3-JSON value the compiled
// engine reads (loader.go), and the ball_proto access-pattern functions it calls
// to inspect that program (in package ballrt). The compiled engine driver lives
// behind the `selfhost` build tag because compiled_engine.go is a gitignored
// build artifact not present in a fresh checkout — a default build stays green
// on the wrapper foundation, exactly like Rust's `self_host` cargo feature and
// C#'s `-p:SelfHost=true` MSBuild property.
package engine

import (
	"errors"

	compiler "github.com/ball-lang/ball/go/compiler"
	ballrt "github.com/ball-lang/ball/go/runtime"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
)

// ErrSelfHostPending is returned by Run in the default build — the compiled
// self-hosted engine driver is only present under the `selfhost` build tag (the
// generated compiled_engine.go is a gitignored build artifact). Build/run with
// `-tags selfhost` after regenerating (see cmd/regen + AGENTS.md).
var ErrSelfHostPending = errors.New(
	"self-hosted engine driver is off in the default build: regenerate " +
		"compiled_engine.go (go run ./cmd/regen) and build with -tags selfhost")

// BallEngine is a loaded Ball program ready to run.
type BallEngine struct {
	Program *ballv1.Program
	view    ballrt.Value
	output  []string
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

// Run executes the program and returns its captured stdout lines. In the default
// build it returns ErrSelfHostPending; under the `selfhost` build tag it drives
// the compiled self-hosted engine.
func (e *BallEngine) Run() ([]string, error) {
	return e.run()
}
