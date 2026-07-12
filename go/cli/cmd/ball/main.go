// Command ball is the Ball language CLI for the Go toolchain (epic #426 Phase
// 5): a single binary with the four core verbs run / compile / encode / check.
//
//	ball run      <program.ball.json>            execute (self-hosted engine; -tags selfhost)
//	ball compile  <program.ball.json> [-o f.go]  Ball → Go source
//	ball encode   <source.go> [-o f] [-format …] Go → Ball program
//	ball check    <program.ball.json> [-compile] validate without running
//
// The whole implementation lives in package cli so it stays testable in-process;
// this entry point only forwards argv and the process exit code.
package main

import (
	"os"

	cli "github.com/ball-lang/ball/go/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
