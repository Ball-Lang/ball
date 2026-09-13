package ballrt

import "testing"

// Issue #641 — ONE contract for the Dart TypeError a failed cast raises.
//
// Two halves, exactly like the StateError contract #616 settled:
//   - TYPED: the thrown value reports runtimeType "TypeError", so a program's
//     own `on TypeError catch` clause sees it.
//   - OBSERVABLE: `to_string(e)` inside that catch body reads Dart's own
//     `_TypeError.toString()`. That string is the ODD ONE OUT of the four
//     built-ins: it carries NO type-name prefix at all —
//     `type 'String' is not a subtype of type 'int' in type cast`, not
//     `TypeError: …`. `dartErrorToString` had no TypeError arm, so a caught
//     one stringified as the bare type tag "TypeError".
//
// The cross-target guard is conformance fixture 466_caught_type_error_to_string
// (compiled and RUN by go/compiler/type_error_contract_test.go); this is the Go
// runtime half.
func TestCastAssertIsTypedAndStringifiesLikeDart(t *testing.T) {
	cases := []struct {
		name     string
		subject  Value
		typeName string
		want     string
	}{
		{"String as int", "hi", "int",
			"type 'String' is not a subtype of type 'int' in type cast"},
		{"double as int", 1.5, "int",
			"type 'double' is not a subtype of type 'int' in type cast"},
		{"bool as int", true, "int",
			"type 'bool' is not a subtype of type 'int' in type cast"},
		{"null as int", nil, "int",
			"type 'Null' is not a subtype of type 'int' in type cast"},
		{"int as String", int64(7), "String",
			"type 'int' is not a subtype of type 'String' in type cast"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer func() {
				r := recover()
				if r == nil {
					t.Fatal("a failed cast must throw, not return")
				}
				thrown, ok := r.(Thrown)
				if !ok {
					t.Fatalf("panicked with %#v, want a ballrt.Thrown", r)
				}
				msg, ok := thrown.Value.(*Message)
				if !ok {
					t.Fatalf("thrown %#v, want a *Message carrying the exception type", thrown.Value)
				}
				if msg.TypeName != "TypeError" {
					t.Errorf("thrown type %q, want TypeError", msg.TypeName)
				}
				if got := ToStr(msg); got != tc.want {
					t.Errorf("to_string(e) = %q, want %q", got, tc.want)
				}
			}()
			CastAssert(false, tc.subject, tc.typeName)
		})
	}
}

// A matching cast is not an assertion failure: it answers true so it can sit as
// a conjunct in the pattern's `&&` chain.
func TestCastAssertPassesThroughOnAMatch(t *testing.T) {
	if !CastAssert(true, int64(42), "int") {
		t.Fatal("CastAssert(true, …) must answer true")
	}
}

// The rendering table stays CLOSED: a user class that merely carries a
// `message` field is not a Dart error and must keep printing its type name.
func TestUserMessageWithAMessageFieldIsNotRenderedAsADartError(t *testing.T) {
	fields := NewMap()
	fields.Set("message", "not a dart error")
	m := NewMessage("main:Complaint", fields)
	if got := ToStr(m); got != "main:Complaint" {
		t.Errorf("ToStr(user message) = %q, want the type name", got)
	}
}
