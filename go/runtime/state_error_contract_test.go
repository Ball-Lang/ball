package ballrt

import "testing"

// Issue #616 — ONE contract for every site that raises Dart's StateError.
//
// Two halves, and every site used to get exactly one of them right:
//   - TYPED: the thrown value reports runtimeType "StateError", so a program's
//     own `on StateError catch` clause can see it. `ListFirst`/`ListLast`/
//     `ListPop`, the `.reduce`/`.firstWhere` method arms and the proto-view
//     `.first`/`.single` arms all used to panic with a plain-string
//     `Thrown{Value: "Bad state: No element"}`, which reports runtimeType
//     "String" and matches NO typed clause.
//   - OBSERVABLE: `to_string(e)` inside that catch body reads Dart's own
//     `StateError.toString()` — "Bad state: No element". `ListFind` was the
//     mirror image: correctly typed since #604, but its message was the bare
//     "No element" and a `*Message` stringified as its type tag, so a Ball
//     program printed "StateError".
//
// The cross-target guard is conformance fixture 464_state_error_message; this
// is the Go runtime half, and it is the only thing that exercises the compiled
// (non-engine) route, which no CI leg compiles the corpus through.
func TestStateErrorSitesAreTypedAndStringifyLikeDart(t *testing.T) {
	alwaysFalse := Fn("", func(Value) Value { return false })
	combine := Fn("", func(m Value) Value { return m })
	methodInput := func(self, arg0 Value) Value {
		m := NewMap()
		m.Set("self", self)
		m.Set("arg0", arg0)
		return m
	}

	cases := map[string]struct {
		run  func()
		want string
	}{
		"ListFirst on empty":  {func() { ListFirst(NewList()) }, "Bad state: No element"},
		"ListLast on empty":   {func() { ListLast(NewList()) }, "Bad state: No element"},
		"ListPop on empty":    {func() { ListPop(NewList()) }, "Bad state: No element"},
		"ListFind no match":   {func() { ListFind(NewList(int64(1)), alwaysFalse) }, "Bad state: No element"},
		"reduce on empty":     {func() { CallMethod("reduce", methodInput(NewList(), combine)) }, "Bad state: No element"},
		"firstWhere no match": {func() { CallMethod("firstWhere", methodInput(NewList(int64(1)), alwaysFalse)) }, "Bad state: No element"},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			defer func() {
				r := recover()
				if r == nil {
					t.Fatal("must throw, not return")
				}
				thrown, ok := r.(Thrown)
				if !ok {
					t.Fatalf("panicked with %#v, want a ballrt.Thrown", r)
				}
				msg, ok := thrown.Value.(*Message)
				if !ok {
					t.Fatalf("thrown %#v, want a *Message carrying the exception type", thrown.Value)
				}
				if msg.TypeName != "StateError" {
					t.Errorf("thrown type: got %q, want %q", msg.TypeName, "StateError")
				}
				if got := ToStr(thrown.Value); got != tc.want {
					t.Errorf("to_string(caught): got %q, want %q", got, tc.want)
				}
			}()
			tc.run()
		})
	}
}

// A user class that merely declares a `message` field is NOT a Dart error and
// must keep stringifying as its own type name — the #616 rendering table is
// deliberately closed over the type names `dartError` raises.
func TestDartErrorRenderingDoesNotLeakIntoUserMessages(t *testing.T) {
	fields := NewMap()
	fields.Set("message", "hello")
	user := &Message{TypeName: "main:Notification", Fields: fields}

	if got := ToStr(user); got != "main:Notification" {
		t.Errorf("user message ToStr: got %q, want %q", got, "main:Notification")
	}
}
