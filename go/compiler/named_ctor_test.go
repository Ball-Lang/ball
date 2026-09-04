package compiler_test

// Named-constructor call resolution and constructor initializer lists
// (issue #527).
//
// The Dart encoder emits `Class.name(args)` as an ordinary method call whose
// packed `self` field is a bare `reference{name: "Class"}` — the class name
// itself, not a bound value. `compileCall` used to fall through to its final
// `name(input)` fallback, emitting a bare `from(...)` with no such Go function
// declared, so the whole program failed `go build`.
//
// These are PR-gated (`go test ./compiler/...` in ci.yml's `go` job). The
// whole-corpus `go-compiler` leg that would also have measured this lives only
// in conformance-matrix.yml, which has no `pull_request:` trigger and is a
// ratchet on an aggregate count — not a parity gate.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ball-lang/ball/go/compiler"
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/known/structpb"
)

// conformancePath resolves a file in tests/conformance/.
func conformancePath(name string) string {
	return filepath.Join("..", "..", "tests", "conformance", name)
}

// readGolden reads an expected-output file as BYTES, normalising only CRLF
// pairs — a fixture may legitimately print a semantic lone \r, which text-mode
// universal-newline translation would collapse.
func readGolden(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(conformancePath(name))
	if err != nil {
		t.Fatalf("read golden %s: %v", name, err)
	}
	return strings.ReplaceAll(string(raw), "\r\n", "\n")
}

func TestNamedConstructorCallCompilesAndRuns(t *testing.T) {
	prog := load(t, conformancePath("436_recursive_ctor_named.ball.json"))
	src := compileFmt(t, prog)
	// The call resolves to the class's own constructor impl, never a bare
	// `from(...)`/`pair(...)` (no such Go function is ever declared).
	for _, want := range []string{"Countdown__from(", "Countdown__pair("} {
		if !strings.Contains(src, want) {
			t.Errorf("emitted Go missing %q\n---\n%s", want, src)
		}
	}
	got := goRun(t, src)
	if want := readGolden(t, "436_recursive_ctor_named.expected_output.txt"); got != want {
		t.Errorf("436: got %q, want %q", got, want)
	}
}

func TestConstructorInitializerListRunsBeforeTheBody(t *testing.T) {
	prog := load(t, conformancePath("438_ctor_initializer_list_with_body.ball.json"))
	src := compileFmt(t, prog)
	// A non-parameter initializer value (`label = 'pt'`, `ratio = 0.5`) must be
	// applied, not left at the field's class-level default.
	for _, want := range []string{`"pt"`, `"origin"`, `"axis"`, `"constants"`, "0.5"} {
		if !strings.Contains(src, want) {
			t.Errorf("emitted Go missing initializer value %s\n---\n%s", want, src)
		}
	}
	got := goRun(t, src)
	if want := readGolden(t, "438_ctor_initializer_list_with_body.expected_output.txt"); got != want {
		t.Errorf("438: got %q, want %q", got, want)
	}
}

// TestShadowingLocalBeatsNamedConstructorDispatch — a local whose name matches a
// class short name still wins: the call dispatches on that local's VALUE, never
// on the class. (Python's `sr in self.type_defs and not self.lookup(sr)` guard
// is the reference semantics all four compilers copy.)
func TestShadowingLocalBeatsNamedConstructorDispatch(t *testing.T) {
	strLit := func(s string) *ballv1.Expression {
		return &ballv1.Expression{Expr: &ballv1.Expression_Literal{
			Literal: &ballv1.Literal{Value: &ballv1.Literal_StringValue{StringValue: s}}}}
	}
	call := &ballv1.Expression{Expr: &ballv1.Expression_Call{Call: &ballv1.FunctionCall{
		Function: "from",
		Input: &ballv1.Expression{Expr: &ballv1.Expression_MessageCreation{
			MessageCreation: &ballv1.MessageCreation{Fields: []*ballv1.FieldValuePair{
				{Name: "self", Value: &ballv1.Expression{Expr: &ballv1.Expression_Reference{
					Reference: &ballv1.Reference{Name: "Countdown"}}}},
				{Name: "arg0", Value: strLit("x")},
			}}}},
	}}}
	prog := &ballv1.Program{
		Name: "shadow", Version: "1.0.0", EntryModule: "main", EntryFunction: "main",
		Modules: []*ballv1.Module{
			{Name: "std", Functions: []*ballv1.FunctionDefinition{{Name: "print", IsBase: true}}},
			{Name: "main", Functions: []*ballv1.FunctionDefinition{
				{Name: "main", Body: &ballv1.Expression{Expr: &ballv1.Expression_Block{
					Block: &ballv1.Block{Statements: []*ballv1.Statement{
						{Stmt: &ballv1.Statement_Let{Let: &ballv1.LetBinding{
							Name: "Countdown", Value: strLit("shadowed")}}},
						{Stmt: &ballv1.Statement_Expression{Expression: call}},
					}}}}},
				{Name: "main:Countdown.from", Metadata: metaStruct(map[string]any{"kind": "constructor"}),
					Body: strLit("class")},
			}},
		},
	}
	prog.Modules[1].TypeDefs = []*ballv1.TypeDefinition{{
		Name: "main:Countdown",
		Descriptor_: &descriptorpb.DescriptorProto{
			Name:  proto.String("main:Countdown"),
			Field: []*descriptorpb.FieldDescriptorProto{{Name: proto.String("value"), Number: proto.Int32(1)}},
		},
		Metadata: metaStruct(map[string]any{"kind": "class"}),
	}}

	src, err := compiler.Compile(prog)
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	// Look only at the entry function's body — `Countdown__from` also appears
	// there as the constructor impl's own declaration.
	idx := strings.Index(src, "func main()")
	if idx < 0 {
		t.Fatalf("no func main() in emitted Go\n---\n%s", src)
	}
	if strings.Contains(src[idx:], "Countdown__from(") {
		t.Errorf("a shadowing local must not resolve as a class reference\n---\n%s", src[idx:])
	}
}

// metaStruct builds a cosmetic metadata Struct from plain string values.
func metaStruct(fields map[string]any) *structpb.Struct {
	s, err := structpb.NewStruct(fields)
	if err != nil {
		panic(err)
	}
	return s
}
