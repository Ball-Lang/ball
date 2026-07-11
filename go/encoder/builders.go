package encoder

import (
	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/types/known/structpb"
)

// This file holds the low-level constructors for the seven Ball Expression node
// types plus statements — the Go analog of the free `int_literal`/`std_call`/…
// helpers at the bottom of `rust/encoder/src/lib.rs`. Keeping them here lets the
// AST-walking code in expr.go / stmt.go read as a direct source→Ball mapping.

// ── Literals ─────────────────────────────────────────────────────────────────

func intLit(v int64) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Literal{
		Literal: &ballv1.Literal{Value: &ballv1.Literal_IntValue{IntValue: v}},
	}}
}

func doubleLit(v float64) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Literal{
		Literal: &ballv1.Literal{Value: &ballv1.Literal_DoubleValue{DoubleValue: v}},
	}}
}

func stringLit(v string) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Literal{
		Literal: &ballv1.Literal{Value: &ballv1.Literal_StringValue{StringValue: v}},
	}}
}

func boolLit(v bool) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Literal{
		Literal: &ballv1.Literal{Value: &ballv1.Literal_BoolValue{BoolValue: v}},
	}}
}

// nullLit is the unset Literal.value oneof — Ball null.
func nullLit() *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Literal{Literal: &ballv1.Literal{}}}
}

func listLit(elems []*ballv1.Expression) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Literal{
		Literal: &ballv1.Literal{Value: &ballv1.Literal_ListValue{
			ListValue: &ballv1.ListLiteral{Elements: elems},
		}},
	}}
}

// ── Reference / field access ─────────────────────────────────────────────────

func ref(name string) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Reference{Reference: &ballv1.Reference{Name: name}}}
}

func fieldAccess(obj *ballv1.Expression, field string) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_FieldAccess{
		FieldAccess: &ballv1.FieldAccess{Object: obj, Field: field},
	}}
}

// ── Message creation (base-call argument packing + typed constructions) ───────

// kv is a named field for a message-creation node — the building block of a
// base call's input message.
type kv struct {
	name  string
	value *ballv1.Expression
}

func pairs(names []string, values []*ballv1.Expression) []kv {
	out := make([]kv, len(names))
	for i := range names {
		out[i] = kv{names[i], values[i]}
	}
	return out
}

func fieldValues(fields []kv) []*ballv1.FieldValuePair {
	out := make([]*ballv1.FieldValuePair, len(fields))
	for i, f := range fields {
		out[i] = &ballv1.FieldValuePair{Name: f.name, Value: f.value}
	}
	return out
}

// argsMessage builds an anonymous (empty type_name) message_creation — the
// "pack named arguments for a base-function call" shape every base function's
// input descriptor uses (left/right, condition/then/else, …).
func argsMessage(fields ...kv) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_MessageCreation{
		MessageCreation: &ballv1.MessageCreation{Fields: fieldValues(fields)},
	}}
}

// namedMessage builds a typed message_creation (non-empty type_name) — a Go
// struct/composite literal `T{...}` becomes one of these.
func namedMessage(typeName string, fields []kv) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_MessageCreation{
		MessageCreation: &ballv1.MessageCreation{TypeName: typeName, Fields: fieldValues(fields)},
	}}
}

// ── Calls ────────────────────────────────────────────────────────────────────

func call(module, function string, input *ballv1.Expression) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Call{Call: &ballv1.FunctionCall{
		Module:   module,
		Function: function,
		Input:    input,
	}}}
}

// stdCall is a call into the universal `std` base module.
func stdCall(function string, input *ballv1.Expression) *ballv1.Expression {
	return call("std", function, input)
}

// stdBinary builds `std.<function>({left, right})`.
func stdBinary(function string, left, right *ballv1.Expression) *ballv1.Expression {
	return stdCall(function, argsMessage(kv{"left", left}, kv{"right", right}))
}

// stdUnary builds `std.<function>({value})`.
func stdUnary(function string, value *ballv1.Expression) *ballv1.Expression {
	return stdCall(function, argsMessage(kv{"value", value}))
}

// ifCall builds `std.if({condition, then, else})` — shared by the `if`
// statement, `if init; …` desugaring, and any future ternary-shaped construct.
func ifCall(condition, then, elseBranch *ballv1.Expression) *ballv1.Expression {
	fields := []kv{{"condition", condition}, {"then", then}}
	if elseBranch != nil {
		fields = append(fields, kv{"else", elseBranch})
	}
	return stdCall("if", argsMessage(fields...))
}

// ── Blocks / statements ──────────────────────────────────────────────────────

func letStmt(name string, value *ballv1.Expression) *ballv1.Statement {
	return &ballv1.Statement{Stmt: &ballv1.Statement_Let{Let: &ballv1.LetBinding{Name: name, Value: value}}}
}

func exprStmt(e *ballv1.Expression) *ballv1.Statement {
	return &ballv1.Statement{Stmt: &ballv1.Statement_Expression{Expression: e}}
}

// blockExpr wraps statements with an optional tail result. A nil result is a
// block with no value (the compiler emits `return ballrt.Value(nil)`), used for
// every Go function body (returns flow through std.return signals, not a tail).
func blockExpr(stmts []*ballv1.Statement, result *ballv1.Expression) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Block{Block: &ballv1.Block{
		Statements: stmts,
		Result:     result,
	}}}
}

// forInitBlock is the `init` clause shape the Go compiler's compileLoopInit
// recognizes: a block of fresh let-bindings with NO result, so each becomes a
// real hoisted local (`var i ballrt.Value = …`) in the compiled loop's IIFE,
// visible to the condition/update/body (mirrors while_sum.ball.json's init).
func forInitBlock(bindings []kv) *ballv1.Expression {
	stmts := make([]*ballv1.Statement, len(bindings))
	for i, b := range bindings {
		stmts[i] = letStmt(b.name, b.value)
	}
	return &ballv1.Expression{Expr: &ballv1.Expression_Block{Block: &ballv1.Block{Statements: stmts}}}
}

// lambdaExpr wraps an anonymous FunctionDefinition (name "") as a Ball lambda —
// a Go func literal encodes to one of these.
func lambdaExpr(fn *ballv1.FunctionDefinition) *ballv1.Expression {
	return &ballv1.Expression{Expr: &ballv1.Expression_Lambda{Lambda: fn}}
}

// ── Metadata (cosmetic — invariant #2) ───────────────────────────────────────

// funcMetadata builds a FunctionDefinition.metadata Struct carrying `kind` and
// the load-bearing `params` list (`[{name}, …]`). The `params` list is the one
// piece the Go compiler actually reads (helpers.go funcParams → paramPrologue),
// so it MUST reflect every declared parameter name in order; everything else the
// metadata could carry is purely cosmetic.
func funcMetadata(params []string) *structpb.Struct {
	m := map[string]any{"kind": "function"}
	if len(params) > 0 {
		list := make([]any, len(params))
		for i, p := range params {
			list[i] = map[string]any{"name": p}
		}
		m["params"] = list
	}
	s, err := structpb.NewStruct(m)
	if err != nil {
		// The map only ever holds strings and nested string maps/lists, which
		// structpb always accepts — an error here is a programming bug.
		panic("encoder: building function metadata: " + err.Error())
	}
	return s
}
