package cli

import (
	"os"
	"strings"

	compiler "github.com/ball-lang/ball/go/compiler"
	engine "github.com/ball-lang/ball/go/engine"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
)

// isBinaryPath reports whether path names a binary-protobuf Ball program by its
// extension (.bin / .pb) rather than proto3-JSON (.ball.json / .json / no
// extension). Mirrors the Dart/Rust/Go loaders' extension sniff.
func isBinaryPath(path string) bool {
	return strings.HasSuffix(path, ".bin") || strings.HasSuffix(path, ".pb")
}

// loadEngine loads a program from path into a *engine.BallEngine, ready for
// `run`. I/O failures become an ioErr (exit 3); an undecodable program a
// parseErr (exit 2). The engine's own loaders (FromJSON strips the @type Any
// envelope; FromBinary prefers the Any-wrapped canonical form, falling back to
// a bare Program) do the format work.
func loadEngine(path string) (*engine.BallEngine, *cliError) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, ioErr("could not read %s: %v", path, err)
	}
	var (
		eng  *engine.BallEngine
		derr error
	)
	if isBinaryPath(path) {
		eng, derr = engine.FromBinary(data)
	} else {
		eng, derr = engine.FromJSON(data)
	}
	if derr != nil {
		return nil, parseErr("could not load %s: %v", path, derr)
	}
	return eng, nil
}

// loadProgram loads the typed ball.v1.Program from path for the verbs that only
// need to inspect/compile it (`compile`, `check`) — no engine view is built.
// Same format sniff and error mapping as loadEngine.
func loadProgram(path string) (*ballv1.Program, *cliError) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, ioErr("could not read %s: %v", path, err)
	}
	var (
		prog *ballv1.Program
		derr error
	)
	if isBinaryPath(path) {
		prog, derr = decodeBinaryProgram(data)
	} else {
		prog, derr = compiler.LoadProgramJSON(data)
	}
	if derr != nil {
		return nil, parseErr("could not load %s: %v", path, derr)
	}
	return prog, nil
}

// decodeBinaryProgram decodes .ball.bin / .ball.pb bytes: it prefers the
// Any-wrapped canonical form the Go pipeline emits (see serialize.go), falling
// back to a bare Program — the same order engine.FromBinary uses.
func decodeBinaryProgram(data []byte) (*ballv1.Program, error) {
	var envelope anypb.Any
	if err := proto.Unmarshal(data, &envelope); err == nil {
		var prog ballv1.Program
		if err := envelope.UnmarshalTo(&prog); err == nil {
			return &prog, nil
		}
	}
	return compiler.LoadProgramBinary(data)
}
