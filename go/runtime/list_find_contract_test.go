package ballrt

import "testing"

// TestListFindReturnsFirstMatch and TestListFindNoMatchThrowsTypedStateError
// pin the ONE portable contract for std_collections.list_find (issue #597): the
// FIRST matching element, and a catchable, TYPED StateError when nothing
// matches — Dart's Iterable.firstWhere WITHOUT orElse, which is exactly what
// dart/shared/lib/std_collections.dart's own declaration says ("Find first:
// list.firstWhere(callback)") and what the Dart reference engine does.
//
// Before #597 the Go COMPILER had no list_find case at all, so a Ball program
// calling it was refused with "unsupported base function" — safe, but it meant
// the Go target could not run a program every self-hosted engine executes fine
// (an engine's own list_find is compiled engine_std.dart, not this table).
//
// This is the Go runtime half of the guard. The cross-target half is
// conformance fixture 463_list_find_no_match — which no CI leg compiles to Go,
// so without this test the Go route would be entirely unexercised.
func TestListFindReturnsFirstMatch(t *testing.T) {
	list := NewList(int64(1), int64(2), int64(3))
	gtOne := Fn("", func(v Value) Value { return v.(int64) > 1 })

	if got := ListFind(list, gtOne); got != int64(2) {
		t.Errorf("ListFind first match: got %#v, want 2", got)
	}
}

func TestListFindNoMatchThrowsTypedStateError(t *testing.T) {
	gtHundred := Fn("", func(v Value) Value { return v.(int64) > 100 })

	for name, list := range map[string]Value{
		"non-empty": NewList(int64(1), int64(2), int64(3)),
		"empty":     NewList(),
	} {
		t.Run(name, func(t *testing.T) {
			defer func() {
				r := recover()
				if r == nil {
					t.Fatal("ListFind with no match must throw, not return nil")
				}
				thrown, ok := r.(Thrown)
				if !ok {
					t.Fatalf("panicked with %#v, want a ballrt.Thrown", r)
				}
				// A TYPED throw: a plain-string Thrown reports runtimeType
				// "String" and matches NO `on StateError catch` clause.
				msg, ok := thrown.Value.(*Message)
				if !ok {
					t.Fatalf("thrown %#v, want a *Message carrying the exception type", thrown.Value)
				}
				if msg.TypeName != "StateError" {
					t.Errorf("thrown type: got %q, want %q", msg.TypeName, "StateError")
				}
				if got, _ := msg.Fields.Get("message"); got != "No element" {
					t.Errorf("thrown message: got %#v, want %q", got, "No element")
				}
				// …and the value a catch body actually READS (issue #616).
				// Typing alone was not enough: the caught value used to
				// stringify as the bare tag "StateError", where the Dart
				// reference engine prints Dart's own StateError.toString().
				if got := ToStr(thrown.Value); got != "Bad state: No element" {
					t.Errorf("to_string(caught): got %q, want %q", got, "Bad state: No element")
				}
			}()
			ListFind(list, gtHundred)
		})
	}
}
