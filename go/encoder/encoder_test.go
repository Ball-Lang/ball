package encoder_test

import (
	"testing"

	"github.com/ball-lang/ball/go/encoder"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// These unit tests assert on the emitted Ball Program *structure* — the direct
// counterpart to the round-trip tests' behavioral checks. Together they prove
// the encoder both produces the right shape and that the shape actually runs.

func mustEncode(t *testing.T, src string) *ballv1.Program {
	t.Helper()
	prog, err := encoder.Encode(src)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	return prog
}

func findModule(p *ballv1.Program, name string) *ballv1.Module {
	for _, m := range p.GetModules() {
		if m.GetName() == name {
			return m
		}
	}
	return nil
}

func findFunc(m *ballv1.Module, name string) *ballv1.FunctionDefinition {
	for _, f := range m.GetFunctions() {
		if f.GetName() == name {
			return f
		}
	}
	return nil
}

// callOf returns the FunctionCall an expression wraps, or nil.
func callOf(e *ballv1.Expression) *ballv1.FunctionCall {
	if c, ok := e.GetExpr().(*ballv1.Expression_Call); ok {
		return c.Call
	}
	return nil
}

// inputField returns the named field of a call's input message, or nil.
func inputField(c *ballv1.FunctionCall, name string) *ballv1.Expression {
	mc, ok := c.GetInput().GetExpr().(*ballv1.Expression_MessageCreation)
	if !ok {
		return nil
	}
	for _, fv := range mc.MessageCreation.GetFields() {
		if fv.GetName() == name {
			return fv.GetValue()
		}
	}
	return nil
}

// firstStmtCall returns the call in the first statement of a function's body
// block (the common single-statement shape these tests build).
func firstStmtCall(t *testing.T, fn *ballv1.FunctionDefinition) *ballv1.FunctionCall {
	t.Helper()
	blk, ok := fn.GetBody().GetExpr().(*ballv1.Expression_Block)
	if !ok {
		t.Fatalf("function %q body is not a block", fn.GetName())
	}
	stmts := blk.Block.GetStatements()
	if len(stmts) == 0 {
		t.Fatalf("function %q body has no statements", fn.GetName())
	}
	es, ok := stmts[0].GetStmt().(*ballv1.Statement_Expression)
	if !ok {
		t.Fatalf("function %q first statement is not an expression", fn.GetName())
	}
	c := callOf(es.Expression)
	if c == nil {
		t.Fatalf("function %q first statement is not a call", fn.GetName())
	}
	return c
}

func paramNames(fn *ballv1.FunctionDefinition) []string {
	pv, ok := fn.GetMetadata().GetFields()["params"]
	if !ok {
		return nil
	}
	var out []string
	for _, v := range pv.GetListValue().GetValues() {
		out = append(out, v.GetStructValue().GetFields()["name"].GetStringValue())
	}
	return out
}

// ── Program shape ────────────────────────────────────────────────────────────

func TestEncodeProgramShape(t *testing.T) {
	prog := mustEncode(t, `package main
import "fmt"
func main() { fmt.Println("hi") }`)

	if prog.GetEntryModule() != "main" || prog.GetEntryFunction() != "main" {
		t.Fatalf("entry = %s.%s, want main.main", prog.GetEntryModule(), prog.GetEntryFunction())
	}
	std := findModule(prog, "std")
	if std == nil {
		t.Fatal("no std module")
	}
	if p := findFunc(std, "print"); p == nil || !p.GetIsBase() {
		t.Fatal("std.print not declared as a base function")
	}
	main := findModule(prog, "main")
	if main == nil {
		t.Fatal("no main module")
	}
	if len(main.GetModuleImports()) == 0 || main.GetModuleImports()[0].GetName() != "std" {
		t.Fatal("main does not import std")
	}
	// main's single statement is a std.print call.
	c := firstStmtCall(t, findFunc(main, "main"))
	if c.GetModule() != "std" || c.GetFunction() != "print" {
		t.Fatalf("expected std.print, got %s.%s", c.GetModule(), c.GetFunction())
	}
}

// ── Operators route through universal std ────────────────────────────────────

func TestBinaryOperatorsEncodeToStd(t *testing.T) {
	cases := map[string]string{
		"1 + 2":  "add",
		"1 - 2":  "subtract",
		"1 * 2":  "multiply",
		"1 % 2":  "modulo",
		"1 < 2":  "less_than",
		"1 == 2": "equals",
	}
	for expr, want := range cases {
		prog := mustEncode(t, "package main\nimport \"fmt\"\nfunc main() { fmt.Println("+expr+") }")
		print := firstStmtCall(t, findFunc(findModule(prog, "main"), "main"))
		msg := callOf(inputField(print, "message"))
		if msg == nil || msg.GetModule() != "std" || msg.GetFunction() != want {
			got := "<nil>"
			if msg != nil {
				got = msg.GetModule() + "." + msg.GetFunction()
			}
			t.Errorf("%q encoded to %s, want std.%s", expr, got, want)
		}
	}
}

// ── Control flow lowers to std base functions (invariant #4) ──────────────────

func TestControlFlowEncodesToStdCalls(t *testing.T) {
	prog := mustEncode(t, `package main
import "fmt"
func main() {
	for i := 0; i < 3; i++ {
		if i == 1 {
			fmt.Println(i)
		}
	}
	for _, x := range []int{1, 2} {
		fmt.Println(x)
	}
}`)
	used := findModule(prog, "std")
	for _, want := range []string{"for", "if", "for_in", "less_than", "equals", "add", "assign", "print"} {
		if findFunc(used, want) == nil {
			t.Errorf("std module missing accumulated base function %q", want)
		}
	}
}

// ── One-input convention (invariant #1) ──────────────────────────────────────

func TestSingleParamKeepsName(t *testing.T) {
	prog := mustEncode(t, `package main
func identity(n int) int { return n }
func main() { identity(5) }`)
	fn := findFunc(findModule(prog, "main"), "identity")
	if got := paramNames(fn); len(got) != 1 || got[0] != "n" {
		t.Fatalf("params = %v, want [n]", got)
	}
	// The body's `return n` reads a plain reference to the parameter name.
	ret := firstStmtCall(t, fn)
	valRef, ok := inputField(ret, "value").GetExpr().(*ballv1.Expression_Reference)
	if !ok || valRef.Reference.GetName() != "n" {
		t.Fatalf("return value is not reference(n)")
	}
}

func TestMultiParamCallPacksMessage(t *testing.T) {
	prog := mustEncode(t, `package main
func add(a, b int) int { return a + b }
func main() { add(10, 20) }`)
	// The callee declares both parameter names.
	addFn := findFunc(findModule(prog, "main"), "add")
	if got := paramNames(addFn); len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("add params = %v, want [a b]", got)
	}
	// The call site packs its two arguments into an anonymous message keyed by
	// the callee's real parameter names.
	callSite := firstStmtCall(t, findFunc(findModule(prog, "main"), "main"))
	if callSite.GetModule() != "" || callSite.GetFunction() != "add" {
		t.Fatalf("expected user call add, got %s.%s", callSite.GetModule(), callSite.GetFunction())
	}
	mc, ok := callSite.GetInput().GetExpr().(*ballv1.Expression_MessageCreation)
	if !ok {
		t.Fatal("multi-arg call input is not a message")
	}
	names := []string{}
	for _, f := range mc.MessageCreation.GetFields() {
		names = append(names, f.GetName())
	}
	if len(names) != 2 || names[0] != "a" || names[1] != "b" {
		t.Fatalf("packed message fields = %v, want [a b]", names)
	}
}

// ── std accumulation declares only what is used ──────────────────────────────

func TestStdAccumulationOnlyUsed(t *testing.T) {
	prog := mustEncode(t, `package main
import "fmt"
func main() { fmt.Println("only print") }`)
	std := findModule(prog, "std")
	if len(std.GetFunctions()) != 1 || std.GetFunctions()[0].GetName() != "print" {
		names := []string{}
		for _, f := range std.GetFunctions() {
			names = append(names, f.GetName())
		}
		t.Fatalf("std declares %v, want only [print]", names)
	}
}

// ── Fail-loud (issue #55) ────────────────────────────────────────────────────

func TestFailLoudOnUnsupportedConstruct(t *testing.T) {
	// A goroutine has no Ball encoding — it must be a fail-loud error, never a
	// silently-dropped statement or a placeholder.
	_, err := encoder.Encode(`package main
func work() {}
func main() { go work() }`)
	if err == nil {
		t.Fatal("expected a fail-loud error for a goroutine, got nil")
	}
}

func TestFailLoudOnMissingMain(t *testing.T) {
	_, err := encoder.Encode(`package main
func helper() {}`)
	if err == nil {
		t.Fatal("expected an error when no func main() is present, got nil")
	}
}

func TestFailLoudOnParseError(t *testing.T) {
	_, err := encoder.Encode(`package main
func main( {`)
	if err == nil {
		t.Fatal("expected a parse error, got nil")
	}
}
