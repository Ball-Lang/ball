package compiler

import (
	"fmt"
	"strconv"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// arg compiles a named input field of a base call, or a null placeholder.
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

// compileBaseCall is the base-function dispatch table. Control flow lowers to
// native Go inside IIFEs evaluated lazily (invariant #4); return/break/continue/
// throw become ballrt flow signals so they cross the IIFE boundaries. An unknown
// base function is a fail-loud compile error (issue #55).
func (c *Compiler) compileBaseCall(call *ballv1.FunctionCall) string {
	mod := call.GetModule()
	fn := call.GetFunction()
	f := fieldMap(call)

	switch mod {
	case "ball_proto":
		return c.compileProtoCall(call, f)
	case "std_collections":
		return c.compileCollectionsCall(call, f)
	}

	L := func() string { return c.arg(f, "left") }
	R := func() string { return c.arg(f, "right") }
	V := func() string { return c.arg(f, "value") }

	switch fn {
	// ── I/O ──────────────────────────────────────────────────────────────
	case "print":
		return fmt.Sprintf("ballrt.Print(%s)", c.arg(f, "message", "value"))
	case "print_error":
		return fmt.Sprintf("ballrt.PrintError(%s)", c.arg(f, "message", "value"))

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

	// ── Bitwise ──────────────────────────────────────────────────────────
	case "bitwise_and":
		return fmt.Sprintf("ballrt.BitwiseAnd(%s, %s)", L(), R())
	case "bitwise_or":
		return fmt.Sprintf("ballrt.BitwiseOr(%s, %s)", L(), R())
	case "bitwise_xor":
		return fmt.Sprintf("ballrt.BitwiseXor(%s, %s)", L(), R())
	case "bitwise_not":
		return fmt.Sprintf("ballrt.BitwiseNot(%s)", V())
	case "left_shift":
		return fmt.Sprintf("ballrt.LeftShift(%s, %s)", L(), R())
	case "right_shift":
		return fmt.Sprintf("ballrt.RightShift(%s, %s)", L(), R())
	case "unsigned_right_shift":
		return fmt.Sprintf("ballrt.UnsignedRightShift(%s, %s)", L(), R())

	// ── Comparison ────────────────────────────────────────────────────────
	case "equals":
		return fmt.Sprintf("ballrt.Eq(%s, %s)", L(), R())
	case "not_equals":
		return fmt.Sprintf("ballrt.Neq(%s, %s)", L(), R())
	case "less_than":
		return fmt.Sprintf("ballrt.Lt(%s, %s)", L(), R())
	case "greater_than":
		return fmt.Sprintf("ballrt.Gt(%s, %s)", L(), R())
	case "lte", "less_than_or_equal":
		return fmt.Sprintf("ballrt.Lte(%s, %s)", L(), R())
	case "gte", "greater_than_or_equal":
		return fmt.Sprintf("ballrt.Gte(%s, %s)", L(), R())

	// ── Logic ─────────────────────────────────────────────────────────────
	case "and":
		return fmt.Sprintf("(ballrt.Truthy(%s) && ballrt.Truthy(%s))", L(), R())
	case "or":
		return fmt.Sprintf("(ballrt.Truthy(%s) || ballrt.Truthy(%s))", L(), R())
	case "not":
		return fmt.Sprintf("ballrt.Not(%s)", V())
	case "null_coalesce":
		return fmt.Sprintf("func() ballrt.Value { __l := %s; if __l != nil { return __l }; return %s }()", L(), R())

	// ── Type ops ──────────────────────────────────────────────────────────
	case "is_type", "is":
		return fmt.Sprintf("ballrt.IsType(%s, %s)", c.arg(f, "value", "object"), c.typeName(f))
	case "is_not_type", "is_not":
		return fmt.Sprintf("ballrt.IsNotType(%s, %s)", c.arg(f, "value", "object"), c.typeName(f))
	case "as_type", "as", "cast":
		return fmt.Sprintf("ballrt.AsType(%s, %s)", c.arg(f, "value", "object"), c.typeName(f))

	// ── Strings & conversion ─────────────────────────────────────────────
	case "concat", "string_concat":
		return fmt.Sprintf("ballrt.Concat(%s, %s)", c.arg(f, "left", "value"), c.arg(f, "right", "other"))
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
	case "string_trim_start":
		return fmt.Sprintf("ballrt.StrTrimStart(%s)", V())
	case "string_trim_end":
		return fmt.Sprintf("ballrt.StrTrimEnd(%s)", V())
	case "string_runes":
		return fmt.Sprintf("ballrt.StrRunes(%s)", V())
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
		end := "ballrt.Value(nil)"
		if hasField(f, "end") {
			end = c.arg(f, "end")
		}
		return fmt.Sprintf("ballrt.Substring(%s, %s, %s)", c.arg(f, "value"), c.arg(f, "start"), end)
	case "string_is_empty":
		return fmt.Sprintf("ballrt.StrIsEmpty(%s)", V())
	case "string_code_unit_at":
		return fmt.Sprintf("ballrt.StrCodeUnitAt(%s, %s)", c.arg(f, "value"), c.arg(f, "index"))
	case "string_last_index_of":
		return fmt.Sprintf("ballrt.StrLastIndexOf(%s, %s)", c.arg(f, "value", "left"), c.arg(f, "search", "right", "substring"))
	case "string_replace":
		return fmt.Sprintf("ballrt.StrReplace(%s, %s, %s)", c.arg(f, "value"), c.arg(f, "from", "pattern"), c.arg(f, "to", "replacement"))
	case "string_pad_left":
		return fmt.Sprintf("ballrt.StrPadLeft(%s, %s, %s)", c.arg(f, "value"), c.arg(f, "width"), c.arg(f, "padding"))
	case "string_pad_right":
		return fmt.Sprintf("ballrt.StrPadRight(%s, %s, %s)", c.arg(f, "value"), c.arg(f, "width"), c.arg(f, "padding"))
	case "compare_to":
		return fmt.Sprintf("ballrt.CompareTo(%s, %s)", c.arg(f, "left", "value"), c.arg(f, "right", "other"))
	case "null_check":
		return fmt.Sprintf("ballrt.NullCheck(%s)", V())

	// ── Numeric conversion + formatting ──────────────────────────────────
	case "to_int":
		return fmt.Sprintf("ballrt.ToInt(%s)", V())
	case "to_double":
		return fmt.Sprintf("ballrt.ToDouble(%s)", V())
	case "to_string_as_fixed":
		return fmt.Sprintf("ballrt.ToStringAsFixed(%s, %s)", V(), c.arg(f, "digits", "fractionDigits"))
	case "to_string_as_exponential":
		exp := "ballrt.Value(nil)"
		if hasField(f, "digits", "fractionDigits") {
			exp = c.arg(f, "digits", "fractionDigits")
		}
		return fmt.Sprintf("ballrt.ToStringAsExponential(%s, %s)", V(), exp)
	case "to_string_as_precision":
		return fmt.Sprintf("ballrt.ToStringAsPrecision(%s, %s)", V(), c.arg(f, "precision"))

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
	case "math_trunc":
		return fmt.Sprintf("ballrt.MathTrunc(%s)", V())
	case "math_sign":
		return fmt.Sprintf("ballrt.MathSign(%s)", V())
	case "math_is_finite":
		return fmt.Sprintf("ballrt.MathIsFinite(%s)", V())
	case "math_is_infinite":
		return fmt.Sprintf("ballrt.MathIsInfinite(%s)", V())
	case "math_clamp":
		return fmt.Sprintf("ballrt.MathClamp(%s, %s, %s)", V(), c.arg(f, "min", "lower", "lowerLimit"), c.arg(f, "max", "upper", "upperLimit"))
	case "math_gcd":
		return fmt.Sprintf("ballrt.MathGcd(%s, %s)", c.arg(f, "value", "left", "a"), c.arg(f, "other", "right", "b"))
	case "round_to_double":
		return fmt.Sprintf("ballrt.RoundToDouble(%s)", V())
	case "floor_to_double":
		return fmt.Sprintf("ballrt.FloorToDouble(%s)", V())
	case "ceil_to_double":
		return fmt.Sprintf("ballrt.CeilToDouble(%s)", V())
	case "truncate_to_double":
		return fmt.Sprintf("ballrt.TruncateToDouble(%s)", V())

	// ── std_convert ──────────────────────────────────────────────────────
	case "json_encode":
		return fmt.Sprintf("ballrt.JSONEncode(%s)", V())
	case "json_decode":
		return fmt.Sprintf("ballrt.JSONDecode(%s)", V())
	case "utf8_encode":
		return fmt.Sprintf("ballrt.UTF8Encode(%s)", V())
	case "utf8_decode":
		return fmt.Sprintf("ballrt.UTF8Decode(%s)", V())
	case "base64_encode":
		return fmt.Sprintf("ballrt.Base64Encode(%s)", V())
	case "base64_decode":
		return fmt.Sprintf("ballrt.Base64Decode(%s)", V())

	// ── Indexing / field mutation ────────────────────────────────────────
	case "index", "null_aware_index":
		return fmt.Sprintf("ballrt.IndexGet(%s, %s)", c.arg(f, "target", "value", "object"), c.arg(f, "index", "key"))
	case "assign":
		return c.compileAssign(call)
	case "pre_increment":
		return c.compilePreMutate(call, "+=")
	case "post_increment":
		return c.compilePostMutate(call, "+=")
	case "pre_decrement":
		return c.compilePreMutate(call, "-=")
	case "post_decrement":
		return c.compilePostMutate(call, "-=")

	// ── Collection / value constructors ──────────────────────────────────
	case "map_create":
		return c.compileMapCreate(call)
	case "map_add_entry":
		return fmt.Sprintf("ballrt.MapAddEntry(%s, %s, %s)", c.arg(f, "map", "target"), c.arg(f, "key"), c.arg(f, "value"))
	case "map_spread", "map_merge_into":
		return fmt.Sprintf("ballrt.MapSpread(%s, %s)", c.arg(f, "map", "target"), c.arg(f, "value", "source", "other"))
	case "set_create":
		if hasField(f, "list", "elements", "set", "value") {
			return fmt.Sprintf("ballrt.SetCreate(%s)", c.arg(f, "list", "elements", "set", "value"))
		}
		return "ballrt.SetCreate(ballrt.Value(nil))"
	case "record":
		return c.compileRecord(f)
	case "spread":
		return c.arg(f, "value")
	case "paren", "await", "parenthesized":
		return V()
	case "invoke":
		// A single-argument first-class call `f(x)` packs its argument under
		// `arg0` (e.g. the self-host list_sort's `(cb as Function)({...})`); the
		// `argument`/`arg`/`input`/`value` aliases missed it, so the argument was
		// dropped and every closure invoked with null (comparators saw no a/b).
		return fmt.Sprintf("ballrt.Invoke(%s, %s)", c.arg(f, "function", "target", "callee"), c.arg(f, "argument", "arg", "input", "value", "arg0"))
	case "typed_list", "list_literal":
		// A typed list literal `<T>[a, ...spread, b]` carries its members in an
		// `elements` listValue (with possible spread / collection_if /
		// collection_for elements) — NOT a `list`/`value` field. Compile it as a
		// list literal so spreads splice; the old `arg(f,"list","value")` path
		// found neither field and produced `ListCopy(nil)` (an empty list),
		// silently dropping every element — which wedged every set op that builds
		// its result via `_ballSetOf(<Object?>[...])` (union/add/intersection).
		if e, ok := f["elements"]; ok {
			if lit := e.GetLiteral(); lit != nil && lit.GetListValue() != nil {
				return c.compileListLiteral(lit.GetListValue())
			}
			return fmt.Sprintf("ballrt.ListCopy(%s)", c.compileExpr(e))
		}
		return fmt.Sprintf("ballrt.ListCopy(%s)", c.arg(f, "list", "value"))

	// ── Control flow ──────────────────────────────────────────────────────
	case "if":
		return c.compileIf(f)
	case "switch":
		return c.compileSwitch(call, f, false)
	case "switch_expr":
		return c.compileSwitch(call, f, true)
	case "for":
		return c.compileFor(f)
	case "while":
		return c.compileWhile(f)
	case "do_while":
		return c.compileDoWhile(f)
	case "for_in", "for_each":
		return c.compileForIn(f)
	case "try":
		return c.compileTry(f)
	case "return":
		if hasField(f, "value") {
			return fmt.Sprintf("ballrt.Return(%s)", c.arg(f, "value"))
		}
		return "ballrt.Return(ballrt.Value(nil))"
	case "break":
		return fmt.Sprintf("ballrt.Break(%s)", strconv.Quote(stringLiteralField(f, "label")))
	case "continue":
		// `continue <caseLabel>` inside a labelled switch is Dart's goto: jump to
		// that case's arm with no subject re-check. Innermost enclosing goto-switch
		// wins; a label naming no case is an ordinary labelled-loop continue.
		if lbl := stringLiteralField(f, "label"); lbl != "" {
			for i := len(c.gotoSwitches) - 1; i >= 0; i-- {
				gs := c.gotoSwitches[i]
				if idx, ok := gs.labels[lbl]; ok {
					return fmt.Sprintf("func() ballrt.Value { %s = %d; return ballrt.Break(%q) }()", gs.stateVar, idx, gs.label)
				}
			}
		}
		return fmt.Sprintf("ballrt.Continue(%s)", strconv.Quote(stringLiteralField(f, "label")))
	case "throw":
		return fmt.Sprintf("ballrt.Throw(%s)", c.arg(f, "value", "exception"))
	case "rethrow":
		return "ballrt.Rethrow()"
	case "assert":
		msg := "ballrt.Value(nil)"
		if hasField(f, "message") {
			msg = c.arg(f, "message")
		}
		return fmt.Sprintf("ballrt.Assert(%s, %s)", c.arg(f, "condition"), msg)

	default:
		c.fail("unsupported base function %s.%s", mod, fn)
		return "ballrt.Value(nil) /* unsupported: " + mod + "." + fn + " */"
	}
}

// typeName extracts a base call's target type name (a string literal `type`
// field), quoted for Go.
func (c *Compiler) typeName(f map[string]*ballv1.Expression) string {
	name := stringLiteralField(f, "type")
	if name == "" {
		name = stringLiteralField(f, "typeName")
	}
	return strconv.Quote(name)
}

// compileRecord builds an anonymous record as a *Map of its named fields.
func (c *Compiler) compileRecord(f map[string]*ballv1.Expression) string {
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n\t\t__r := ballrt.NewMap()\n")
	for name, e := range f {
		fmt.Fprintf(&b, "\t\t__r.Set(%q, %s)\n", name, c.compileExpr(e))
	}
	b.WriteString("\t\treturn __r\n\t}()")
	return b.String()
}

// compileIf lowers std.if to a native Go if inside an IIFE (lazy — invariant #4).
func (c *Compiler) compileIf(f map[string]*ballv1.Expression) string {
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	fmt.Fprintf(&b, "\t\tif ballrt.Truthy(%s) {\n", c.arg(f, "condition"))
	fmt.Fprintf(&b, "\t\t\treturn %s\n\t\t}\n", c.arg(f, "then"))
	if hasField(f, "else") {
		fmt.Fprintf(&b, "\t\treturn %s\n", c.arg(f, "else"))
	} else {
		b.WriteString("\t\treturn ballrt.Value(nil)\n")
	}
	b.WriteString("\t}()")
	return b.String()
}

// compileFor lowers std.for to a native Go for loop inside an IIFE.
func (c *Compiler) compileFor(f map[string]*ballv1.Expression) string {
	c.pushScope()
	defer c.popScope()
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

func (c *Compiler) compileWhile(f map[string]*ballv1.Expression) string {
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	fmt.Fprintf(&b, "\t\tfor ballrt.Truthy(%s) {\n", c.arg(f, "condition"))
	fmt.Fprintf(&b, "\t\t\tif ballrt.RunLoopBody(%q, func() { _ = %s }) {\n\t\t\t\tbreak\n\t\t\t}\n", "", c.loopBody(f))
	b.WriteString("\t\t}\n\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

func (c *Compiler) compileDoWhile(f map[string]*ballv1.Expression) string {
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	b.WriteString("\t\tfor {\n")
	fmt.Fprintf(&b, "\t\t\tif ballrt.RunLoopBody(%q, func() { _ = %s }) {\n\t\t\t\tbreak\n\t\t\t}\n", "", c.loopBody(f))
	fmt.Fprintf(&b, "\t\t\tif !ballrt.Truthy(%s) {\n\t\t\t\tbreak\n\t\t\t}\n", c.arg(f, "condition"))
	b.WriteString("\t\t}\n\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

func (c *Compiler) compileForIn(f map[string]*ballv1.Expression) string {
	variable := stringLiteralField(f, "variable")
	if variable == "" {
		variable = "__it"
	}
	vn := sanitize(variable)
	iter := c.arg(f, "iterable", "collection", "list")
	c.pushScope()
	c.bind(variable)
	body := c.loopBody(f)
	c.popScope()

	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	fmt.Fprintf(&b, "\t\tfor _, %s := range ballrt.Iterate(%s) {\n", vn, iter)
	fmt.Fprintf(&b, "\t\t\t_ = %s\n", vn)
	fmt.Fprintf(&b, "\t\t\tif ballrt.RunLoopBody(%q, func() { _ = %s }) {\n\t\t\t\tbreak\n\t\t\t}\n", "", body)
	b.WriteString("\t\t}\n\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

func (c *Compiler) loopBody(f map[string]*ballv1.Expression) string {
	if e, ok := f["body"]; ok {
		return c.compileExpr(e)
	}
	return "ballrt.Value(nil)"
}

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

// compileSwitch lowers std.switch / std.switch_expr to an if-else chain inside an
// IIFE. Fall-through (a body-less case sharing the next case's body) accumulates
// conditions. In statement mode a matched body runs for effect; in expr mode a
// matched body's value is returned. A statement switch carrying case labels is a
// goto-switch and lowers to a state machine instead.
func (c *Compiler) compileSwitch(call *ballv1.FunctionCall, f map[string]*ballv1.Expression, exprMode bool) string {
	cases := messageList(f, "cases")
	if !exprMode && hasCaseLabels(cases) {
		return c.compileGotoSwitch(f, cases)
	}

	uid := c.uid()
	subj := fmt.Sprintf("__subj%d", uid)
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	fmt.Fprintf(&b, "\t\t%s := %s\n\t\t_ = %s\n", subj, c.arg(f, "subject"), subj)

	var defaultCase *ballv1.MessageCreation
	var pending []string
	for _, caseMc := range cases {
		cf := messageCreationFields(caseMc)
		if boolLiteralField(cf, "is_default") {
			defaultCase = caseMc
			continue
		}
		res := c.compileCasePattern(subj, cf)
		bodyExpr, present := cf["body"]
		// Dart fall-through (`case A: case B: body;`) encodes the leading
		// labels as cases whose `body` is an EMPTY block (`{"block":{}}`) or a
		// notSet literal — not an absent field. Such a case falls through to the
		// next case that carries a real body: accumulate its match condition
		// instead of emitting a terminal (no-op) arm. Without this, three of the
		// four increment/decrement functions the engine routes through a shared
		// fall-through (`post_increment`/`pre_increment`/`post_decrement` →
		// `pre_decrement: _evalIncDec`) compiled to empty arms, silently
		// no-op'ing `i++`/`i--` and wedging every for/while loop in an infinite
		// spin. Mirrors the Rust compiler's `is_empty_switch_body` test.
		//
		// A case with a `when` guard is never an empty fall-through, even with an
		// empty body: its guard still has to run.
		//
		// STATEMENT MODE ONLY. A switch EXPRESSION has no fall-through — every arm
		// carries a value — and Ball encodes the `null` literal as a value-less
		// Literal (encoder: `Expression()..literal = Literal()`), the very shape
		// isEmptySwitchBody reads as "empty". Applied to an expression, the test
		// DELETES every `_ => null` arm and folds its condition into the next one,
		// so a non-final `=> null` arm returns the FOLLOWING arm's value: the
		// engine's own `unwrap` (`BallNull() => null` ahead of `_ => val`) handed
		// back the wrapper instead of null. Compiles, exits 0, wrong answer.
		if (!present || (!exprMode && isEmptySwitchBody(bodyExpr))) && !hasField(cf, "guard") {
			pending = append(pending, res.cond)
			continue
		}
		pending = append(pending, res.cond)
		combined := "(" + strings.Join(pending, " || ") + ")"
		pending = nil
		b.WriteString(c.emitSwitchArm(combined, res.bindings, cf, bodyExpr, exprMode))
	}

	if defaultCase != nil {
		cf := messageCreationFields(defaultCase)
		bodyExpr, ok := cf["body"]
		if ok && exprMode {
			fmt.Fprintf(&b, "\t\treturn %s\n\t}()", c.compileExpr(bodyExpr))
			return b.String()
		}
		if ok {
			fmt.Fprintf(&b, "\t\t_ = %s\n", c.compileExpr(bodyExpr))
		}
		b.WriteString("\t\treturn ballrt.Value(nil)\n\t}()")
		return b.String()
	}
	// A switch that matched no arm evaluates to Ball null — the same tail the TS
	// compiler emits (`defaultBody ? … : "undefined"`). It must NOT throw: the
	// engine's own oneof dispatchers rely on the null tail, and #55's fail-loud
	// rule is about a pattern KIND the compiler cannot lower (a compile-time
	// c.fail in pattern.go), not about a legal runtime fall-through in the IR.
	b.WriteString("\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

// emitSwitchArm emits one matched arm: the condition (plus its guard), the
// binders re-materialized as locals, then the body.
func (c *Compiler) emitSwitchArm(cond string, binds []patternBinding, cf map[string]*ballv1.Expression, bodyExpr *ballv1.Expression, exprMode bool) string {
	c.pushScope()
	defer c.popScope()
	for _, bd := range binds {
		c.bind(bd.name)
	}
	decls := c.bindDecls(binds)

	full := cond
	if g, ok := cf["guard"]; ok {
		// A pattern that matches but whose guard is false is NOT a match: control
		// falls through to the next case. Because the guard is just another
		// conjunct of this arm's `if`, that fall-through is free. Go's &&
		// short-circuits, so the binders are only computed once the pattern matched.
		full = fmt.Sprintf("%s && ballrt.Truthy(func() ballrt.Value {\n%s\t\t\treturn %s\n\t\t}())",
			cond, indent(decls, "\t\t\t"), c.compileExpr(g))
	}

	var b strings.Builder
	fmt.Fprintf(&b, "\t\tif %s {\n", full)
	b.WriteString(indent(decls, "\t\t\t"))
	if exprMode {
		fmt.Fprintf(&b, "\t\t\treturn %s\n\t\t}\n", c.compileExpr(bodyExpr))
	} else {
		fmt.Fprintf(&b, "\t\t\t_ = %s\n\t\t\treturn ballrt.Value(nil)\n\t\t}\n", c.compileExpr(bodyExpr))
	}
	return b.String()
}

// gotoArm is one arm of a goto-switch state machine.
type gotoArm struct {
	cond      string
	binds     []patternBinding
	body      *ballv1.Expression
	guard     *ballv1.Expression
	isDefault bool
}

// hasCaseLabels reports whether any case carries a label — Dart's
// `one: case 1:`, the target of a `continue one;` goto.
func hasCaseLabels(cases []*ballv1.MessageCreation) bool {
	for _, mc := range cases {
		if stringField(messageCreationFields(mc), "label") != "" {
			return true
		}
	}
	return false
}

// compileGotoSwitch lowers a labelled switch to a state machine.
//
// Dart's `continue <caseLabel>` is a GOTO: it transfers control to that case's
// body with no subject re-check. An if-else chain cannot express that, so the
// arms become numbered states driven by a loop:
//
//	state = <first matching arm, else the default>
//	for state >= 0 { cur, state = state, -1; run arm[cur] }
//
// An arm that runs to completion leaves state at -1 and the switch exits (arms
// never fall through). `continue one` sets state to that arm's index and unwinds
// to the driver with a break carrying this switch's synthetic label; a bare
// `break` unwinds with the empty label. ballrt.RunLoopBody recovers both (and
// re-panics anything else — a return, or a labelled jump aimed at an enclosing
// loop), which is also what keeps a case-body `break` from escaping into the
// enclosing loop.
func (c *Compiler) compileGotoSwitch(f map[string]*ballv1.Expression, cases []*ballv1.MessageCreation) string {
	uid := c.uid()
	subj := fmt.Sprintf("__subj%d", uid)
	stateVar := fmt.Sprintf("__state%d", uid)
	swLabel := fmt.Sprintf("__sw%d", uid)

	// Pass 1: arms, and the label → arm-index map. Bodies are compiled only in
	// pass 2, because a body may `continue` to a label defined by a LATER case.
	var arms []gotoArm
	labelToArm := map[string]int{}
	var pendingLabels []string
	var pendingConds []string
	defaultArm := -1

	for _, mc := range cases {
		cf := messageCreationFields(mc)
		if lbl := stringField(cf, "label"); lbl != "" {
			pendingLabels = append(pendingLabels, lbl)
		}
		if boolLiteralField(cf, "is_default") {
			defaultArm = len(arms)
			arms = append(arms, gotoArm{cond: "true", body: cf["body"], isDefault: true})
			for _, l := range pendingLabels {
				labelToArm[l] = defaultArm
			}
			pendingLabels = nil
			continue
		}
		res := c.compileCasePattern(subj, cf)
		bodyExpr, present := cf["body"]
		guard, hasGuard := cf["guard"]
		if (!present || isEmptySwitchBody(bodyExpr)) && !hasGuard {
			// An empty fall-through case: its condition merges into the next arm, and
			// a label on it targets that same absorbing arm (jumping there and
			// falling through to it are the same thing).
			pendingConds = append(pendingConds, res.cond)
			continue
		}
		pendingConds = append(pendingConds, res.cond)
		idx := len(arms)
		arms = append(arms, gotoArm{
			cond:  "(" + strings.Join(pendingConds, " || ") + ")",
			binds: res.bindings,
			body:  bodyExpr,
			guard: guard,
		})
		pendingConds = nil
		for _, l := range pendingLabels {
			labelToArm[l] = idx
		}
		pendingLabels = nil
	}

	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	fmt.Fprintf(&b, "\t\t%s := %s\n\t\t_ = %s\n", subj, c.arg(f, "subject"), subj)
	fmt.Fprintf(&b, "\t\t%s := -1\n", stateVar)

	// Entry-arm selection, in source order. The default is not a candidate here —
	// it is the fallback when nothing matched.
	for i, a := range arms {
		if a.isDefault {
			continue
		}
		cond := a.cond
		if a.guard != nil {
			c.pushScope()
			for _, bd := range a.binds {
				c.bind(bd.name)
			}
			cond = fmt.Sprintf("%s && ballrt.Truthy(func() ballrt.Value {\n%s\t\t\treturn %s\n\t\t}())",
				cond, indent(c.bindDecls(a.binds), "\t\t\t"), c.compileExpr(a.guard))
			c.popScope()
		}
		fmt.Fprintf(&b, "\t\tif %s < 0 && %s {\n\t\t\t%s = %d\n\t\t}\n", stateVar, cond, stateVar, i)
	}
	if defaultArm >= 0 {
		fmt.Fprintf(&b, "\t\tif %s < 0 {\n\t\t\t%s = %d\n\t\t}\n", stateVar, stateVar, defaultArm)
	}

	// Pass 2: the arm bodies, with the goto context live so `continue <label>`
	// resolves to a state assignment rather than a loop continue.
	c.gotoSwitches = append(c.gotoSwitches, gotoSwitch{stateVar: stateVar, label: swLabel, labels: labelToArm})
	var armSrc strings.Builder
	for i, a := range arms {
		fmt.Fprintf(&armSrc, "\t\t\tcase %d:\n", i)
		c.pushScope()
		for _, bd := range a.binds {
			c.bind(bd.name)
		}
		armSrc.WriteString(indent(c.bindDecls(a.binds), "\t\t\t\t"))
		fmt.Fprintf(&armSrc, "\t\t\t\t_ = %s\n", c.compileExpr(a.body))
		c.popScope()
	}
	c.gotoSwitches = c.gotoSwitches[:len(c.gotoSwitches)-1]

	fmt.Fprintf(&b, "\t\tfor %s >= 0 {\n", stateVar)
	fmt.Fprintf(&b, "\t\t\t__cur%d := %s\n\t\t\t%s = -1\n", uid, stateVar, stateVar)
	fmt.Fprintf(&b, "\t\t\t_ = ballrt.RunLoopBody(%q, func() {\n", swLabel)
	fmt.Fprintf(&b, "\t\t\t\tswitch __cur%d {\n", uid)
	b.WriteString(indent(armSrc.String(), "\t"))
	b.WriteString("\t\t\t\t}\n\t\t\t})\n\t\t}\n")
	b.WriteString("\t\treturn ballrt.Value(nil)\n\t}()")
	return b.String()
}

// isEmptySwitchBody reports whether a switch case's `body` is an empty block or
// a value-less (notSet) literal — the shape the Dart encoder emits for a
// fall-through label (`case A:` with no statements before the next case).
// Mirrors the Rust compiler's `is_empty_switch_body`.
func isEmptySwitchBody(e *ballv1.Expression) bool {
	if e == nil {
		return true
	}
	if blk := e.GetBlock(); blk != nil {
		return len(blk.GetStatements()) == 0 && blk.GetResult() == nil
	}
	if lit := e.GetLiteral(); lit != nil {
		return lit.GetValue() == nil
	}
	return false
}

// compileCasePattern builds a switch case's match condition and its binders. A
// case always carries a structured `pattern_expr`; the bare `pattern`/`value`
// fallback is for a case the encoder could not encode structurally.
func (c *Compiler) compileCasePattern(subj string, cf map[string]*ballv1.Expression) patternResult {
	if pe, ok := cf["pattern_expr"]; ok {
		return c.compilePattern(subj, pe)
	}
	return patternResult{cond: fmt.Sprintf("ballrt.Truthy(ballrt.Eq(%s, %s))", subj, c.arg(cf, "pattern", "value"))}
}

// compileTry lowers std.try to ballrt.TryCatch (body/catch/finally closures). The
// first catch clause's variable binds the thrown payload; a second stack-trace
// variable binds the caught trace.
func (c *Compiler) compileTry(f map[string]*ballv1.Expression) string {
	body := c.loopBody(f)
	catches := messageList(f, "catches")
	catchFn := "nil"
	if len(catches) > 0 {
		cf := messageCreationFields(catches[0])
		variable := stringField(cf, "variable")
		stackVar := stringField(cf, "stack_trace")
		c.pushScope()
		var cb strings.Builder
		cb.WriteString("func(__ex ballrt.Value) ballrt.Value {\n")
		if variable != "" {
			c.bind(variable)
			fmt.Fprintf(&cb, "\t\t%s := __ex\n\t\t_ = %s\n", sanitize(variable), sanitize(variable))
		}
		if stackVar != "" {
			c.bind(stackVar)
			fmt.Fprintf(&cb, "\t\t%s := ballrt.CaughtStackTrace()\n\t\t_ = %s\n", sanitize(stackVar), sanitize(stackVar))
		}
		catchBody := "ballrt.Value(nil)"
		if b, ok := cf["body"]; ok {
			catchBody = c.compileExpr(b)
		}
		fmt.Fprintf(&cb, "\t\treturn %s\n\t}", catchBody)
		c.popScope()
		catchFn = cb.String()
	}
	finallyFn := "nil"
	if e, ok := f["finally"]; ok {
		finallyFn = fmt.Sprintf("func() { _ = %s }", c.compileExpr(e))
	}
	return fmt.Sprintf("ballrt.TryCatch(func() ballrt.Value { return %s }, %s, %s)", body, catchFn, finallyFn)
}

// ── Assignment / mutation ───────────────────────────────────────────────────

// lvalue describes an assignment target.
type lvalue struct {
	kind string // "var", "field", "index", "null_index", "unsupported"
	a, b string
}

func (c *Compiler) resolveLValue(target *ballv1.Expression) lvalue {
	switch x := target.GetExpr().(type) {
	case *ballv1.Expression_Reference:
		name := x.Reference.GetName()
		if c.isLocal(name) {
			return lvalue{kind: "var", a: sanitize(name)}
		}
		if c.inInstanceMethod && c.selfRecvName != "" && c.volatileFields[name] {
			return lvalue{kind: "field", a: c.selfRecvName, b: name}
		}
		return lvalue{kind: "var", a: sanitize(name)}
	case *ballv1.Expression_FieldAccess:
		obj := c.compileExpr(x.FieldAccess.GetObject())
		return lvalue{kind: "field", a: obj, b: x.FieldAccess.GetField()}
	case *ballv1.Expression_Call:
		call := x.Call
		if call.GetModule() == "std" && (call.GetFunction() == "index" || call.GetFunction() == "null_aware_index") {
			idxFields := fieldMap(call)
			kind := "index"
			if call.GetFunction() == "null_aware_index" {
				kind = "null_index"
			}
			return lvalue{kind: kind, a: c.arg(idxFields, "target", "value", "object"), b: c.arg(idxFields, "index", "key")}
		}
	}
	return lvalue{kind: "unsupported"}
}

func (c *Compiler) compileAssign(call *ballv1.FunctionCall) string {
	f := fieldMap(call)
	op := stringLiteralField(f, "op")
	if op == "" {
		op = "="
	}
	value := c.arg(f, "value")
	target, ok := f["target"]
	if !ok {
		c.fail("assign: missing target")
		return "ballrt.Value(nil)"
	}
	return c.emitMutation(c.resolveLValue(target), op, value)
}

// compilePreMutate is the value-position pre-increment/decrement (yields the new
// value).
func (c *Compiler) compilePreMutate(call *ballv1.FunctionCall, op string) string {
	f := fieldMap(call)
	target := c.mutateTarget(f)
	return c.emitMutation(c.resolveLValue(target), op, "int64(1)")
}

// compilePostMutate is the value-position post-increment/decrement (yields the
// old value).
func (c *Compiler) compilePostMutate(call *ballv1.FunctionCall, op string) string {
	f := fieldMap(call)
	target := c.mutateTarget(f)
	lv := c.resolveLValue(target)
	if lv.kind == "var" {
		return fmt.Sprintf("func() ballrt.Value { __old := %s; %s = %s; return __old }()", lv.a, lv.a, combineOp(op, lv.a, "int64(1)"))
	}
	return "(" + c.emitMutation(lv, op, "int64(1)") + ")"
}

func (c *Compiler) mutateTarget(f map[string]*ballv1.Expression) *ballv1.Expression {
	if t, ok := f["value"]; ok {
		return t
	}
	if t, ok := f["target"]; ok {
		return t
	}
	return &ballv1.Expression{}
}

// emitMutation emits an assignment to a resolved lvalue as an IIFE expression
// yielding the new value (Go assignments are statements, not expressions).
func (c *Compiler) emitMutation(lv lvalue, op, value string) string {
	switch lv.kind {
	case "var":
		return fmt.Sprintf("func() ballrt.Value { __v := %s; %s = __v; return __v }()", combineOp(op, lv.a, value), lv.a)
	case "field":
		cur := fmt.Sprintf("ballrt.FieldGet(%s, %q)", lv.a, lv.b)
		return fmt.Sprintf("ballrt.FieldSet(%s, %q, %s)", lv.a, lv.b, combineOp(op, cur, value))
	case "index":
		cur := fmt.Sprintf("ballrt.IndexGet(%s, %s)", lv.a, lv.b)
		return fmt.Sprintf("ballrt.IndexSet(%s, %s, %s)", lv.a, lv.b, combineOp(op, cur, value))
	case "null_index":
		uid := c.uid()
		na := fmt.Sprintf("__na%d", uid)
		cur := fmt.Sprintf("ballrt.IndexGet(%s, %s)", na, lv.b)
		return fmt.Sprintf("func() ballrt.Value { %s := %s; if %s == nil { return ballrt.Value(nil) }; return ballrt.IndexSet(%s, %s, %s) }()",
			na, lv.a, na, na, lv.b, combineOp(op, cur, value))
	default:
		return "ballrt.UnsupportedBaseCall(\"std\", \"assign\")"
	}
}

// combineOp combines a read of left with right per the compound-assignment op.
func combineOp(op, left, right string) string {
	switch op {
	case "=", "":
		return right
	case "+=":
		return fmt.Sprintf("ballrt.Add(%s, %s)", left, right)
	case "-=":
		return fmt.Sprintf("ballrt.Sub(%s, %s)", left, right)
	case "*=":
		return fmt.Sprintf("ballrt.Mul(%s, %s)", left, right)
	case "/=":
		return fmt.Sprintf("ballrt.DivDouble(%s, %s)", left, right)
	case "~/=":
		return fmt.Sprintf("ballrt.IntDiv(%s, %s)", left, right)
	case "%=":
		return fmt.Sprintf("ballrt.Modulo(%s, %s)", left, right)
	case "&=":
		return fmt.Sprintf("ballrt.BitwiseAnd(%s, %s)", left, right)
	case "|=":
		return fmt.Sprintf("ballrt.BitwiseOr(%s, %s)", left, right)
	case "^=":
		return fmt.Sprintf("ballrt.BitwiseXor(%s, %s)", left, right)
	case "<<=":
		return fmt.Sprintf("ballrt.LeftShift(%s, %s)", left, right)
	case ">>=":
		return fmt.Sprintf("ballrt.RightShift(%s, %s)", left, right)
	case ">>>=":
		return fmt.Sprintf("ballrt.UnsignedRightShift(%s, %s)", left, right)
	case "??=":
		return fmt.Sprintf("ballrt.NullCoalesce(%s, %s)", left, right)
	default:
		return right
	}
}

// ── std_collections ─────────────────────────────────────────────────────────

func (c *Compiler) compileCollectionsCall(call *ballv1.FunctionCall, f map[string]*ballv1.Expression) string {
	list := func() string { return c.arg(f, "list") }
	set := func() string { return c.arg(f, "set") }
	mp := func() string { return c.arg(f, "map") }
	switch call.GetFunction() {
	case "list_get":
		return fmt.Sprintf("ballrt.ListGet(%s, %s)", list(), c.arg(f, "index"))
	case "list_length":
		return fmt.Sprintf("ballrt.ListLength(%s)", list())
	case "list_is_empty":
		return fmt.Sprintf("ballrt.ListIsEmpty(%s)", list())
	case "list_first":
		return fmt.Sprintf("ballrt.ListFirst(%s)", list())
	case "list_last":
		return fmt.Sprintf("ballrt.ListLast(%s)", list())
	case "list_contains":
		return fmt.Sprintf("ballrt.ListContains(%s, %s)", list(), c.arg(f, "value"))
	case "list_index_of":
		return fmt.Sprintf("ballrt.ListIndexOf(%s, %s)", list(), c.arg(f, "value"))
	case "list_reverse":
		return fmt.Sprintf("ballrt.ListReverse(%s)", list())
	case "list_concat":
		return fmt.Sprintf("ballrt.ListConcat(%s, %s)", list(), c.arg(f, "value", "index"))
	case "list_slice":
		return fmt.Sprintf("ballrt.ListSlice(%s, %s, %s)", list(), c.arg(f, "start"), c.arg(f, "end"))
	case "list_take":
		return fmt.Sprintf("ballrt.ListTake(%s, %s)", list(), c.arg(f, "index", "value", "count"))
	case "list_drop":
		return fmt.Sprintf("ballrt.ListDrop(%s, %s)", list(), c.arg(f, "index", "value", "count"))
	case "list_push":
		return fmt.Sprintf("ballrt.ListPush(%s, %s)", list(), c.arg(f, "value"))
	case "list_pop":
		return fmt.Sprintf("ballrt.ListPop(%s)", list())
	case "list_insert":
		return fmt.Sprintf("ballrt.ListInsert(%s, %s, %s)", list(), c.arg(f, "index"), c.arg(f, "value"))
	case "list_remove_at":
		return fmt.Sprintf("ballrt.ListRemoveAt(%s, %s)", list(), c.arg(f, "index"))
	case "list_set":
		return fmt.Sprintf("ballrt.ListSet(%s, %s, %s)", list(), c.arg(f, "index"), c.arg(f, "value"))
	case "list_clear":
		return fmt.Sprintf("ballrt.ListClear(%s)", list())
	case "list_map":
		return fmt.Sprintf("ballrt.ListMap(%s, %s)", list(), c.arg(f, "value", "callback"))
	case "list_filter":
		return fmt.Sprintf("ballrt.ListFilter(%s, %s)", list(), c.arg(f, "value", "callback"))
	case "list_all":
		return fmt.Sprintf("ballrt.ListAll(%s, %s)", list(), c.arg(f, "value", "callback"))
	case "list_any":
		return fmt.Sprintf("ballrt.ListAny(%s, %s)", list(), c.arg(f, "value", "callback"))
	case "list_sort":
		return fmt.Sprintf("ballrt.ListSort(%s, %s)", list(), c.arg(f, "value", "compare"))
	case "list_join":
		return fmt.Sprintf("ballrt.ListJoin(%s, %s)", list(), c.arg(f, "separator"))
	case "list_to_list":
		return fmt.Sprintf("ballrt.ListToList(%s)", list())
	case "map_get":
		return fmt.Sprintf("ballrt.MapGet(%s, %s)", mp(), c.arg(f, "key"))
	case "map_set":
		return fmt.Sprintf("ballrt.MapSet(%s, %s, %s)", mp(), c.arg(f, "key"), c.arg(f, "value"))
	case "map_delete":
		return fmt.Sprintf("ballrt.MapDelete(%s, %s)", mp(), c.arg(f, "key"))
	case "map_contains_key":
		return fmt.Sprintf("ballrt.MapContainsKey(%s, %s)", mp(), c.arg(f, "key"))
	case "map_contains_value":
		return fmt.Sprintf("ballrt.MapContainsValue(%s, %s)", mp(), c.arg(f, "value"))
	case "map_keys":
		return fmt.Sprintf("ballrt.MapKeys(%s)", mp())
	case "map_values":
		return fmt.Sprintf("ballrt.MapValues(%s)", mp())
	case "map_length":
		return fmt.Sprintf("ballrt.MapLength(%s)", mp())
	case "map_is_empty":
		return fmt.Sprintf("ballrt.MapIsEmpty(%s)", mp())
	case "map_merge":
		return fmt.Sprintf("ballrt.MapMerge(%s, %s)", mp(), c.arg(f, "value", "key"))
	case "map_put_if_absent":
		return fmt.Sprintf("ballrt.MapPutIfAbsent(%s, %s, %s)", mp(), c.arg(f, "key"), c.arg(f, "value"))
	case "string_join":
		return fmt.Sprintf("ballrt.StringJoin(%s, %s)", list(), c.arg(f, "separator"))
	case "set_create":
		return fmt.Sprintf("ballrt.SetCreate(%s)", c.arg(f, "list", "elements", "set"))
	case "set_add":
		return fmt.Sprintf("ballrt.SetAdd(%s, %s)", set(), c.arg(f, "value"))
	case "set_remove":
		return fmt.Sprintf("ballrt.SetRemove(%s, %s)", set(), c.arg(f, "value"))
	case "set_contains":
		return fmt.Sprintf("ballrt.SetContains(%s, %s)", set(), c.arg(f, "value"))
	case "set_length":
		return fmt.Sprintf("ballrt.SetLength(%s)", set())
	case "set_is_empty":
		return fmt.Sprintf("ballrt.SetIsEmpty(%s)", set())
	case "set_to_list":
		return fmt.Sprintf("ballrt.SetToList(%s)", set())
	case "set_union":
		return fmt.Sprintf("ballrt.SetUnion(%s, %s)", c.arg(f, "left", "set"), c.arg(f, "right", "other"))
	case "set_intersection":
		return fmt.Sprintf("ballrt.SetIntersection(%s, %s)", c.arg(f, "left", "set"), c.arg(f, "right", "other"))
	case "set_difference":
		return fmt.Sprintf("ballrt.SetDifference(%s, %s)", c.arg(f, "left", "set"), c.arg(f, "right", "other"))
	default:
		c.fail("unsupported base function std_collections.%s", call.GetFunction())
		return "ballrt.Value(nil)"
	}
}

// ── ball_proto ──────────────────────────────────────────────────────────────

func (c *Compiler) compileProtoCall(call *ballv1.FunctionCall, f map[string]*ballv1.Expression) string {
	obj := func() string { return c.arg(f, "obj") }
	switch call.GetFunction() {
	case "whichExpr":
		return fmt.Sprintf("ballrt.WhichExpr(%s)", obj())
	case "whichValue":
		return fmt.Sprintf("ballrt.WhichValue(%s)", obj())
	case "whichStmt":
		return fmt.Sprintf("ballrt.WhichStmt(%s)", obj())
	case "whichKind":
		return fmt.Sprintf("ballrt.WhichKind(%s)", obj())
	case "whichSource":
		return fmt.Sprintf("ballrt.WhichSource(%s)", obj())
	case "getField":
		return fmt.Sprintf("ballrt.GetField(%s, %s)", obj(), c.arg(f, "name"))
	case "getFieldOr":
		return fmt.Sprintf("ballrt.GetFieldOr(%s, %s, %s)", obj(), c.arg(f, "name"), c.arg(f, "defaultValue"))
	case "setField":
		return fmt.Sprintf("ballrt.SetFieldValue(%s, %s, %s)", obj(), c.arg(f, "name"), c.arg(f, "value"))
	case "getStructField":
		return fmt.Sprintf("ballrt.GetStructField(%s, %s)", c.arg(f, "struct"), c.arg(f, "key"))
	case "getStringField":
		return fmt.Sprintf("ballrt.GetStringField(%s, %s)", c.arg(f, "struct"), c.arg(f, "key"))
	case "getBoolField":
		return fmt.Sprintf("ballrt.GetBoolField(%s, %s)", c.arg(f, "struct"), c.arg(f, "key"))
	case "getListField":
		return fmt.Sprintf("ballrt.GetListField(%s, %s)", c.arg(f, "struct"), c.arg(f, "key"))
	case "getNumberField":
		return fmt.Sprintf("ballrt.GetNumberField(%s, %s)", c.arg(f, "struct"), c.arg(f, "key"))
	case "getStructFieldKeys":
		return fmt.Sprintf("ballrt.GetStructFieldKeys(%s)", c.arg(f, "struct"))
	case "ensureDefaults":
		return fmt.Sprintf("ballrt.EnsureDefaults(%s, %s)", obj(), c.arg(f, "messageType"))
	case "defaultString":
		return "ballrt.DefaultString()"
	case "defaultList":
		return "ballrt.DefaultList()"
	case "defaultBool":
		return "ballrt.DefaultBool()"
	case "defaultInt":
		return "ballrt.DefaultInt()"
	case "exprCase":
		return fmt.Sprintf("ballrt.ExprCase(%s)", c.arg(f, "name"))
	case "literalCase":
		return fmt.Sprintf("ballrt.LiteralCase(%s)", c.arg(f, "name"))
	case "stmtCase":
		return fmt.Sprintf("ballrt.StmtCase(%s)", c.arg(f, "name"))
	}
	if strings.HasPrefix(call.GetFunction(), "has") && len(call.GetFunction()) > 3 {
		field := lowerFirst(call.GetFunction()[3:])
		return fmt.Sprintf("ballrt.HasField(%s, %q)", obj(), field)
	}
	c.fail("unsupported base function ball_proto.%s", call.GetFunction())
	return "ballrt.Value(nil)"
}

func lowerFirst(s string) string {
	if s == "" {
		return s
	}
	return strings.ToLower(s[:1]) + s[1:]
}

// ── Message-list helpers (switch cases / try catches) ───────────────────────

func messageList(f map[string]*ballv1.Expression, key string) []*ballv1.MessageCreation {
	var out []*ballv1.MessageCreation
	e, ok := f[key]
	if !ok {
		return out
	}
	lit := e.GetLiteral()
	if lit == nil || lit.GetListValue() == nil {
		return out
	}
	for _, el := range lit.GetListValue().GetElements() {
		if mc := el.GetMessageCreation(); mc != nil {
			out = append(out, mc)
		}
	}
	return out
}

func messageCreationFields(mc *ballv1.MessageCreation) map[string]*ballv1.Expression {
	out := map[string]*ballv1.Expression{}
	for _, fv := range mc.GetFields() {
		out[fv.GetName()] = fv.GetValue()
	}
	return out
}

func stringField(f map[string]*ballv1.Expression, key string) string {
	return stringLiteralField(f, key)
}

func boolLiteralField(f map[string]*ballv1.Expression, key string) bool {
	e, ok := f[key]
	if !ok {
		return false
	}
	if lit := e.GetLiteral(); lit != nil {
		return lit.GetBoolValue()
	}
	return false
}
