//go:build selfhost

package compiled

import (
	"fmt"
	"os"
	"runtime/debug"

	ballrt "github.com/ball-lang/ball/go/runtime"
)

// debugStack, when the BALL_DEBUG_STACK env var is set, appends a Go stack trace
// to a run failure so a compiled-engine panic can be located.
var debugStack = os.Getenv("BALL_DEBUG_STACK") != ""

// RunProgram drives the compiled self-hosted engine (epic #426 Phase 4): it
// builds the 16-field BallEngine constructor input (the program view, an stdout
// callback capturing each printed line, permissive limits, and a
// StdModuleHandler), constructs the engine via its compiled constructor, then
// calls the compiled instance `run`. Mirrors csharp/engine's RunSelfHosted and
// rust/engine's run_self_hosted.
//
// timeoutMs, when > 0, drives the compiled engine's cooperative
// execution-timeout guard (dart/engine/lib/engine.dart's
// `_checkExecutionTimeout`, run on every expression eval): a FLAT-STACK runaway
// (an infinite while/for) self-aborts with an "Execution timeout exceeded"
// BallRuntimeError once it has run that long, so the goroutine below exits
// instead of spinning forever (Go cannot kill a goroutine — issue #436).
// Unbounded-stack Ball RECURSION is NOT reliably stopped by this guard — it was
// observed to keep recursing past the budget, surfacing only via the runner's
// select backstop while its goroutine leaks, and it risks a fatal Go stack
// overflow under the 1 GiB SetMaxStack ceiling below (see
// conformance/runner.go). 0 leaves execution unbounded (the CLI's behavior).
//
// The compiled engine is a deep tree-walker whose methods each carry a large
// frame (hundreds of field-alias locals), so the recursion budget is lifted well
// past the default. Runs on its own goroutine so a Ball throw / flow signal that
// escapes is recovered as an error rather than crashing the process.
func RunProgram(view ballrt.Value, stdout func(string), timeoutMs int64) (err error) {
	debug.SetMaxStack(1 << 30) // 1 GiB — deep tree-walk-on-tree-walk frames.

	done := make(chan struct{})
	go func() {
		defer close(done)
		if !debugStack {
			// In the normal path, recover a Ball throw / flow signal that escaped
			// as an error. In debug mode, let it crash so Go prints the full
			// panic-origin stack (locating the compiled-engine line).
			defer func() {
				if r := recover(); r != nil {
					err = fmt.Errorf("self-hosted engine did not complete: %v", panicMessage(r))
				}
			}()
		}

		stdoutFn := ballrt.Fn("stdout", func(msg ballrt.Value) ballrt.Value {
			stdout(ballrt.ToStr(msg))
			return nil
		})

		ctor := ballrt.NewMap()
		ctor.Set("program", view)
		ctor.Set("stdout", stdoutFn)
		ctor.Set("stderr", nil)
		ctor.Set("stdinReader", nil)
		ctor.Set("envGet", nil)
		ctor.Set("args", ballrt.NewList())
		ctor.Set("enableProfiling", false)
		ctor.Set("maxRecursionDepth", int64(1000000))
		if timeoutMs > 0 {
			ctor.Set("timeoutMs", timeoutMs)
		} else {
			ctor.Set("timeoutMs", nil)
		}
		ctor.Set("maxMemoryBytes", nil)
		ctor.Set("maxModules", int64(1000000))
		ctor.Set("maxExpressionDepth", int64(1000000))
		ctor.Set("maxProgramSizeBytes", nil)
		ctor.Set("sandbox", false)
		ctor.Set("moduleHandlers", ballrt.NewList(stdModuleHandler()))
		ctor.Set("resolver", nil)

		engine := BallEngine__new(ctor)

		runInput := ballrt.NewMap()
		runInput.Set("self", engine)
		run(runInput)
	}()
	<-done
	return err
}

// stdModuleHandler builds the engine's StdModuleHandler with its field-level
// defaults (the constructor's `moduleHandlers ?? [StdModuleHandler()]` default
// is a cosmetic initializer the compiler does not evaluate, so the wrapper
// supplies the handler; the engine's own `for (h in moduleHandlers) h.init(this)`
// then populates its dispatch). Mirrors csharp/engine's RunSelfHosted.
func stdModuleHandler() ballrt.Value {
	fields := ballrt.NewMap()
	fields.Set("_dispatch", ballrt.NewMap())
	fields.Set("_composedDispatch", ballrt.NewMap())
	fields.Set("_tombstones", ballrt.NewList())
	fields.Set("_allowlist", nil)
	return ballrt.NewMessage("main:StdModuleHandler", fields)
}

func panicMessage(r any) string {
	if t, ok := r.(ballrt.Thrown); ok {
		// A thrown Ball error object (e.g. main:BallRuntimeError) carries its
		// human-readable text in a `message` field; surface it when present. A
		// plainly-thrown string/value is stringified directly.
		if msg := errorMessageField(t.Value); msg != "" {
			return "Ball exception: " + msg
		}
		return "Ball exception: " + ballrt.ToStr(t.Value)
	}
	return fmt.Sprintf("%v", r)
}

// errorMessageField reads a "message" field off a thrown map/message, or "".
func errorMessageField(v ballrt.Value) string {
	switch v.(type) {
	case *ballrt.Map, *ballrt.Message:
		if msg := ballrt.FieldGet(v, "message"); msg != nil {
			return ballrt.ToStr(msg)
		}
	}
	return ""
}
