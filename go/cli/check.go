package cli

import (
	"flag"
	"fmt"
	"io"

	compiler "github.com/ball-lang/ball/go/compiler"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// cmdCheck implements `ball check <program.ball.json> [-compile]`: load the
// program and run a battery of structural checks without running it. Mirrors the
// Rust CLI's `check` (rust/cli/src/commands/check.rs) and Dart's `_validate`:
//   - entry_module / entry_function are set and resolve to a real module + func;
//   - every module has a non-empty, unique name;
//   - every non-base function carries a body or metadata (a bodiless, non-base
//     function is malformed — only base functions may omit a body).
//
// With -compile, and only when the structural checks passed, it additionally
// attempts a dry-run go/compiler compile (output discarded) — a stronger,
// Go-target-specific check that catches shapes the structural checks don't, at
// the cost of false positives for a program that is valid Ball but hits a
// documented go/compiler scope gap; hence opt-in.
//
// Any finding is reported as a single parseErr (exit 2) listing every problem;
// success prints a one-line summary to stdout (exit 0).
func cmdCheck(args []string, w io.Writer) *cliError {
	const usage = "ball check <program.ball.json> [-compile]"
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	alsoCompile := fs.Bool("compile", false, "additionally attempt a dry-run compile to Go (stronger, Go-specific check)")
	positionals, cerr := parseCommand(fs, "check", usage, args)
	if cerr != nil {
		return cerr
	}
	if len(positionals) != 1 {
		return parseErr("check: expected exactly one program path (usage: %s)", usage)
	}

	prog, cerr := loadProgram(positionals[0])
	if cerr != nil {
		return cerr
	}

	problems := validateStructure(prog)

	if *alsoCompile && len(problems) == 0 {
		if _, err := compiler.Compile(prog); err != nil {
			problems = append(problems, fmt.Sprintf("does not compile to Go: %v", err))
		}
	}

	if len(problems) > 0 {
		msg := fmt.Sprintf("invalid program: %d error(s) found", len(problems))
		for _, p := range problems {
			msg += "\n  - " + p
		}
		return parseErr("%s", msg)
	}

	fnCount := 0
	for _, m := range prog.GetModules() {
		fnCount += len(m.GetFunctions())
	}
	if werr := printLine(w, fmt.Sprintf("Valid: %q v%s", prog.GetName(), prog.GetVersion())); werr != nil {
		return werr
	}
	return printLine(w, fmt.Sprintf("  %d module(s), %d function(s)", len(prog.GetModules()), fnCount))
}

// validateStructure returns a slice of human-readable findings, empty when the
// program is structurally sound. Split out from cmdCheck so it stays trivially
// unit-testable without a filesystem round trip.
func validateStructure(prog *ballv1.Program) []string {
	var problems []string

	entryMod := prog.GetEntryModule()
	entryFn := prog.GetEntryFunction()
	if entryMod == "" {
		problems = append(problems, "missing entry_module")
	}
	if entryFn == "" {
		problems = append(problems, "missing entry_function")
	}
	if entryMod != "" && entryFn != "" {
		var found *ballv1.Module
		for _, m := range prog.GetModules() {
			if m.GetName() == entryMod {
				found = m
				break
			}
		}
		if found == nil {
			problems = append(problems, fmt.Sprintf("entry module %q not found in modules", entryMod))
		} else {
			hasFn := false
			for _, f := range found.GetFunctions() {
				if f.GetName() == entryFn {
					hasFn = true
					break
				}
			}
			if !hasFn {
				problems = append(problems, fmt.Sprintf("entry function %q not found in module %q", entryFn, entryMod))
			}
		}
	}

	seen := make(map[string]bool)
	for i, m := range prog.GetModules() {
		name := m.GetName()
		if name == "" {
			problems = append(problems, fmt.Sprintf("module at index %d has no name", i))
			continue
		}
		if seen[name] {
			problems = append(problems, fmt.Sprintf("duplicate module name: %q", name))
		}
		seen[name] = true
	}

	for _, m := range prog.GetModules() {
		for _, f := range m.GetFunctions() {
			if !f.GetIsBase() && f.GetBody() == nil && f.GetMetadata() == nil {
				problems = append(problems, fmt.Sprintf("%s.%s: non-base function with no body or metadata", m.GetName(), f.GetName()))
			}
		}
	}

	return problems
}
