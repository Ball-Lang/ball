package compiler

import (
	"fmt"
	"strconv"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// compileCall dispatches a FunctionCall: a call into a base module (std,
// std_collections, …) goes to compileBaseCall; anything else is a direct call
// to a user function `name(input)` (an empty module names the current module).
func (c *Compiler) compileCall(call *ballv1.FunctionCall) string {
	mod := call.GetModule()
	if mod != "" && c.baseModules[mod] {
		return c.compileBaseCall(call)
	}
	name := sanitize(call.GetFunction())
	// A call through a first-class function *value* (a local bound to a
	// *ballrt.Function) goes through ballrt.Call; a call to a known top-level
	// function is a direct Go call.
	input := "ballrt.Value(nil)"
	if call.GetInput() != nil {
		input = c.compileExpr(call.GetInput())
	}
	if c.isLocal(call.GetFunction()) && !c.userFuncs[name] {
		return fmt.Sprintf("ballrt.Call(%s, %s)", name, input)
	}
	return fmt.Sprintf("%s(%s)", name, input)
}

// arg compiles a named input field of a base call, or a null placeholder if the
// field is absent.
func (c *Compiler) arg(f map[string]*ballv1.Expression, names ...string) string {
	for _, n := range names {
		if e, ok := f[n]; ok {
			return c.compileExpr(e)
		}
	}
	return "ballrt.Value(nil)"
}

// hasField reports whether any of names is present in the field map.
func hasField(f map[string]*ballv1.Expression, names ...string) bool {
	for _, n := range names {
		if _, ok := f[n]; ok {
			return true
		}
	}
	return false
}

// compileBaseCall is the base-function dispatch table — the heart of the
// compiler. Control flow (if/for/while/for_in) compiles to NATIVE Go control
// flow evaluated lazily (invariant #4); return/break/continue/throw become
// ballrt flow signals. Arithmetic/comparison/logic map to ballrt ops. An
// unknown base function is a fail-loud compile error (issue #55 doctrine) — it
// still emits parseable Go so the recorded error, not a Go syntax error, is the
// signal.
func (c *Compiler) compileBaseCall(call *ballv1.FunctionCall) string {
	f := fieldMap(call)
	fn := call.GetFunction()

	// Binary/unary operand shorthands.
	L := func() string { return c.arg(f, "left") }
	R := func() string { return c.arg(f, "right") }
	V := func() string { return c.arg(f, "value") }

	switch fn {
	// ── I/O ──────────────────────────────────────────────────────────────
	case "print":
		return fmt.Sprintf("ballrt.Print(%s)", c.arg(f, "message", "value"))

	// ── Arithmetic ───────────────────────────────────────────────────────
	case "add":
		return fmt.Sprintf("ballrt.Add(%s, %s)", L(), R())
	case "subtract":
		return fmt.Sprintf("ballrt.Sub(%s, %s)", L(), R())
	case "multiply":
		return fmt.Sprintf("ballrt.Mul(%s, %s)", L(), R())
	case "divide":
		return fmt.Sprintf("ballrt.IntDiv(%s, %s)", L(), R())
	case "divide_double":
		return fmt.Sprintf("ballrt.DivDouble(%s, %s)", L(), R())
	case "modulo":
		return fmt.Sprintf("ballrt.Modulo(%s, %s)", L(), R())
	case "negate":
		return fmt.Sprintf("ballrt.Negate(%s)", V())

	// ── Comparison (produce Go bool, which is a valid ballrt.Value) ───────
	case "equals":
		return fmt.Sprintf("ballrt.Eq(%s, %s)", L(), R())
	case "not_equals":
		return fmt.Sprintf("ballrt.Neq(%s, %s)", L(), R())
	case "less_than":
		return fmt.Sprintf("ballrt.Lt(%s, %s)", L(), R())
	case "greater_than":
		return fmt.Sprintf("ballrt.Gt(%s, %s)", L(), R())
	case "lte":
		return fmt.Sprintf("ballrt.Lte(%s, %s)", L(), R())
	case "gte":
		return fmt.Sprintf("ballrt.Gte(%s, %s)", L(), R())

	// ── Logic (short-circuit via native Go && / ||) ──────────────────────
	case "and":
		return fmt.Sprintf("(ballrt.Truthy(%s) && ballrt.Truthy(%s))", L(), R())
	case "or":
		return fmt.Sprintf("(ballrt.Truthy(%s) || ballrt.Truthy(%s))", L(), R())
	case "not":
		return fmt.Sprintf("ballrt.Not(%s)", V())

	// ── Strings & conversion ─────────────────────────────────────────────
	case "concat", "string_concat":
		return fmt.Sprintf("ballrt.Concat(%s, %s)", L(), R())
	case "to_string", "int_to_string", "double_to_string":
		return fmt.Sprintf("ballrt.ToStr(%s)", V())
	case "length", "string_length":
		return fmt.Sprintf("ballrt.Length(%s)", V())
	case "string_to_int":
		return fmt.Sprintf("ballrt.StrToInt(%s)", V())
	case "string_to_double":
		return fmt.Sprintf("ballrt.StrToDouble(%s)", V())
	case "string_to_upper":
		return fmt.Sprintf("ballrt.StrUpper(%s)", V())
	case "string_to_lower":
		return fmt.Sprintf("ballrt.StrLower(%s)", V())
	case "string_trim":
		return fmt.Sprintf("ballrt.StrTrim(%s)", V())
	case "string_contains":
		return fmt.Sprintf("ballrt.StrContains(%s, %s)", c.arg(f, "value", "left"), c.arg(f, "search", "right", "substring"))
	case "string_starts_with":
		return fmt.Sprintf("ballrt.StrStartsWith(%s, %s)", c.arg(f, "value", "left"), c.arg(f, "prefix", "right"))
	case "string_ends_with":
		return fmt.Sprintf("ballrt.StrEndsWith(%s, %s)", c.arg(f, "value", "left"), c.arg(f, "suffix", "right"))
	case "string_index_of":
		return fmt.Sprintf("ballrt.StrIndexOf(%s, %s)", c.arg(f, "value", "left"), c.arg(f, "search", "right", "substring"))
	case "string_split":
		return fmt.Sprintf("ballrt.StrSplit(%s, %s)", c.arg(f, "value", "left"), c.arg(f, "separator", "right"))
	case "string_replace_all":
		return fmt.Sprintf("ballrt.StrReplaceAll(%s, %s, %s)", c.arg(f, "value"), c.arg(f, "from", "pattern"), c.arg(f, "to", "replacement"))
	case "string_substring":
		start := c.arg(f, "start")
		end := "ballrt.Value(nil)"
		if hasField(f, "end") {
			end = c.arg(f, "end")
		}
		return fmt.Sprintf("ballrt.Substring(%s, %s, %s)", c.arg(f, "value"), start, end)

	// ── Numeric conversion ───────────────────────────────────────────────
	case "to_int":
		return fmt.Sprintf("ballrt.ToInt(%s)", V())
	case "to_double":
		return fmt.Sprintf("ballrt.ToDouble(%s)", V())

	// ── Math ─────────────────────────────────────────────────────────────
	case "math_abs":
		return fmt.Sprintf("ballrt.MathAbs(%s)", V())
	case "math_floor":
		return fmt.Sprintf("ballrt.MathFloor(%s)", V())
	case "math_ceil":
		return fmt.Sprintf("ballrt.MathCeil(%s)", V())
	case "math_round":
		return fmt.Sprintf("ballrt.MathRound(%s)", V())
	case "math_sqrt":
		return fmt.Sprintf("ballrt.MathSqrt(%s)", V())
	case "math_pow":
		return fmt.Sprintf("ballrt.MathPow(%s, %s)", c.arg(f, "base", "left", "x"), c.arg(f, "exponent", "right", "y"))
	case "math_min":
		return fmt.Sprintf("ballrt.MathMin(%s, %s)", L(), R())
	case "math_max":
		return fmt.Sprintf("ballrt.MathMax(%s, %s)", L(), R())

	// ── Indexing / field mutation ────────────────────────────────────────
	case "index":
		return fmt.Sprintf("ballrt.Index(%s, %s)", c.arg(f, "target", "value", "object"), c.arg(f, "index", "key"))
	case "assign":
		return c.compileAssign(f)

	// ── Conditional expression / control flow ────────────────────────────
	case "if":
		return c.compileIf(f)
	case "for":
		return c.compileFor(f)
	case "while":
		return c.compileWhile(f)
	case "do_while":
		return c.compileDoWhile(f)
	case "for_in", "for_each":
		return c.compileForIn(f)
	case "return":
		if hasField(f, "value") {
			return fmt.Sprintf("ballrt.Return(%s)", c.arg(f, "value"))
		}
		return "ballrt.Return(ballrt.Value(nil))"
	case "break":
		return fmt.Sprintf("ballrt.Break(%s)", strconv.Quote(stringLiteralField(f, "label")))
	case "continue":
		return fmt.Sprintf("ballrt.Continue(%s)", strconv.Quote(stringLiteralField(f, "label")))
	case "throw":
		return fmt.Sprintf("ballrt.Throw(%s)", c.arg(f, "value", "exception"))
	case "invoke":
		return fmt.Sprintf("ballrt.Call(%s, %s)", c.arg(f, "function", "target", "callee"), c.arg(f, "argument", "arg", "input", "value"))

	default:
		c.fail("unsupported base function %s.%s", call.GetModule(), fn)
		return "ballrt.Value(nil) /* unsupported: " + call.GetModule() + "." + fn + " */"
	}
}

// compileIf lowers std.if to a native Go if inside an IIFE (value position),
// evaluating only the taken branch (lazy — invariant #4).
func (c *Compiler) compileIf(f map[string]*ballv1.Expression) string {
	cond := c.arg(f, "condition")
	then := c.arg(f, "then")
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	fmt.Fprintf(&b, "\t\tif ballrt.Truthy(%s) {\n", cond)
	fmt.Fprintf(&b, "\t\t\treturn %s\n\t\t}\n", then)
	if hasField(f, "else") {
		fmt.Fprintf(&b, "\t\treturn %s\n", c.arg(f, "else"))
	} else {
		b.WriteString("\t\treturn ballrt.Value(nil)\n")
	}
	b.WriteString("\t}()")
	return b.String()
}

// compileFor lowers std.for to a native Go for loop inside an IIFE. init/update
// are compiled as statements; the body's break/continue are recovered by
// ballrt.RunLoopBody (so they cross the IIFE boundary).
func (c *Compiler) compileFor(f map[string]*ballv1.Expression) string {
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	if e, ok := f["init"]; ok {
		b.WriteString(indent(c.compileLoopInit(e), "\t"))
	}
	cond := "true"
	if hasField(f, "condition") {
		cond = "ballrt.Truthy(" + c.arg(f, "condition") + ")"
	}
	fmt.Fprintf(&b, "\t\tfor %s {\n", cond)
	fmt.Fprintf(&b, "\t\t\tif ballrt.RunLoopBody(%q, func() { _ = %s }) {\n\t\t\t\tbreak\n\t\t\t}\n", "", c.loopBody(f))
	if e, ok := f["update"]; ok {
		fmt.Fprintf(&b, "\t\t\t_ = %s\n", c.compileExpr(e))
	}
	b.WriteString("\t\t}\n\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

// compileWhile lowers std.while to a native Go for loop with a condition.
func (c *Compiler) compileWhile(f map[string]*ballv1.Expression) string {
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	fmt.Fprintf(&b, "\t\tfor ballrt.Truthy(%s) {\n", c.arg(f, "condition"))
	fmt.Fprintf(&b, "\t\t\tif ballrt.RunLoopBody(%q, func() { _ = %s }) {\n\t\t\t\tbreak\n\t\t\t}\n", "", c.loopBody(f))
	b.WriteString("\t\t}\n\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

// compileDoWhile lowers std.do_while (body runs at least once).
func (c *Compiler) compileDoWhile(f map[string]*ballv1.Expression) string {
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	b.WriteString("\t\tfor {\n")
	fmt.Fprintf(&b, "\t\t\tif ballrt.RunLoopBody(%q, func() { _ = %s }) {\n\t\t\t\tbreak\n\t\t\t}\n", "", c.loopBody(f))
	fmt.Fprintf(&b, "\t\t\tif !ballrt.Truthy(%s) {\n\t\t\t\tbreak\n\t\t\t}\n", c.arg(f, "condition"))
	b.WriteString("\t\t}\n\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

// compileForIn lowers std.for_in / std.for_each to `for _, v := range
// ballrt.Iterate(iterable)`, binding the loop variable.
func (c *Compiler) compileForIn(f map[string]*ballv1.Expression) string {
	variable := stringLiteralField(f, "variable")
	if variable == "" {
		variable = "__it"
	}
	vn := sanitize(variable)
	c.pushScope()
	c.bind(variable)
	body := c.loopBody(f)
	c.popScope()

	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	fmt.Fprintf(&b, "\t\tfor _, %s := range ballrt.Iterate(%s) {\n", vn, c.arg(f, "iterable", "collection", "list"))
	fmt.Fprintf(&b, "\t\t\t_ = %s\n", vn)
	fmt.Fprintf(&b, "\t\t\tif ballrt.RunLoopBody(%q, func() { _ = %s }) {\n\t\t\t\tbreak\n\t\t\t}\n", "", body)
	b.WriteString("\t\t}\n\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

// loopBody compiles a loop's "body" field. It is bound inside compileForIn's
// scope (so the loop variable is in scope for a for_in body).
func (c *Compiler) loopBody(f map[string]*ballv1.Expression) string {
	if e, ok := f["body"]; ok {
		return c.compileExpr(e)
	}
	return "ballrt.Value(nil)"
}

// compileLoopInit compiles a for-loop's init clause as Go statements (rather
// than a value): a block's let-bindings hoist into the loop's IIFE scope so the
// condition/update/body can reference them; any other init is evaluated for
// effect.
func (c *Compiler) compileLoopInit(e *ballv1.Expression) string {
	if blk := e.GetBlock(); blk != nil {
		var b strings.Builder
		b.WriteString(c.compileStatements(blk.GetStatements()))
		if blk.GetResult() != nil {
			fmt.Fprintf(&b, "_ = %s\n", c.compileExpr(blk.GetResult()))
		}
		return b.String()
	}
	return fmt.Sprintf("_ = %s\n", c.compileExpr(e))
}

// compileAssign lowers std.assign. A reference target reassigns the (closure-
// captured) Go local; a field/index target routes through the runtime
// read-modify-write helpers.
func (c *Compiler) compileAssign(f map[string]*ballv1.Expression) string {
	target, ok := f["target"]
	if !ok {
		c.fail("assign: missing target")
		return "ballrt.Value(nil)"
	}
	value := c.arg(f, "value")

	if ref := target.GetReference(); ref != nil {
		tn := sanitize(ref.GetName())
		return fmt.Sprintf("func() ballrt.Value { __v := %s; %s = __v; return __v }()", value, tn)
	}
	if fa := target.GetFieldAccess(); fa != nil {
		obj := c.compileExpr(fa.GetObject())
		return fmt.Sprintf("ballrt.FieldSet(%s, %q, %s)", obj, fa.GetField(), value)
	}
	// An index target: assign into target[index] = value. The Ball index node is
	// a std.index call; recover its target/index from that call's input.
	if call := target.GetCall(); call != nil && call.GetFunction() == "index" {
		idxFields := fieldMap(call)
		return fmt.Sprintf("ballrt.SetIndex(%s, %s, %s)",
			c.arg(idxFields, "target", "value", "object"), c.arg(idxFields, "index", "key"), value)
	}
	c.fail("assign: unsupported target shape %T", target.GetExpr())
	return "ballrt.Value(nil)"
}
