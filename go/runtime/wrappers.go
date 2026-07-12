package ballrt

import (
	"os"
	"runtime/debug"
	"strings"
)

// debugTrace prints a Go stack trace when BALL_DEBUG_STACK is set — used at a
// fail-loud coercion site to locate the compiled-engine caller before the panic
// is re-thrown through the flow-signal recover chain (which erases the origin).
var debugTracing = os.Getenv("BALL_DEBUG_STACK") != ""

func debugTrace() {
	if debugTracing {
		debug.PrintStack()
	}
}

// Value-model wrappers + the runtime class-hierarchy registry.
//
// The self-hosted engine boxes some primitives in its own ball_value.dart
// wrapper classes (BallInt/BallDouble/BallString/BallBool) that carry no typeDef
// in the self-host program — each target provides them natively. The compiler
// maps their single positional constructor argument to a `value` field, so a
// wrapper reaches the runtime as a *Message tagged "…BallDouble" with
// {value: <inner>}. Numeric/string/bool coercions must therefore see through the
// wrapper. Mirrors the Rust "value-wrapper" bucket and C#'s wrapper handling.

// unwrap resolves a value-model wrapper message to its inner scalar, recursively.
// A non-wrapper value is returned unchanged.
func unwrap(v Value) Value {
	m, ok := v.(*Message)
	if !ok {
		return v
	}
	switch messageShortName(m.TypeName) {
	case "BallInt", "BallDouble", "BallString", "BallBool":
		if inner, ok := m.Fields.Get("value"); ok {
			return unwrap(inner)
		}
	}
	return v
}

// messageShortName strips a module/owner prefix from a type name (the part after
// the last ':' or '.').
func messageShortName(name string) string {
	if i := strings.LastIndex(name, ":"); i >= 0 {
		name = name[i+1:]
	}
	if i := strings.LastIndex(name, "."); i >= 0 {
		name = name[i+1:]
	}
	return name
}

// ── Class-hierarchy registry (Dart is/as supertype tests) ───────────────────

// subtypeParents maps a class short name to its declared superclass short name.
// Populated by the compiled program's init (the compiler emits RegisterSubtype
// for every typeDef carrying a metadata.superclass), plus the engine's native
// BallObject extends BallMap edge.
var subtypeParents = map[string]string{
	"BallObject": "BallMap",
}

// RegisterSubtype records that child's superclass is parent (short names). Called
// from the compiled program's init so runtime is/as tests can walk the chain.
func RegisterSubtype(child, parent string) {
	if child != "" && parent != "" {
		subtypeParents[messageShortName(child)] = messageShortName(parent)
	}
}

// messageIsSubtype reports whether the type named fullType (or its superclass
// chain) matches the short supertype name.
func messageIsSubtype(fullType, shortSuper string) bool {
	cur := messageShortName(fullType)
	for i := 0; i < 64; i++ {
		if cur == shortSuper {
			return true
		}
		parent, ok := subtypeParents[cur]
		if !ok {
			return false
		}
		cur = parent
	}
	return false
}
