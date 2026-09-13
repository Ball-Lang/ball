package encoder

import (
	"go/ast"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// Recognizing the Ball Go runtime's own dispatch helpers (`ballrt.*`).
//
// `go/runtime` is an ordinary, importable Go package, so `ballrt.Add(a, b)` is a
// perfectly normal thing to find in hand-written Go — but the reason this file
// exists is the ROUND-TRIP leg (issue #642): `go/compiler` emits every Ball
// base-function call as exactly one of these helpers, and the encoder used to
// refuse all of them ("unsupported qualified call ballrt.Add"), so not one of
// the conformance fixtures could survive Ball -> Go -> Ball. The leg measured a
// flat 0 and its CI row went green on it.
//
// Every entry below is the exact INVERSE of one line in
// `go/compiler/base_call.go`: the helper's name, the base function it is the
// emission of, and that base function's input field for each positional
// argument (a base call's input is always a message keyed by field name —
// `{left, right}`, `{value}`, …). Keep the two in step. A helper the compiler
// emits but this table does not name is NOT silently mis-encoded: it fails loud
// (issue #55 doctrine), which is why the table is deliberately restricted to
// helpers whose shape is unambiguous:
//
//   - fixed arity, every argument a real expression. Helpers the compiler calls
//     with a `ballrt.Value(nil)` placeholder for an omitted optional argument
//     (`Substring`, `ToStringAsExponential`, `Assert`, `Return`) are left out
//     rather than guessed at;
//   - a `std` base function that `dart/shared/std.json` actually declares —
//     the canonical base-function inventory. `print_error`/`invoke` are not in
//     it, so they are not here either;
//   - no type-name string operands (`IsType`/`AsType` take a quoted Go string,
//     not an encodable expression).
//
// Statement-shaped lowerings (`if`/`for`/`while`/`switch`/`try`) are not here at
// all: the compiler emits them as Go control flow or IIFEs, and the encoder
// already reads them back from that Go syntax.

// ballrtHelper is the Ball base function a `ballrt.<Name>` call stands for: the
// base module, the function name, and the input-message field each positional
// argument fills, in order.
type ballrtHelper struct {
	fn     string
	fields []string
}

// ballrtPackage is the import alias `go/compiler` gives the Ball Go runtime in
// every program it emits
// (`import ballrt "github.com/ball-lang/ball/go/runtime"`).
const ballrtPackage = "ballrt"

// ballrtEntryWrapper is the helper `go/compiler` wraps a program's entry
// function body in: `func main() { ballrt.RunEntry(func() ballrt.Value { … }) }`.
// It is not a base call and is meaningful only in that one position, so it is
// unwrapped structurally by [unwrapEntryWrapper] and rejected anywhere else.
const ballrtEntryWrapper = "RunEntry"

// ballrtValueConversion is the runtime's dynamic value type. `ballrt.Value(x)`
// is a Go TYPE CONVERSION, not a call — the identity in Ball, where every value
// is already dynamic.
const ballrtValueConversion = "Value"

// ballrtTruthy coerces a runtime value to a Go bool. The compiler emits it only
// as glue at a condition site (`(ballrt.Truthy(a) && ballrt.Truthy(b))`,
// `if ballrt.Truthy(c) {`), and Ball performs that coercion implicitly wherever
// a condition is evaluated (`std.and`, `std.if`, …), so it encodes back to its
// operand unchanged.
const ballrtTruthy = "Truthy"

var (
	unary  = []string{"value"}
	binary = []string{"left", "right"}
)

// ballrtHelpers maps a `ballrt.<Name>` helper to the `std` base call it encodes
// back to, ordered the way `go/compiler/base_call.go` orders its switch so the
// two read side by side.
var ballrtHelpers = map[string]ballrtHelper{
	// ── I/O ─────────────────────────────────────────────────────────────────
	"Print": {fn: "print", fields: []string{"message"}},

	// ── Arithmetic ──────────────────────────────────────────────────────────
	"Add":       {fn: "add", fields: binary},
	"Sub":       {fn: "subtract", fields: binary},
	"Mul":       {fn: "multiply", fields: binary},
	"IntDiv":    {fn: "divide", fields: binary},
	"DivDouble": {fn: "divide_double", fields: binary},
	"Modulo":    {fn: "modulo", fields: binary},
	"Negate":    {fn: "negate", fields: unary},

	// ── Bitwise ─────────────────────────────────────────────────────────────
	"BitwiseAnd":         {fn: "bitwise_and", fields: binary},
	"BitwiseOr":          {fn: "bitwise_or", fields: binary},
	"BitwiseXor":         {fn: "bitwise_xor", fields: binary},
	"BitwiseNot":         {fn: "bitwise_not", fields: unary},
	"LeftShift":          {fn: "left_shift", fields: binary},
	"RightShift":         {fn: "right_shift", fields: binary},
	"UnsignedRightShift": {fn: "unsigned_right_shift", fields: binary},

	// ── Comparison ──────────────────────────────────────────────────────────
	"Eq":        {fn: "equals", fields: binary},
	"Neq":       {fn: "not_equals", fields: binary},
	"Lt":        {fn: "less_than", fields: binary},
	"Gt":        {fn: "greater_than", fields: binary},
	"Lte":       {fn: "lte", fields: binary},
	"Gte":       {fn: "gte", fields: binary},
	"CompareTo": {fn: "compare_to", fields: binary},

	// ── Logic ───────────────────────────────────────────────────────────────
	"Not": {fn: "not", fields: unary},

	// ── Strings ─────────────────────────────────────────────────────────────
	"Concat":         {fn: "concat", fields: binary},
	"ToStr":          {fn: "to_string", fields: unary},
	"Length":         {fn: "length", fields: unary},
	"StrToInt":       {fn: "string_to_int", fields: unary},
	"StrToDouble":    {fn: "string_to_double", fields: unary},
	"StrUpper":       {fn: "string_to_upper", fields: unary},
	"StrLower":       {fn: "string_to_lower", fields: unary},
	"StrTrim":        {fn: "string_trim", fields: unary},
	"StrTrimStart":   {fn: "string_trim_start", fields: unary},
	"StrTrimEnd":     {fn: "string_trim_end", fields: unary},
	"StrRunes":       {fn: "string_runes", fields: unary},
	"StrIsEmpty":     {fn: "string_is_empty", fields: unary},
	"StrContains":    {fn: "string_contains", fields: []string{"value", "search"}},
	"StrStartsWith":  {fn: "string_starts_with", fields: []string{"value", "prefix"}},
	"StrEndsWith":    {fn: "string_ends_with", fields: []string{"value", "suffix"}},
	"StrIndexOf":     {fn: "string_index_of", fields: []string{"value", "search"}},
	"StrLastIndexOf": {fn: "string_last_index_of", fields: []string{"value", "search"}},
	"StrSplit":       {fn: "string_split", fields: []string{"value", "separator"}},
	"StrCodeUnitAt":  {fn: "string_code_unit_at", fields: []string{"value", "index"}},
	"StrReplace":     {fn: "string_replace", fields: []string{"value", "from", "to"}},
	"StrReplaceAll":  {fn: "string_replace_all", fields: []string{"value", "from", "to"}},
	"StrPadLeft":     {fn: "string_pad_left", fields: []string{"value", "width", "padding"}},
	"StrPadRight":    {fn: "string_pad_right", fields: []string{"value", "width", "padding"}},

	// ── Numeric conversion + formatting ─────────────────────────────────────
	"NullCheck":           {fn: "null_check", fields: unary},
	"ToInt":               {fn: "to_int", fields: unary},
	"ToDouble":            {fn: "to_double", fields: unary},
	"ToStringAsFixed":     {fn: "to_string_as_fixed", fields: []string{"value", "digits"}},
	"ToStringAsPrecision": {fn: "to_string_as_precision", fields: []string{"value", "precision"}},

	// ── Math ────────────────────────────────────────────────────────────────
	"MathAbs":        {fn: "math_abs", fields: unary},
	"MathFloor":      {fn: "math_floor", fields: unary},
	"MathCeil":       {fn: "math_ceil", fields: unary},
	"MathRound":      {fn: "math_round", fields: unary},
	"MathSqrt":       {fn: "math_sqrt", fields: unary},
	"MathTrunc":      {fn: "math_trunc", fields: unary},
	"MathSign":       {fn: "math_sign", fields: unary},
	"MathIsFinite":   {fn: "math_is_finite", fields: unary},
	"MathIsInfinite": {fn: "math_is_infinite", fields: unary},
	"MathPow":        {fn: "math_pow", fields: []string{"base", "exponent"}},
	"MathMin":        {fn: "math_min", fields: binary},
	"MathMax":        {fn: "math_max", fields: binary},
	"MathClamp":      {fn: "math_clamp", fields: []string{"value", "min", "max"}},
	"MathGcd":        {fn: "math_gcd", fields: []string{"value", "other"}},

	// ── Indexing ────────────────────────────────────────────────────────────
	"IndexGet": {fn: "index", fields: []string{"target", "index"}},
	"TypeOf":   {fn: "type_of", fields: unary},
}

// encodeBallrtCall encodes a `ballrt.<name>(args…)` call — one universal `std`
// base call each, per the table above.
func (e *Encoder) encodeBallrtCall(name string, args []ast.Expr) *ballv1.Expression {
	switch name {
	case ballrtValueConversion:
		// `ballrt.Value(x)` is a conversion to the runtime's dynamic value type:
		// the identity in Ball. `ballrt.Value(nil)` is Ball null, which the
		// `nil` identifier already encodes to.
		if len(args) != 1 {
			e.fail("ballrt.%s is a type conversion and takes exactly one operand, got %d", ballrtValueConversion, len(args))
			return nullLit()
		}
		return e.encodeExpr(args[0])
	case ballrtTruthy:
		if len(args) != 1 {
			e.fail("ballrt.%s expects exactly one argument, got %d", ballrtTruthy, len(args))
			return nullLit()
		}
		return e.encodeExpr(args[0])
	case ballrtEntryWrapper:
		e.fail("ballrt.%s is the compiled entry-point wrapper and is encodable only as the whole body of `func main()`", ballrtEntryWrapper)
		return nullLit()
	}
	h, ok := ballrtHelpers[name]
	if !ok {
		e.fail("unsupported runtime helper ballrt.%s (go/encoder/ballrt.go lists the helpers that have a universal std inverse)", name)
		return nullLit()
	}
	if len(args) != len(h.fields) {
		e.fail("ballrt.%s expects %d argument(s), got %d", name, len(h.fields), len(args))
		return nullLit()
	}
	fields := make([]kv, len(args))
	for i, a := range args {
		fields[i] = kv{h.fields[i], e.encodeExpr(a)}
	}
	return stdCall(h.fn, argsMessage(fields...))
}

// unwrapEntryWrapper returns the body of the
// `ballrt.RunEntry(func() ballrt.Value { … })` call that IS `func main()`'s whole
// body, or nil when main has some other shape (a hand-written `func main()`,
// which encodes normally).
//
// `RunEntry` runs the entry body and swallows a top-level `std.return` signal
// (go/runtime/flow.go) — exactly what a Ball Program's entry function does — so
// unwrapping it preserves semantics rather than special-casing a round-trip.
func unwrapEntryWrapper(body *ast.BlockStmt) *ast.BlockStmt {
	if body == nil || len(body.List) != 1 {
		return nil
	}
	stmt, ok := body.List[0].(*ast.ExprStmt)
	if !ok {
		return nil
	}
	callExpr, ok := stmt.X.(*ast.CallExpr)
	if !ok || len(callExpr.Args) != 1 {
		return nil
	}
	sel, ok := callExpr.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != ballrtEntryWrapper {
		return nil
	}
	if pkg, isIdent := sel.X.(*ast.Ident); !isIdent || pkg.Name != ballrtPackage {
		return nil
	}
	lit, ok := callExpr.Args[0].(*ast.FuncLit)
	if !ok || len(paramNames(lit.Type)) != 0 {
		return nil
	}
	return lit.Body
}

// inlineIIFE encodes `func() ballrt.Value { … }()` — the compiler's lowering of
// a Ball block used in expression position — back into a Ball block.
//
// Only the shape whose meaning is unambiguous is accepted: a body whose LAST
// statement is `return <expr>` and which contains no other `return` (nested
// function literals excluded, they have their own). Any other shape would
// change meaning, because a Go `return` inside the IIFE ends only the IIFE
// while the encoder's `std.return` ends the enclosing Ball function — so it
// fails loud instead.
func (e *Encoder) inlineIIFE(lit *ast.FuncLit) (*ballv1.Expression, bool) {
	if len(paramNames(lit.Type)) != 0 || lit.Body == nil || len(lit.Body.List) == 0 {
		return nil, false
	}
	last, ok := lit.Body.List[len(lit.Body.List)-1].(*ast.ReturnStmt)
	if !ok || len(last.Results) != 1 {
		return nil, false
	}
	head := lit.Body.List[:len(lit.Body.List)-1]
	for _, s := range head {
		if containsReturn(s) {
			return nil, false
		}
	}
	stmts := make([]*ballv1.Statement, 0, len(head))
	for _, s := range head {
		stmts = append(stmts, e.encodeStmt(s)...)
	}
	return blockExpr(stmts, e.encodeExpr(last.Results[0])), true
}

// containsReturn reports whether a statement contains a `return` of its own,
// not counting returns inside a nested function literal (those belong to that
// literal).
func containsReturn(node ast.Node) bool {
	found := false
	ast.Inspect(node, func(n ast.Node) bool {
		if found {
			return false
		}
		switch n.(type) {
		case *ast.FuncLit:
			return false
		case *ast.ReturnStmt:
			found = true
			return false
		}
		return true
	})
	return found
}
