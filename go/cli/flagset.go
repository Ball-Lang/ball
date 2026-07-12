package cli

import (
	"flag"
	"io"
)

// parseCommand parses args against fs, allowing flags to appear before, after,
// or interspersed with the positional arguments. Go's flag package alone stops
// at the first positional (so `encode source.go -o out` would treat `-o out` as
// positionals); this repeatedly re-parses the tail after each positional to
// recover the ergonomics the Rust/C# CLIs get from clap/System.CommandLine.
//
// It returns the collected positionals. A flag syntax error (unknown flag,
// missing value) becomes a parseErr (exit 2) tagged with the command name and
// its usage line. fs must be a flag.ContinueOnError set; its output/usage are
// silenced so the caller controls all diagnostics.
func parseCommand(fs *flag.FlagSet, name, usage string, args []string) ([]string, *cliError) {
	fs.SetOutput(io.Discard)
	fs.Usage = func() {}

	var positionals []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, parseErr("%s: %v (usage: %s)", name, err, usage)
		}
		if fs.NArg() == 0 {
			break
		}
		positionals = append(positionals, fs.Arg(0))
		args = fs.Args()[1:]
	}
	return positionals, nil
}
