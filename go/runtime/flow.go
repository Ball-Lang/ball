package ballrt

import (
	"fmt"
	"os"
)

// Flow signals model Ball's non-local control flow (return / break / continue)
// the same way every reference engine does — as objects that propagate up the
// call stack (Dart's FlowSignal, the engines' break/continue values). Here they
// travel as Go panics so they cross the immediately-invoked-function-expression
// (IIFE) boundaries the compiler emits for blocks and control flow: Go has no
// block/if/loop *expressions*, so a block compiles to `func() Value { … }()`,
// and a bare `return`/`break`/`continue` keyword cannot escape that closure.
// Panicking a flow signal and recovering it at the right frame (a function
// wrapper for return, a loop for break/continue) is the portable equivalent.
//
// Native control flow stays native: `if`/`for`/`while` compile to real Go
// `if`/`for`, evaluated lazily (only the taken branch / next iteration runs).
// Only the *jump* is a signal.

type flowKind int

const (
	flowReturn flowKind = iota
	flowBreak
	flowContinue
)

// flowSignal is a return/break/continue in flight. label is the empty string for
// an unlabeled break/continue; value carries a return's payload.
type flowSignal struct {
	kind  flowKind
	label string
	value Value
}

// Thrown is a Ball exception in flight (std.throw). Caught by TryCatch and, at
// the top level, by RunEntry (which reports it and exits non-zero).
type Thrown struct {
	Value Value
}

func (t Thrown) Error() string { return "Ball exception: " + ToStr(t.Value) }

// dartError throws a Ball exception whose runtime type is typeName (e.g.
// "FormatException", "RangeError") so the engine's typed `on T catch` clauses —
// which match on the thrown value's runtimeType (engine_control_flow.dart's
// _evalLazyTry) — can catch it. A raw `panic("...")` (a Go string) escapes the
// engine's Dart-try→ballrt.TryCatch recover entirely, and even a Thrown with a
// plain-string value reports runtimeType "String", matching no typed clause.
func dartError(typeName, message string) {
	fields := NewMap()
	fields.Set("message", message)
	panic(Thrown{Value: &Message{TypeName: typeName, Fields: fields}})
}

// Return implements std.return: unwind to the enclosing function wrapper,
// yielding v. Typed as Value so it fits any expression position the compiler
// emits it in; it never actually returns (it panics).
func Return(v Value) Value { panic(flowSignal{kind: flowReturn, value: v}) }

// Break implements std.break (label "" for an unlabeled break).
func Break(label string) Value { panic(flowSignal{kind: flowBreak, label: label}) }

// Continue implements std.continue.
func Continue(label string) Value { panic(flowSignal{kind: flowContinue, label: label}) }

// Throw implements std.throw.
func Throw(v Value) Value {
	debugTrace()
	panic(Thrown{Value: v})
}

// CatchReturn is deferred at the top of every compiled function body. If the
// body unwinds with a std.return, it captures the returned value into the
// function's named return slot; any other panic (a break/continue that escaped
// its loop — a malformed program — or a Ball exception) propagates unchanged.
func CatchReturn(out *Value) {
	if r := recover(); r != nil {
		if fs, ok := r.(flowSignal); ok && fs.kind == flowReturn {
			*out = fs.value
			return
		}
		panic(r)
	}
}

// RunLoopBody runs one iteration body for a compiled loop and reports whether
// the loop should break. It recovers a break/continue whose label is empty
// (unlabeled — targets the innermost loop) or matches this loop's label;
// break → returns true, continue → returns false. Any other signal (a return, a
// labeled jump targeting an *outer* loop, or a Ball exception) is re-panicked so
// it reaches its own frame.
func RunLoopBody(label string, body func()) (brk bool) {
	defer func() {
		if r := recover(); r != nil {
			if fs, ok := r.(flowSignal); ok && (fs.label == "" || fs.label == label) {
				switch fs.kind {
				case flowBreak:
					brk = true
					return
				case flowContinue:
					brk = false
					return
				}
			}
			panic(r)
		}
	}()
	body()
	return false
}

// activeExceptions is the stack of exceptions currently being handled, so
// std.rethrow can re-raise the innermost caught one. The engine runs on a single
// goroutine, so a package-level stack is sufficient.
var activeExceptions []Value

// TryCatch implements std.try. It runs body; if a Ball exception unwinds it and
// catch is non-nil, catch is invoked with the thrown value. finally (if
// non-nil) always runs. A return/break/continue that unwinds body still runs
// finally, then continues unwinding (Dart semantics).
func TryCatch(body func() Value, catch func(Value) Value, finally func()) (result Value) {
	if finally != nil {
		defer finally()
	}
	defer func() {
		if r := recover(); r != nil {
			if t, ok := r.(Thrown); ok && catch != nil {
				activeExceptions = append(activeExceptions, t.Value)
				defer func() { activeExceptions = activeExceptions[:len(activeExceptions)-1] }()
				result = catch(t.Value)
				return
			}
			panic(r)
		}
	}()
	return body()
}

// Rethrow re-raises the innermost exception currently being handled (std.rethrow).
func Rethrow() Value {
	if len(activeExceptions) == 0 {
		panic(Thrown{Value: "Bad state: rethrow outside of catch"})
	}
	panic(Thrown{Value: activeExceptions[len(activeExceptions)-1]})
}

// Assert implements std.assert: on a falsy condition, throw an AssertionError
// carrying the message (Dart's `dart run` runs with asserts enabled).
func Assert(condition, message Value) Value {
	if !Truthy(condition) {
		msg := "assertion failed"
		if message != nil {
			msg = "Assertion failed: " + ToStr(message)
		}
		panic(Thrown{Value: msg})
	}
	return nil
}

// RunBody runs a constructor/void body, recovering a std.return that unwinds it
// (its value discarded — a constructor implicitly returns its instance, a void
// body returns nothing). Any other signal (break/continue that escaped, or a
// Ball exception) propagates unchanged.
func RunBody(fn func() Value) {
	defer func() {
		if r := recover(); r != nil {
			if fs, ok := r.(flowSignal); ok && fs.kind == flowReturn {
				return
			}
			panic(r)
		}
	}()
	fn()
}

// RunEntry executes a program's entry function body. A top-level std.return is
// swallowed (the program simply ends); an uncaught Ball exception is reported to
// stderr and the process exits with status 1 (matching the reference engines'
// fail-loud behavior).
func RunEntry(body func() Value) {
	defer func() {
		if r := recover(); r != nil {
			if fs, ok := r.(flowSignal); ok && fs.kind == flowReturn {
				return
			}
			if t, ok := r.(Thrown); ok {
				fmt.Fprintln(os.Stderr, "Unhandled exception: "+ToStr(t.Value))
				os.Exit(1)
			}
			panic(r)
		}
	}()
	body()
}

// ── Field / index access & mutation ─────────────────────────────────────────

// FieldGet implements a field read (`object.field`). A message/map returns the
// stored field (or a virtual property, or null when absent — Dart's dynamic-map
// behavior); a native value (list/string/set/…) resolves a virtual property
// (.length/.first/…). A field access on a value with no such field or property
// fails loud.
func FieldGet(object Value, field string) Value {
	switch o := object.(type) {
	case *Message:
		if v, ok := o.Fields.Get(field); ok {
			return v
		}
		if alias := fieldGetterAlias(field); alias != "" {
			if v, ok := o.Fields.Get(alias); ok {
				return v
			}
		}
		// `.runtimeType`/`.hashCode` resolve against the MESSAGE (its type name),
		// not its field map — else `e.runtimeType` on a thrown FormatException
		// yielded "Map" (the field map's type) and no `on T catch` clause matched.
		if vp, ok := VirtualProperty(object, field); ok {
			return vp
		}
		if vp, ok := VirtualProperty(o.Fields, field); ok {
			return vp
		}
		return nil
	case *Map:
		if v, ok := o.Get(field); ok {
			return v
		}
		if alias := fieldGetterAlias(field); alias != "" {
			if v, ok := o.Get(alias); ok {
				return v
			}
		}
		if vp, ok := VirtualProperty(o, field); ok {
			return vp
		}
		return nil
	}
	if vp, ok := VirtualProperty(object, field); ok {
		return vp
	}
	panic(fmt.Sprintf("ball: field access .%s on non-message %T", field, object))
}

// fieldGetterAlias maps a Dart-protobuf-renamed getter to the canonical
// proto3-JSON field name the engine loader's view uses. The Dart protobuf
// codegen renames a getter that would collide with an Object member
// (`FieldAccess.field` → `.field_2`, `TypeDefinition.descriptor` → `.descriptor_`),
// and the engine reads the program through those getters; the view keys them by
// the plain jsonName. Mirrors rust/shared/src/runtime.rs's field_2→field alias.
func fieldGetterAlias(field string) string {
	switch field {
	case "field_2":
		return "field"
	case "descriptor_":
		return "descriptor"
	}
	return ""
}

// FieldSet implements a field write (`object.field = value`). Returns value.
func FieldSet(object Value, field string, value Value) Value {
	switch o := object.(type) {
	case *Message:
		o.Fields.Set(field, value)
	case *Map:
		o.Set(field, value)
	default:
		panic(fmt.Sprintf("ball: field set .%s on non-message %T", field, object))
	}
	return value
}

// Index implements std.index (`target[index]`) for lists, maps, and strings.
func Index(target, index Value) Value {
	switch t := target.(type) {
	case *List:
		i := int(asFloat(index))
		if i < 0 || i >= len(t.Items) {
			dartError("RangeError", fmt.Sprintf("Index out of range: index should be less than %d: %d", len(t.Items), i))
		}
		return t.Items[i]
	case *Map:
		k := ToStr(index)
		v, _ := t.Get(k)
		return v
	case string:
		i := int(asFloat(index))
		r := []rune(t)
		if i < 0 || i >= len(r) {
			dartError("RangeError", fmt.Sprintf("Index out of range: %d", i))
		}
		return string(r[i])
	}
	panic(fmt.Sprintf("ball: indexing unsupported target %T", target))
}

// SetIndex implements `target[index] = value`. Returns value.
func SetIndex(target, index, value Value) Value {
	switch t := target.(type) {
	case *List:
		i := int(asFloat(index))
		if i < 0 || i >= len(t.Items) {
			panic(fmt.Sprintf("ball: list index %d out of range (len %d)", i, len(t.Items)))
		}
		t.Items[i] = value
	case *Map:
		t.Set(ToStr(index), value)
	default:
		panic(fmt.Sprintf("ball: index-set unsupported target %T", target))
	}
	return value
}

// Iterate yields the elements a std.for_in / std.for_each ranges over: a list's
// items, a map's keys, or a string's characters.
func Iterate(v Value) []Value {
	switch x := v.(type) {
	case *List:
		return x.Items
	case *Map:
		out := make([]Value, 0, x.Len())
		for _, k := range x.keys {
			out = append(out, k)
		}
		return out
	case *Set:
		return append([]Value(nil), x.Items...)
	case string:
		out := make([]Value, 0, len(x))
		for _, r := range x {
			out = append(out, string(r))
		}
		return out
	case nil:
		return nil
	}
	panic(fmt.Sprintf("ball: cannot iterate %T", v))
}

// Call invokes a first-class function value with a single input (std.invoke).
func Call(fn, input Value) Value {
	if f, ok := fn.(*Function); ok {
		return f.Fn(input)
	}
	panic(fmt.Sprintf("ball: cannot call non-function %T", fn))
}
