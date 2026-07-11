// Command ballgoc compiles a Ball program (.ball.json / .ball.bin) to Go source.
//
// Usage:
//
//	ballgoc <input.ball.json> [-o output.go]
//
// This is the Phase-2 compiler front-end (Ball → Go). The full `ball` CLI
// (run/compile/encode/check) is a later phase; this thin command exists so the
// compiler can be exercised from the shell and by tooling.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/ball-lang/ball/go/compiler"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

func main() {
	out := flag.String("o", "", "output Go file (default: stdout)")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: ballgoc <input.ball.json> [-o output.go]")
		os.Exit(2)
	}

	prog, err := loadAny(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, "load:", err)
		os.Exit(3)
	}

	src, cerr := compiler.Compile(prog)
	// Format even on compile error so the emitted Go stays readable; the compile
	// error (an unsupported construct) is still fatal.
	if formatted, ferr := compiler.Format(src); ferr == nil {
		src = formatted
	}
	if cerr != nil {
		fmt.Fprintln(os.Stderr, "compile:", cerr)
		os.Exit(2)
	}

	if *out == "" {
		fmt.Print(src)
		return
	}
	if err := os.WriteFile(*out, []byte(src), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		os.Exit(3)
	}
}

func loadAny(path string) (*ballv1.Program, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if strings.HasSuffix(path, ".bin") || strings.HasSuffix(path, ".pb") {
		return compiler.LoadProgramBinary(data)
	}
	return compiler.LoadProgramJSON(data)
}
