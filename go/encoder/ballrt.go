package encoder

import (
	"fmt"
	"go/ast"
	"go/token"
	"strconv"

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
// `go/compiler/base_call.go`: the helper's name, the base MODULE and function it
// is the emission of, and that base function's input field for each positional
// argument (a base call's input is always a message keyed by field name —
// `{left, right}`, `{value}`, …). Keep the two in step — the drift guard in
// `ballrt_table_test.go` parses that switch and fails when they part. A helper
// the compiler emits but this table does not name is NOT silently mis-encoded:
// it fails loud (issue #55 doctrine), which is why the table is deliberately
// restricted to helpers whose shape is unambiguous:
//
//   - fixed arity, every argument a real expression. Helpers the compiler calls
//     with a `ballrt.Value(nil)` placeholder for an omitted optional argument
//     (`Substring`, `ToStringAsExponential`, `Assert`, `Return`) are left out
//     rather than guessed at;
//   - a base function the module's own builder actually declares —
//     `dart/shared/std.json` for `std`, `dart/shared/lib/std_collections.dart`
//     for `std_collections`. `print_error`/`invoke` are not in std.json, so they
//     are not here either;
//   - no type-name string operands (`IsType`/`AsType` take a quoted Go string,
//     not an encodable expression);
//   - ONE module. A helper the compiler emits from two switches at once (today
//     only `SetCreate`, which both `std.set_create` and
//     `std_collections.set_create` lower to) has no single inverse, so it is
//     excluded rather than guessed at.
//
// Statement-shaped lowerings (`if`/`for`/`while`/`switch`/`try`) are not here at
// all: the compiler emits them as Go control flow or IIFEs, and the encoder
// already reads them back from that Go syntax.

// ballrtHelper is the Ball base call a `ballrt.<Name>` call stands for: the base
// MODULE, the function name, and the input-message field each positional
// argument fills, in order.
type ballrtHelper struct {
	mod    string
	fn     string
	fields []string
}

// The two base modules the `ballrt.*` helpers invert into. There is deliberately
// no `go_std` (see this package's doc comment).
const (
	moduleStd         = "std"
	moduleCollections = "std_collections"
)

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

// ballrtFieldGet reads a named member off a value. `go/compiler` emits it for a
// Ball `field_access` node, so `ballrt.FieldGet(obj, "length")` encodes back to
// exactly that — NOT to a base call. The member name must be a string literal;
// a computed one is `ballrt.IndexGet` (`std.index`) instead, which the table
// above already covers.
const ballrtFieldGet = "FieldGet"

// ballrtNewList builds a runtime list from its arguments — the compiler's
// emission for a Ball list LITERAL (`compileListLiteral`: `ballrt.NewList()` for
// the empty one, `ballrt.NewList(a, b, c)` otherwise). Its inverse is a Ball
// `Literal.list_value`, not a base call, so it is variadic by construction.
const ballrtNewList = "NewList"

// ballrtLoopBody wraps one iteration of a compiled loop so a `break`/`continue`
// flow signal can be recovered. It is meaningful only in the exact statement the
// compiler emits for it (`if ballrt.RunLoopBody("", func() { … }) { break }`),
// which [unwrapLoopBody] reads back structurally; anywhere else it is refused.
const ballrtLoopBody = "RunLoopBody"

// ballrtCatchReturn is the deferred guard that turns a Ball `std.return` signal
// into the compiled function's named result. Like [ballrtEntryWrapper] it is
// plumbing with no Ball counterpart — a Ball function body simply IS its value —
// so it is recognized only inside the compiled-function shape
// ([unwrapCompiledFunc]) and refused anywhere else.
const ballrtCatchReturn = "CatchReturn"

// ballrtReturnVar is the named result `go/compiler` gives every compiled
// function (`func f(input ballrt.Value) (__ret ballrt.Value)`).
const ballrtReturnVar = "__ret"

var (
	unary  = []string{"value"}
	binary = []string{"left", "right"}

	// std_collections receivers — the `list()`/`set()`/`mp()` closures at the
	// top of the compiler's compileCollectionsCall.
	listOnly = []string{"list"}
	setOnly  = []string{"set"}
	mapOnly  = []string{"map"}
)

// ballrtHelpers is the single lookup the encoder consults: every module's table
// merged, with the module stamped on each entry. Built once at init so a helper
// that appears in two module tables is a loud programming error rather than a
// silent module coin-flip (see [mergeHelperTables]).
var ballrtHelpers = mergeHelperTables()

// mergeHelperTables merges the per-module inverse tables into one lookup keyed
// by helper name, stamping each entry with its module. A name in two tables has
// no single inverse, so it panics at package init rather than letting whichever
// table merged last decide the module of an encoded call.
func mergeHelperTables() map[string]ballrtHelper {
	merged := make(map[string]ballrtHelper, len(stdHelpers)+len(collectionsHelpers))
	for mod, table := range map[string]map[string]ballrtHelper{
		moduleStd:         stdHelpers,
		moduleCollections: collectionsHelpers,
	} {
		for name, h := range table {
			if prev, dup := merged[name]; dup {
				panic(fmt.Sprintf(
					"encoder: ballrt.%s is mapped by both the %s and %s inverse tables; "+
						"a helper the compiler emits from two switches has no single inverse "+
						"and must be excluded instead", name, prev.mod, mod))
			}
			h.mod = mod
			merged[name] = h
		}
	}
	return merged
}

// stdHelpers maps a `ballrt.<Name>` helper to the universal `std` base call it
// encodes back to, ordered the way `go/compiler/base_call.go` orders its switch
// so the two read side by side.
var stdHelpers = map[string]ballrtHelper{
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
	"StrIsNotEmpty":  {fn: "string_is_not_empty", fields: unary},
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

// collectionsHelpers is the inverse of `compileCollectionsCall` — the second
// half of `go/compiler/base_call.go`'s dispatch, and the one whose absence kept
// most of the corpus out of the round-trip leg (issue #691): every fixture that
// touches a list, a map or a set stops at its first collection helper.
//
// Same three rules as [stdHelpers], plus the module one. The field name for each
// positional argument is the compiler's FIRST alias for that position — the name
// `c.arg(f, "value", "callback")` looks for before any fallback — so a program
// re-encoded through this table compiles back to the same Go on the next pass,
// and so the reference engines read the field they prefer
// (`dart/engine/lib/engine_std.dart` accepts the aliases as fallbacks).
//
// Deliberately absent: `SetCreate`. `std.set_create` and
// `std_collections.set_create` BOTH lower to it, so its module is ambiguous, and
// the Dart reference engine reads a set's members from an `elements` field that
// neither module's input descriptor declares — an inverse guessing `{list: …}`
// would hand every engine an empty set instead of failing. `mergeHelperTables`
// and the drift guard both treat that as a documented exclusion, not an
// oversight.
var collectionsHelpers = map[string]ballrtHelper{
	// ── Lists ───────────────────────────────────────────────────────────────
	"ListGet":      {fn: "list_get", fields: []string{"list", "index"}},
	"ListLength":   {fn: "list_length", fields: listOnly},
	"ListIsEmpty":  {fn: "list_is_empty", fields: listOnly},
	"ListFirst":    {fn: "list_first", fields: listOnly},
	"ListLast":     {fn: "list_last", fields: listOnly},
	"ListContains": {fn: "list_contains", fields: []string{"list", "value"}},
	"ListIndexOf":  {fn: "list_index_of", fields: []string{"list", "value"}},
	"ListReverse":  {fn: "list_reverse", fields: listOnly},
	"ListConcat":   {fn: "list_concat", fields: []string{"list", "value"}},
	"ListSlice":    {fn: "list_slice", fields: []string{"list", "start", "end"}},
	"ListTake":     {fn: "list_take", fields: []string{"list", "index"}},
	"ListDrop":     {fn: "list_drop", fields: []string{"list", "index"}},
	"ListPush":     {fn: "list_push", fields: []string{"list", "value"}},
	"ListPop":      {fn: "list_pop", fields: listOnly},
	"ListInsert":   {fn: "list_insert", fields: []string{"list", "index", "value"}},
	"ListRemoveAt": {fn: "list_remove_at", fields: []string{"list", "index"}},
	"ListSet":      {fn: "list_set", fields: []string{"list", "index", "value"}},
	"ListClear":    {fn: "list_clear", fields: listOnly},
	"ListMap":      {fn: "list_map", fields: []string{"list", "value"}},
	"ListFilter":   {fn: "list_filter", fields: []string{"list", "value"}},
	"ListForEach":  {fn: "list_foreach", fields: []string{"list", "value"}},
	"ListAll":      {fn: "list_all", fields: []string{"list", "value"}},
	"ListAny":      {fn: "list_any", fields: []string{"list", "value"}},
	"ListFind":     {fn: "list_find", fields: []string{"list", "value"}},
	"ListSort":     {fn: "list_sort", fields: []string{"list", "value"}},
	"ListJoin":     {fn: "list_join", fields: []string{"list", "separator"}},
	"ListToList":   {fn: "list_to_list", fields: listOnly},

	// ── Maps ────────────────────────────────────────────────────────────────
	"MapGet":           {fn: "map_get", fields: []string{"map", "key"}},
	"MapSet":           {fn: "map_set", fields: []string{"map", "key", "value"}},
	"MapDelete":        {fn: "map_delete", fields: []string{"map", "key"}},
	"MapContainsKey":   {fn: "map_contains_key", fields: []string{"map", "key"}},
	"MapContainsValue": {fn: "map_contains_value", fields: []string{"map", "value"}},
	"MapKeys":          {fn: "map_keys", fields: mapOnly},
	"MapValues":        {fn: "map_values", fields: mapOnly},
	"MapLength":        {fn: "map_length", fields: mapOnly},
	"MapIsEmpty":       {fn: "map_is_empty", fields: mapOnly},
	"MapMerge":         {fn: "map_merge", fields: []string{"map", "value"}},
	"MapPutIfAbsent":   {fn: "map_put_if_absent", fields: []string{"map", "key", "value"}},

	// ── String ↔ collection bridge ──────────────────────────────────────────
	"StringJoin": {fn: "string_join", fields: []string{"list", "separator"}},

	// ── Sets ────────────────────────────────────────────────────────────────
	"SetAdd":          {fn: "set_add", fields: []string{"set", "value"}},
	"SetRemove":       {fn: "set_remove", fields: []string{"set", "value"}},
	"SetContains":     {fn: "set_contains", fields: []string{"set", "value"}},
	"SetLength":       {fn: "set_length", fields: setOnly},
	"SetIsEmpty":      {fn: "set_is_empty", fields: setOnly},
	"SetToList":       {fn: "set_to_list", fields: setOnly},
	"SetUnion":        {fn: "set_union", fields: binary},
	"SetIntersection": {fn: "set_intersection", fields: binary},
	"SetDifference":   {fn: "set_difference", fields: binary},
}

// encodeBallrtCall encodes a `ballrt.<name>(args…)` call — one base call each,
// in the module the tables above record (`std`, or `std_collections` for the
// list/map/set family).
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
	case ballrtFieldGet:
		if len(args) != 2 {
			e.fail("ballrt.%s expects 2 argument(s), got %d", ballrtFieldGet, len(args))
			return nullLit()
		}
		name, ok := stringLiteral(args[1])
		if !ok {
			e.fail("ballrt.%s needs a string-literal member name to encode as a Ball field access", ballrtFieldGet)
			return nullLit()
		}
		return fieldAccess(e.encodeExpr(args[0]), name)
	case ballrtNewList:
		elems := make([]*ballv1.Expression, len(args))
		for i, a := range args {
			elems[i] = e.encodeExpr(a)
		}
		return listLit(elems)
	case ballrtEntryWrapper:
		e.fail("ballrt.%s is the compiled entry-point wrapper and is encodable only as the whole body of `func main()`", ballrtEntryWrapper)
		return nullLit()
	case ballrtLoopBody:
		e.fail("ballrt.%s is the compiled loop-body guard and is encodable only as `if ballrt.%s(\"\", func() { … }) { break }` inside a loop", ballrtLoopBody, ballrtLoopBody)
		return nullLit()
	case ballrtCatchReturn:
		e.fail("ballrt.%s is the compiled return-signal guard and is encodable only as the `defer` of a compiled function body", ballrtCatchReturn)
		return nullLit()
	}
	h, ok := ballrtHelpers[name]
	if !ok {
		e.fail("unsupported runtime helper ballrt.%s (go/encoder/ballrt.go lists the helpers that have a universal std/std_collections inverse)", name)
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
	return call(h.mod, h.fn, argsMessage(fields...))
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

// unwrapLoopBody returns the body of the
// `if ballrt.RunLoopBody("", func() { … }) { break }` statement that IS a
// compiled loop's whole body, or nil for any other `if`.
//
// `RunLoopBody` runs one iteration and recovers a `break`/`continue` flow signal
// (go/runtime/flow.go), answering true when the loop must stop — precisely what
// a Ball loop body does on its own, so unwrapping it preserves semantics instead
// of special-casing a round trip. Only the compiler's exact emission is
// accepted: an EMPTY label (the only one the loop lowerings emit — a non-empty
// one comes from the goto-switch lowering, whose shape is different and whose
// label Ball's `std.for`/`std.while` cannot carry), a 0-parameter literal, and a
// body that is exactly `break`.
func unwrapLoopBody(s *ast.IfStmt) *ast.BlockStmt {
	if s.Init != nil || s.Else != nil || s.Body == nil || len(s.Body.List) != 1 {
		return nil
	}
	br, ok := s.Body.List[0].(*ast.BranchStmt)
	if !ok || br.Tok != token.BREAK || br.Label != nil {
		return nil
	}
	callExpr, ok := s.Cond.(*ast.CallExpr)
	if !ok || len(callExpr.Args) != 2 || !isBallrtCall(callExpr.Fun, ballrtLoopBody) {
		return nil
	}
	if label, ok := stringLiteral(callExpr.Args[0]); !ok || label != "" {
		return nil
	}
	lit, ok := callExpr.Args[1].(*ast.FuncLit)
	if !ok || len(paramNames(lit.Type)) != 0 || lit.Type.Results != nil {
		return nil
	}
	return lit.Body
}

// unwrapCompiledFunc reads back the shape `go/compiler` emits for every
// non-entry Ball function:
//
//	func f(input ballrt.Value) (__ret ballrt.Value) {
//		_ = input
//		<parameter aliases…>
//		defer ballrt.CatchReturn(&__ret)
//		__ret = <body>
//		return
//	}
//
// and answers with the statements to keep and the expression that is the
// function's VALUE. The two pieces it drops are pure Go plumbing: the deferred
// `CatchReturn` guard exists because Go has no expression-valued function body,
// and the `__ret = <body>; return` tail is that body being handed to it. A Ball
// function body simply IS `<body>`.
//
// Encoding the shape literally instead is not merely verbose, it is WRONG:
// `__ret` is not a Ball variable, so the trailing bare `return` would encode as
// `std.return` with no value and the function would answer null on every engine.
// Refusing the `defer` (what happened before this) was the honest half of that;
// this is the other half.
func unwrapCompiledFunc(fd *ast.FuncDecl) (stmts []ast.Stmt, result ast.Expr, ok bool) {
	if fd.Body == nil || !hasNamedResult(fd.Type, ballrtReturnVar) || len(fd.Body.List) < 3 {
		return nil, nil, false
	}
	list := fd.Body.List
	if ret, isReturn := list[len(list)-1].(*ast.ReturnStmt); !isReturn || len(ret.Results) != 0 {
		return nil, nil, false
	}
	assign, isAssign := list[len(list)-2].(*ast.AssignStmt)
	if !isAssign || assign.Tok != token.ASSIGN || len(assign.Lhs) != 1 || len(assign.Rhs) != 1 {
		return nil, nil, false
	}
	if lhs, isIdent := assign.Lhs[0].(*ast.Ident); !isIdent || lhs.Name != ballrtReturnVar {
		return nil, nil, false
	}
	head := list[:len(list)-2]
	guards := 0
	kept := make([]ast.Stmt, 0, len(head))
	for _, s := range head {
		if d, isDefer := s.(*ast.DeferStmt); isDefer && isBallrtCall(d.Call.Fun, ballrtCatchReturn) {
			guards++
			continue
		}
		kept = append(kept, s)
	}
	if guards != 1 {
		return nil, nil, false
	}
	return kept, assign.Rhs[0], true
}

// hasNamedResult reports whether ft declares exactly one result, named name.
func hasNamedResult(ft *ast.FuncType, name string) bool {
	if ft.Results == nil || len(ft.Results.List) != 1 || len(ft.Results.List[0].Names) != 1 {
		return false
	}
	return ft.Results.List[0].Names[0].Name == name
}

// isBallrtCall reports whether fn names `ballrt.<name>`.
func isBallrtCall(fn ast.Expr, name string) bool {
	sel, ok := fn.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != name {
		return false
	}
	pkg, ok := sel.X.(*ast.Ident)
	return ok && pkg.Name == ballrtPackage
}

// stringLiteral returns the value of a Go string-literal expression.
func stringLiteral(expr ast.Expr) (string, bool) {
	lit, ok := expr.(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return "", false
	}
	s, err := strconv.Unquote(lit.Value)
	if err != nil {
		return "", false
	}
	return s, true
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
