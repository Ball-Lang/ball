package compiler

import (
	"fmt"
	"go/format"
)

// Format runs gofmt over generated Go source. A formatting error means the
// emitted code is not syntactically valid Go — a compiler bug — so it is
// surfaced (with the raw source) rather than swallowed.
func Format(src string) (string, error) {
	out, err := format.Source([]byte(src))
	if err != nil {
		return src, fmt.Errorf("gofmt failed on generated source (compiler bug): %w", err)
	}
	return string(out), nil
}
