package ballrt

import (
	"fmt"
	"strings"
)

// Compiler-emitted helper surface (epic #426 Phase 4) — the functions the
// self-hosted compiled engine calls that are not plain arithmetic/collection
// ops: argument binding, first-class/method dispatch, receiver weaving, type
// tests, and the fail-loud markers. The Go siblings of the BallRuntime.* helpers
// the C#/Rust compilers emit.

// TypeMarker is a bare type reference used as a static-method receiver
// (int.tryParse) or a type argument (List<int>). It is a first-class Value.
type TypeMarker struct{ Name string }

// TypeLiteral wraps a Dart core type name as a dispatchable value.
func TypeLiteral(name string) Value { return TypeMarker{Name: name} }

// ArgGet reads a parameter from a packed call input: the caller's by-name key
// when present, else the positional argN slot, else null. Used by the
// multi-parameter prologue (invariant #1 packs 2+ args into one message).
func ArgGet(input Value, name, argKey string) Value {
	fields := asFields(input)
	if fields == nil {
		// A lone positional value passed where a name was expected.
		return input
	}
	if v, ok := fields.Get(name); ok {
		return v
	}
	if v, ok := fields.Get(argKey); ok {
		return v
	}
	return nil
}

// CallFunction invokes a first-class function value with a single input.
func CallFunction(fn, input Value) Value { return Call(fn, input) }

// MessageTypeName returns a message's type tag (full name), or "" for a
// non-message value.
func MessageTypeName(v Value) Value {
	if m, ok := v.(*Message); ok {
		return m.TypeName
	}
	return ""
}

// messageShortType returns the short type name of a *Message (after the last
// ':'), or "".
func messageShortType(v Value) string {
	if m, ok := v.(*Message); ok {
		if i := strings.LastIndex(m.TypeName, ":"); i >= 0 {
			return m.TypeName[i+1:]
		}
		return m.TypeName
	}
	return ""
}

// WithSelf merges a receiver into a call's input message, returning it. A null
// input becomes a fresh {self}; a message gains a self field.
func WithSelf(input, self Value) Value {
	m := asFields(input)
	if m == nil {
		m = NewMap()
	}
	m.Set("self", self)
	return m
}

// Arg0WithSelf wraps a single positional argument together with a receiver as
// {self, arg0}.
func Arg0WithSelf(arg, self Value) Value {
	m := NewMap()
	m.Set("self", self)
	m.Set("arg0", arg)
	return m
}

// UnsupportedBaseCall fails loud on an unimplemented external base function
// (issue #55 doctrine — never a silent placeholder).
func UnsupportedBaseCall(module, fn string) Value {
	panic(Thrown{Value: fmt.Sprintf("ball: unsupported base function %s.%s", module, fn)})
}

// UnresolvedReference fails loud on a reference the compiler could not resolve.
func UnresolvedReference(name string) Value {
	panic(Thrown{Value: "ball: unresolved reference " + name})
}

// ToStringValue is the canonical string form of a value (the toString dispatcher
// fallback and std.to_string on a non-overriding receiver).
func ToStringValue(v Value) Value { return ToStr(v) }

// CaughtStackTrace returns the current caught exception's stack trace form. The
// by-value model captures no real trace; return an empty string.
func CaughtStackTrace() Value { return "" }

// SpreadIter yields the elements a list-literal spread (...x) splices.
func SpreadIter(v Value) []Value { return Iterate(v) }

// IndexGet is std.index (target[index]).
func IndexGet(target, index Value) Value { return Index(target, index) }

// IndexSet is target[index] = value.
func IndexSet(target, index, value Value) Value { return SetIndex(target, index, value) }

// ── Type tests (Dart is / as) ───────────────────────────────────────────────

// IsType implements Dart's `v is T` for the type names the engine tests.
func IsType(v Value, typeName string) Value { return isType(v, typeName) }

// IsNotType implements `v is! T`.
func IsNotType(v Value, typeName string) Value { return !isType(v, typeName) }

// AsType implements Dart's `v as T` — an identity cast in the dynamic model
// (the value already carries its runtime type); a failing cast is the caller's
// concern and surfaces at the next operation.
func AsType(v Value, typeName string) Value { return v }

func isType(v Value, typeName string) bool {
	short := typeName
	if i := strings.LastIndex(typeName, ":"); i >= 0 {
		short = typeName[i+1:]
	}
	switch short {
	case "Object", "dynamic":
		return v != nil
	case "Null":
		return v == nil
	case "int":
		_, ok := v.(int64)
		return ok
	case "double":
		_, ok := v.(float64)
		return ok
	case "num":
		return isNum(v)
	case "String":
		_, ok := v.(string)
		return ok
	case "bool":
		_, ok := v.(bool)
		return ok
	case "List":
		_, ok := v.(*List)
		return ok
	case "Iterable":
		if _, ok := v.(*List); ok {
			return true
		}
		_, ok := v.(*Set)
		return ok
	case "Map":
		_, ok := v.(*Map)
		return ok
	case "Set":
		_, ok := v.(*Set)
		return ok
	case "Function":
		_, ok := v.(*Function)
		return ok
	case "Comparable":
		switch v.(type) {
		case int64, float64, string:
			return true
		}
		return false
	}
	// A user message: match on its (short or full) type tag, or a supertype.
	if m, ok := v.(*Message); ok {
		return m.TypeName == typeName || messageShortType(v) == short || messageIsSubtype(m.TypeName, short)
	}
	return false
}
