package cli

import (
	"fmt"
	"io"
	"os"
)

// writeOut writes content to the file at outPath, or to w (the command's stdout
// writer) when outPath is empty. Shared by `compile` (Go source) and `encode`
// (JSON text or binary bytes). No trailing newline is added beyond what content
// already carries.
func writeOut(w io.Writer, outPath string, content []byte) *cliError {
	if outPath == "" {
		if _, err := w.Write(content); err != nil {
			return ioErr("could not write to stdout: %v", err)
		}
		return nil
	}
	if err := os.WriteFile(outPath, content, 0o644); err != nil {
		return ioErr("could not write %s: %v", outPath, err)
	}
	return nil
}

// printLine writes a single line plus a newline to w, surfacing a write failure
// as an I/O error (exit 3) rather than swallowing it.
func printLine(w io.Writer, line string) *cliError {
	if _, err := fmt.Fprintln(w, line); err != nil {
		return ioErr("could not write to stdout: %v", err)
	}
	return nil
}
