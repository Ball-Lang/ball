//go:build selfhost

package engine

import (
	compiled "github.com/ball-lang/ball/go/engine/compiled"
)

// run (selfhost build) drives the compiled self-hosted engine: the compiled
// engine's BallEngine constructor + run method, fed this program's view and an
// stdout callback capturing into e.output. Mirrors rust/engine's run_self_hosted
// and csharp/engine's RunSelfHosted.
func (e *BallEngine) run() ([]string, error) {
	e.output = e.output[:0]
	if err := compiled.RunProgram(e.view, func(line string) {
		e.output = append(e.output, line)
	}, e.TimeoutMs); err != nil {
		return e.output, err
	}
	return e.output, nil
}
