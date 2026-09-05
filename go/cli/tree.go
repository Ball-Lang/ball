package cli

import (
	"flag"
	"io"

	ballrt "github.com/ball-lang/ball/go/runtime"
)

// cmdTree implements `ball tree <program.ball.json>` (issue #570): print the
// program's module/import tree.
//
// Like `info`, the report comes from the self-hosted CLI core
// (cli_core.treeReport), so it is byte-identical to the Dart CLI's `tree`. The
// Go sibling of rust/cli/src/commands/tree.rs.
func cmdTree(args []string, w io.Writer) *cliError {
	const usage = "ball tree <program.ball.json>"
	view, cerr := loadCliCoreView("tree", usage, flag.NewFlagSet("tree", flag.ContinueOnError), args)
	if cerr != nil {
		return cerr
	}
	report, cerr := cliCoreTree(view)
	if cerr != nil {
		return cerr
	}
	return printLine(w, report)
}

// loadCliCoreView parses the single program-path positional every cli-core verb
// takes and returns the program's canonical proto3-JSON view — the input the
// compiled report functions consume.
//
// Loading happens BEFORE the cli-core availability check on purpose (see
// cmdInfo's doc comment): an unreadable file or a malformed program must report
// its own I/O (3) / parse (2) failure rather than being masked by the build-tag
// message, which is exactly what rust/cli's `let _engine = load_engine(path)?;`
// does in its `#[cfg(not(feature = "cli_core"))]` arms.
func loadCliCoreView(name, usage string, fs *flag.FlagSet, args []string) (view ballrt.Value, cerr *cliError) {
	positionals, cerr := parseCommand(fs, name, usage, args)
	if cerr != nil {
		return nil, cerr
	}
	if len(positionals) != 1 {
		return nil, parseErr("%s: expected exactly one program path (usage: %s)", name, usage)
	}
	eng, cerr := loadEngine(positionals[0])
	if cerr != nil {
		return nil, cerr
	}
	return eng.ProgramValue(), nil
}
