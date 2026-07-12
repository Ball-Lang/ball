package cli

import (
	"flag"
	"io"

	compiler "github.com/ball-lang/ball/go/compiler"
)

// cmdCompile implements `ball compile <program.ball.json> [-o out.go]`: load the
// program and compile it to runnable Go source via go/compiler, writing to -o or
// stdout.
//
// The compiler fails loud (issue #55): an unsupported expression shape or base
// function is returned as an error, surfaced here as a parseErr (exit 2), never
// silent bad code. The emitted source is gofmt'd for readability; a formatting
// failure on otherwise-valid output is non-fatal (the raw source is still
// written) — only a real compile error stops the command.
func cmdCompile(args []string, w io.Writer) *cliError {
	const usage = "ball compile <program.ball.json> [-o out.go]"
	fs := flag.NewFlagSet("compile", flag.ContinueOnError)
	out := fs.String("o", "", "write the generated Go source here instead of stdout")
	positionals, cerr := parseCommand(fs, "compile", usage, args)
	if cerr != nil {
		return cerr
	}
	if len(positionals) != 1 {
		return parseErr("compile: expected exactly one program path (usage: %s)", usage)
	}

	prog, cerr := loadProgram(positionals[0])
	if cerr != nil {
		return cerr
	}

	src, compileErr := compiler.Compile(prog)
	if formatted, ferr := compiler.Format(src); ferr == nil {
		src = formatted
	}
	if compileErr != nil {
		return parseErr("compile: %v", compileErr)
	}
	return writeOut(w, *out, []byte(src))
}
