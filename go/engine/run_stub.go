//go:build !selfhost

package engine

// run (default build) — the compiled self-hosted engine driver is not compiled
// in. Returns ErrSelfHostPending; the loader, the program view, and the
// ball_proto access patterns the wrapper provides are still exercised by the
// wrapper's own tests. The C# analog of BallEngine.Run throwing
// SelfHostPendingException without -p:SelfHost=true.
func (e *BallEngine) run() ([]string, error) {
	return nil, ErrSelfHostPending
}
