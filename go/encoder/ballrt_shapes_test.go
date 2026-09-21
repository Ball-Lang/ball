package encoder_test

import (
	"strings"
	"testing"

	"github.com/ball-lang/ball/go/encoder"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// The std_collections inverses and the compiler's emitted SHAPES (issue #691).
//
// The round-trip leg measured a flat 31/350 after #642 because `ballrt.go`'s
// table covered the universal `std` helpers only — every fixture that touches a
// list, a map or a set stopped at its first `ballrt.List*`/`Map*`/`Set*` call —
// and because four shapes the compiler emits for EVERY program had no inverse at
// all: the named-result function body, the deferred return guard, the loop-body
// guard, and `FieldGet`/`NewList`.
//
// These are the fast guards on those shapes. The whole-corpus proof is the
// `go-roundtrip` row in conformance-matrix.yml and its ratcheted floor; a
// regression here fails `go test ./encoder/...` in seconds instead.

// compiledMain wraps body in the entry shape `go/compiler` emits, so a test can
// state one emitted expression and still exercise the real Encode path.
func compiledMain(body string) string {
	return `package main

import ballrt "github.com/ball-lang/ball/go/runtime"

func main() {
	ballrt.RunEntry(func() ballrt.Value {
		return ` + body + `
	})
}
`
}

// entryResult returns the expression the encoded `main` evaluates to: its body
// block's tail result, or its single statement when the block has no result.
func entryResult(t *testing.T, prog *ballv1.Program) *ballv1.Expression {
	t.Helper()
	for _, m := range prog.GetModules() {
		for _, f := range m.GetFunctions() {
			if f.GetName() != "main" {
				continue
			}
			block := f.GetBody().GetBlock()
			if block == nil {
				t.Fatalf("encoded main has no block body: %v", f)
			}
			if block.GetResult() != nil {
				return unwrapReturn(block.GetResult())
			}
			if len(block.GetStatements()) == 1 {
				return unwrapReturn(block.GetStatements()[0].GetExpression())
			}
			t.Fatalf("encoded main's body is neither a single statement nor result-valued: %v", block)
		}
	}
	t.Fatal("encoded program declares no main")
	return nil
}

// unwrapReturn peels the `std.return({value: …})` a Go `return <expr>` encodes
// to, so a test can assert on the expression it carries.
func unwrapReturn(e *ballv1.Expression) *ballv1.Expression {
	call := e.GetCall()
	if call == nil || call.GetModule() != "std" || call.GetFunction() != "return" {
		return e
	}
	for _, f := range call.GetInput().GetMessageCreation().GetFields() {
		if f.GetName() == "value" {
			return f.GetValue()
		}
	}
	return e
}

func fieldNames(call *ballv1.FunctionCall) []string {
	var names []string
	for _, f := range call.GetInput().GetMessageCreation().GetFields() {
		names = append(names, f.GetName())
	}
	return names
}

// TestCollectionsHelperEncodesIntoStdCollections pins the module, the function
// and the input field names of a collections inverse — the three things the old
// `stdCall`-shaped table could not express at all.
func TestCollectionsHelperEncodesIntoStdCollections(t *testing.T) {
	cases := []struct {
		source string
		fn     string
		fields []string
	}{
		{`ballrt.ListGet(items, 1)`, "list_get", []string{"list", "index"}},
		{`ballrt.ListLength(items)`, "list_length", []string{"list"}},
		{`ballrt.MapSet(lookup, "k", 2)`, "map_set", []string{"map", "key", "value"}},
		{`ballrt.SetUnion(a, b)`, "set_union", []string{"left", "right"}},
		{`ballrt.StringJoin(items, ", ")`, "string_join", []string{"list", "separator"}},
	}
	for _, tc := range cases {
		t.Run(tc.fn, func(t *testing.T) {
			prog, err := encoder.Encode(compiledMain(tc.source))
			if err != nil {
				t.Fatalf("encode %s: %v", tc.source, err)
			}
			result := entryResult(t, prog)
			call := result.GetCall()
			if call == nil {
				t.Fatalf("%s did not encode to a call: %v", tc.source, result)
			}
			if call.GetModule() != "std_collections" || call.GetFunction() != tc.fn {
				t.Fatalf("%s encoded to %s.%s, want std_collections.%s",
					tc.source, call.GetModule(), call.GetFunction(), tc.fn)
			}
			if got := fieldNames(call); strings.Join(got, ",") != strings.Join(tc.fields, ",") {
				t.Fatalf("%s packed fields %v, want %v", tc.source, got, tc.fields)
			}
		})
	}
}

// TestCollectionsCallDeclaresItsModule pins the other half: a base call is only
// runnable if the Program declares the module it names and the main module
// imports it. A `std_collections` call inside a program that declares only `std`
// is structurally valid and refused by every engine.
func TestCollectionsCallDeclaresItsModule(t *testing.T) {
	prog, err := encoder.Encode(compiledMain(`ballrt.ListLength(items)`))
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	var declared *ballv1.Module
	for _, m := range prog.GetModules() {
		if m.GetName() == "std_collections" {
			declared = m
		}
	}
	if declared == nil {
		t.Fatalf("no std_collections module declared: %v", prog.GetModules())
	}
	fns := declared.GetFunctions()
	if len(fns) != 1 || fns[0].GetName() != "list_length" || !fns[0].GetIsBase() {
		t.Fatalf("std_collections must declare exactly the base functions used, as base functions: %v", fns)
	}
	imported := false
	for _, m := range prog.GetModules() {
		if m.GetName() != "main" {
			continue
		}
		for _, imp := range m.GetModuleImports() {
			if imp.GetName() == "std_collections" {
				imported = true
			}
		}
	}
	if !imported {
		t.Fatal("the main module does not import std_collections")
	}
}

// TestSetCreateStaysFailLoud pins the documented exclusion: `ballrt.SetCreate`
// is emitted by BOTH `std.set_create` and `std_collections.set_create`, so it
// has no single inverse — and the Dart reference engine reads a set's members
// from an `elements` field neither module's input descriptor declares. Guessing
// an inverse would hand every engine an empty set, silently: exactly the
// issue-#55 failure mode this table exists to avoid.
func TestSetCreateStaysFailLoud(t *testing.T) {
	_, err := encoder.Encode(compiledMain(`ballrt.SetCreate(items)`))
	if err == nil {
		t.Fatal("expected ballrt.SetCreate to be refused, got none")
	}
	if !strings.Contains(err.Error(), "unsupported runtime helper ballrt.SetCreate") {
		t.Fatalf("expected an unsupported-helper error, got: %v", err)
	}
}

// TestFieldGetEncodesAsFieldAccess: `ballrt.FieldGet(x, "length")` is the
// compiler's emission for a Ball field_access node, so it encodes back to one —
// not to a base call, and not to a refusal.
func TestFieldGetEncodesAsFieldAccess(t *testing.T) {
	prog, err := encoder.Encode(compiledMain(`ballrt.FieldGet(items, "length")`))
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	result := entryResult(t, prog)
	fa := result.GetFieldAccess()
	if fa == nil {
		t.Fatalf("FieldGet did not encode to a field access: %v", result)
	}
	if fa.GetField() != "length" || fa.GetObject().GetReference().GetName() != "items" {
		t.Fatalf("field access reads %q off %v, want \"length\" off items", fa.GetField(), fa.GetObject())
	}
}

// TestFieldGetNeedsALiteralName is the boundary: a computed member name has no
// field_access encoding (that is `std.index`), so it must fail rather than
// encode the expression as if it were a literal name.
func TestFieldGetNeedsALiteralName(t *testing.T) {
	_, err := encoder.Encode(compiledMain(`ballrt.FieldGet(items, name)`))
	if err == nil {
		t.Fatal("expected a computed FieldGet member name to be refused")
	}
	if !strings.Contains(err.Error(), "string-literal member name") {
		t.Fatalf("expected a string-literal-name error, got: %v", err)
	}
}

// TestNewListEncodesAsListLiteral: `ballrt.NewList(a, b)` is the compiler's
// emission for a Ball list LITERAL, so its inverse is a literal, not a call.
func TestNewListEncodesAsListLiteral(t *testing.T) {
	for _, tc := range []struct {
		source string
		want   int
	}{
		{`ballrt.NewList()`, 0},
		{`ballrt.NewList(int64(1), int64(2), int64(3))`, 3},
	} {
		prog, err := encoder.Encode(compiledMain(tc.source))
		if err != nil {
			t.Fatalf("encode %s: %v", tc.source, err)
		}
		result := entryResult(t, prog)
		lit := result.GetLiteral().GetListValue()
		if lit == nil {
			t.Fatalf("%s did not encode to a list literal: %v", tc.source, result)
		}
		if len(lit.GetElements()) != tc.want {
			t.Fatalf("%s encoded %d elements, want %d", tc.source, len(lit.GetElements()), tc.want)
		}
	}
}

// TestCompiledFunctionBodyIsItsValue pins the named-result shape every compiled
// Ball function carries:
//
//	func triple(input ballrt.Value) (__ret ballrt.Value) {
//		_ = input
//		x := input
//		_ = x
//		defer ballrt.CatchReturn(&__ret)
//		__ret = ballrt.Mul(x, int64(3))
//		return
//	}
//
// Encoding that literally is not merely verbose, it is WRONG: `__ret` is not a
// Ball variable, so the trailing bare `return` would become a `std.return` with
// no value and the function would answer null on every engine. The Ball body is
// the assigned expression, and it must come back as the block's tail RESULT.
func TestCompiledFunctionBodyIsItsValue(t *testing.T) {
	src := compileFixture(t, "283_enc_nested_calls")
	prog, err := encoder.Encode(src)
	if err != nil {
		t.Fatalf("re-encoding the compiler's own output failed: %v\n--- source ---\n%s", err, src)
	}
	var triple *ballv1.FunctionDefinition
	for _, m := range prog.GetModules() {
		for _, f := range m.GetFunctions() {
			if f.GetName() == "triple" {
				triple = f
			}
		}
	}
	if triple == nil {
		t.Fatalf("re-encoded program declares no `triple`: %v", prog.GetModules())
	}
	block := triple.GetBody().GetBlock()
	if block == nil || block.GetResult() == nil {
		t.Fatalf("`triple`'s body is not result-valued — it would answer null: %v", triple.GetBody())
	}
	if call := block.GetResult().GetCall(); call == nil || call.GetFunction() != "multiply" {
		t.Fatalf("`triple`'s value is %v, want the std.multiply that is its Ball body", block.GetResult())
	}
	// "__ret" is the compiler's named result; nothing about it may survive.
	if strings.Contains(triple.String(), "__ret") {
		t.Fatalf("the compiled named result leaked into the encoding: %s", triple.String())
	}
}

// TestLoopBodyGuardUnwraps: `if ballrt.RunLoopBody("", func() { … }) { break }`
// is the compiler's lowering of a loop BODY, not a Ball `if`. It comes back as
// the body's own statements, inside the Ball loop the enclosing Go loop encodes
// to.
func TestLoopBodyGuardUnwraps(t *testing.T) {
	const src = `package main

import ballrt "github.com/ball-lang/ball/go/runtime"

func main() {
	ballrt.RunEntry(func() ballrt.Value {
		return func() ballrt.Value {
			for ballrt.Truthy(more) {
				if ballrt.RunLoopBody("", func() { _ = ballrt.Print(more) }) {
					break
				}
			}
			return ballrt.Value(nil)
		}()
	})
}
`
	prog, err := encoder.Encode(src)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	text := prog.String()
	if strings.Contains(text, "RunLoopBody") {
		t.Fatalf("the loop-body guard survived into the encoding: %s", text)
	}
	if !strings.Contains(text, `function:"while"`) {
		t.Fatalf("the loop did not encode to a Ball while: %s", text)
	}
	if !strings.Contains(text, `function:"print"`) {
		t.Fatalf("the loop body was dropped: %s", text)
	}
}

// TestCompiledGuardsOutsideTheirShapeFailLoud is the other half: each of these
// helpers carries plumbing Ball has no expression for (flow-signal recovery, the
// entry wrapper), so anywhere but the exact emitted statement they must fail
// rather than encode as an ordinary call. A non-empty loop label is refused for
// the same reason: it comes from the goto-switch lowering, and Ball's
// `std.for`/`std.while` cannot carry it.
func TestCompiledGuardsOutsideTheirShapeFailLoud(t *testing.T) {
	cases := map[string]string{
		"bare loop-body guard": `ballrt.RunLoopBody("", func() { _ = ballrt.Print(x) })`,
		"non-empty loop label": "func() ballrt.Value {\n\t\t\tfor {\n\t\t\t\tif ballrt.RunLoopBody(\"outer\", func() { _ = ballrt.Print(x) }) {\n\t\t\t\t\tbreak\n\t\t\t\t}\n\t\t\t}\n\t\t\treturn ballrt.Value(nil)\n\t\t}()",
		"bare return guard":    `ballrt.CatchReturn(x)`,
		"nested entry wrapper": `ballrt.RunEntry(func() ballrt.Value { return x })`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := encoder.Encode(compiledMain(body)); err == nil {
				t.Fatalf("expected %s to be refused, got none", name)
			}
		})
	}
}

// TestNewlyRoundTrippableFixturesEncode is the in-module floor on the leg's
// climb: every fixture below re-encodes from the compiler's own output, and each
// is blocked on a DIFFERENT piece of this change, so a regression names which
// piece broke.
func TestNewlyRoundTrippableFixturesEncode(t *testing.T) {
	fixtures := []string{
		"99_type_conversion",   // ballrt.FieldGet
		"283_enc_nested_calls", // the compiled-function shape
		"97_stack_operations",  // NewList + ListPush/ListPop + the loop-body guard
		"27_list_ops",          // the std_collections list family
		"268_enc_while",        // the loop-body guard on its own
	}
	encoded := 0
	for _, name := range fixtures {
		src := compileFixture(t, name)
		if _, err := encoder.Encode(src); err != nil {
			t.Errorf("%s no longer re-encodes: %v", name, err)
			continue
		}
		encoded++
	}
	// Positive floor: an exit code cannot tell "all encoded" from "nothing ran".
	if encoded != len(fixtures) {
		t.Fatalf("re-encoded %d of %d fixtures", encoded, len(fixtures))
	}
}
