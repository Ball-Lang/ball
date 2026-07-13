package compiler

// Structured pattern matching (Dart 3 patterns) for switch statements and switch
// expressions.
//
// A pattern compiles to two things: a boolean Go *condition* over a subject
// accessor, and a flat, ordered list of (name, accessor) *bindings* that the arm
// re-materializes as locals. Sub-patterns receive derived accessor STRINGS
// (`ballrt.Index(S, 0)`, `ballrt.MapGet(S, "k")`) rather than evaluated values,
// so one recursive pass yields one flat condition and one flat binding list.
//
// Every condition is a Go bool expression, so `&&`/`||` short-circuit
// left-to-right: the shape conjuncts (is-a-list, length) always precede the
// element accessors they make safe. ballrt.Index panics past the end of a list
// and ballrt.Gt panics on a non-number, so that ordering is load-bearing, not
// cosmetic.

import (
	"fmt"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// patternBinding is one binder: the Ball name the arm body refers to, and the Go
// expression that recomputes its value from the subject.
type patternBinding struct {
	name string
	acc  string
}

// patternResult is a compiled pattern: when to take the arm, and what to bind.
type patternResult struct {
	cond     string
	bindings []patternBinding
}

// relationalFns maps a relational pattern's ordering operator to its ballrt
// comparison helper. `==`/`!=` are handled separately (they are Ball equality,
// not an ordering, and accept non-numeric operands).
var relationalFns = map[string]string{">": "Gt", "<": "Lt", ">=": "Gte", "<=": "Lte"}

// patternKind names a pattern MessageCreation's kind. The encoder puts it in the
// message's typeName; `__pattern_kind__` is the engine-normalized fallback.
func patternKind(mc *ballv1.MessageCreation, f map[string]*ballv1.Expression) string {
	if tn := typeShortName(mc.GetTypeName()); tn != "" {
		return tn
	}
	return stringField(f, "__pattern_kind__")
}

// typeCheckCond builds the type test shared by VarPattern, WildcardPattern,
// ObjectPattern and CastPattern. They must all route through this one function:
// a typed binder (`case int x:`) and a typed wildcard (`case int _:`) are the
// same test, and letting them diverge is how the typed-wildcard collapse (below)
// got in.
//
// ballrt.IsType already covers int/double/num/String/bool/List/Map/Set/Function,
// user messages (short, module-qualified, or a registered supertype) and generic
// forms; only Dart's nullable suffix is a compiler-side concern. An unrecognized
// name falls through to the user-message test (false for a primitive) — it is
// never a hardcoded true.
func (c *Compiler) typeCheckCond(typeName, subj string) string {
	if len(typeName) > 1 && strings.HasSuffix(typeName, "?") {
		return fmt.Sprintf("(%s == nil || %s)", subj, c.typeCheckCond(strings.TrimSuffix(typeName, "?"), subj))
	}
	return fmt.Sprintf("ballrt.Truthy(ballrt.IsType(%s, %q))", subj, typeName)
}

// compilePattern compiles one structured pattern against the subject accessor
// subj. An unknown kind is a fail-loud compile error (issue #55): emitting a
// placeholder condition would produce a program that runs, exits 0 and prints
// the wrong answer.
func (c *Compiler) compilePattern(subj string, pe *ballv1.Expression) patternResult {
	mc := pe.GetMessageCreation()
	if mc == nil {
		// Not a structured pattern message: a bare constant expression.
		return patternResult{cond: fmt.Sprintf("ballrt.Eq(%s, %s)", subj, c.compileExpr(pe))}
	}
	f := messageCreationFields(mc)

	switch kind := patternKind(mc, f); kind {
	case "ConstPattern":
		if !hasField(f, "value") {
			return patternResult{cond: "true"}
		}
		// Ball equality, not Go's `==`: a boxed number or string compared by
		// identity would never match its literal.
		return patternResult{cond: fmt.Sprintf("ballrt.Eq(%s, %s)", subj, c.arg(f, "value"))}

	case "VarPattern":
		res := patternResult{cond: "true"}
		if t := stringField(f, "type"); t != "" {
			res.cond = c.typeCheckCond(t, subj)
		}
		if name := stringField(f, "name"); name != "" {
			res.bindings = []patternBinding{{name: name, acc: subj}}
		}
		return res

	case "WildcardPattern":
		// A TYPED wildcard (`case int _:`) still tests its type. Returning a bare
		// `true` here makes the first such case an unconditional catch-all, which
		// swallows every later case: 183_type_patterns printed int/int/int/int
		// (compiles, exits 0, wrong answer). Only an UNTYPED `_` is a catch-all.
		if t := stringField(f, "type"); t != "" {
			return patternResult{cond: c.typeCheckCond(t, subj)}
		}
		return patternResult{cond: "true"}

	case "LogicalOrPattern":
		l := c.compilePattern(subj, f["left"])
		r := c.compilePattern(subj, f["right"])
		return patternResult{
			cond:     fmt.Sprintf("(%s || %s)", l.cond, r.cond),
			bindings: dedupeBindings(l.bindings, r.bindings),
		}

	case "LogicalAndPattern":
		l := c.compilePattern(subj, f["left"])
		r := c.compilePattern(subj, f["right"])
		return patternResult{
			cond:     fmt.Sprintf("(%s && %s)", l.cond, r.cond),
			bindings: dedupeBindings(l.bindings, r.bindings),
		}

	case "RelationalPattern":
		return c.compileRelationalPattern(subj, f)

	case "CastPattern":
		return c.compileCastPattern(subj, f)

	case "NullCheckPattern", "NullAssertPattern":
		// Both kinds match identically: a null never binds.
		sub := patternResult{cond: "true"}
		if p, ok := f["pattern"]; ok {
			sub = c.compilePattern(subj, p)
		}
		cond := fmt.Sprintf("(%s != nil)", subj)
		if sub.cond != "true" {
			cond = fmt.Sprintf("(%s != nil && %s)", subj, sub.cond)
		}
		return patternResult{cond: cond, bindings: sub.bindings}

	case "ListPattern":
		return c.compileListPattern(subj, f)

	case "MapPattern":
		return c.compileMapPattern(subj, f)

	case "RecordPattern":
		return c.compileRecordPattern(subj, f)

	case "ObjectPattern":
		return c.compileObjectPattern(subj, f)

	case "RestPattern":
		// Only meaningful inside a ListPattern (handled there). Standalone is
		// defensive.
		if p, ok := f["subpattern"]; ok {
			return c.compilePattern(subj, p)
		}
		return patternResult{cond: "true"}

	default:
		c.fail("unsupported pattern kind %q", kind)
		return patternResult{cond: "false"}
	}
}

// compileRelationalPattern compiles `> 5`, `== 3`, `!= x`.
func (c *Compiler) compileRelationalPattern(subj string, f map[string]*ballv1.Expression) patternResult {
	op := stringField(f, "operator")
	if op == "" || !hasField(f, "operand") {
		return patternResult{cond: "true"}
	}
	operand := c.arg(f, "operand")
	switch op {
	case "==":
		return patternResult{cond: fmt.Sprintf("ballrt.Eq(%s, %s)", subj, operand)}
	case "!=":
		return patternResult{cond: fmt.Sprintf("!ballrt.Eq(%s, %s)", subj, operand)}
	}
	fn, ok := relationalFns[op]
	if !ok {
		c.fail("unsupported relational pattern operator %q", op)
		return patternResult{cond: "false"}
	}
	// A non-numeric subject must FAIL TO MATCH — not throw, not coerce. ballrt's
	// comparisons panic on a non-number, so both sides are type-tested first and
	// Go's && short-circuits away the comparison.
	return patternResult{cond: fmt.Sprintf("(ballrt.Truthy(ballrt.IsType(%s, \"num\")) && ballrt.Truthy(ballrt.IsType(%s, \"num\")) && ballrt.%s(%s, %s))",
		subj, operand, fn, subj, operand)}
}

// compileCastPattern compiles `p as T`, which ASSERTS rather than refutes: a
// type mismatch throws a TypeError, it does not fall through to the next case.
func (c *Compiler) compileCastPattern(subj string, f map[string]*ballv1.Expression) patternResult {
	sub := patternResult{cond: "true"}
	if p, ok := f["pattern"]; ok {
		sub = c.compilePattern(subj, p)
	}
	t := stringField(f, "type")
	if t == "" {
		return sub
	}
	// The sub-pattern's condition is the LEFT conjunct so the assert only fires
	// once the outer shape matched: `[var x as int, var y as int]` must return the
	// default arm for the subject 'hi', not throw (302_cast_patterns).
	return patternResult{
		cond:     fmt.Sprintf("(%s && %s)", sub.cond, c.castAssert(c.typeCheckCond(t, subj), t)),
		bindings: sub.bindings,
	}
}

// castAssert returns a bool expression that is true when ok holds and otherwise
// throws a catchable Ball TypeError (Dart's failed `as`).
func (c *Compiler) castAssert(ok, typeName string) string {
	uid := c.uid()
	var b strings.Builder
	b.WriteString("func() bool {\n")
	fmt.Fprintf(&b, "\t\tif !(%s) {\n", ok)
	fmt.Fprintf(&b, "\t\t\t__cast%d := ballrt.NewMap()\n", uid)
	fmt.Fprintf(&b, "\t\t\t__cast%d.Set(\"message\", %q)\n", uid, "type cast failed: not a "+typeName)
	fmt.Fprintf(&b, "\t\t\tballrt.Throw(ballrt.NewMessage(\"TypeError\", __cast%d))\n", uid)
	b.WriteString("\t\t}\n\t\treturn true\n\t}()")
	return b.String()
}

// compileListPattern compiles `[a, b]` and `[a, ...rest, z]`. Only the first
// rest element is honoured (Dart allows at most one).
func (c *Compiler) compileListPattern(subj string, f map[string]*ballv1.Expression) patternResult {
	elems := patternElements(f, "elements")
	restIdx := -1
	for i, el := range elems {
		if mc := el.GetMessageCreation(); mc != nil && patternKind(mc, messageCreationFields(mc)) == "RestPattern" {
			restIdx = i
			break
		}
	}

	conds := []string{fmt.Sprintf("ballrt.Truthy(ballrt.IsType(%s, \"List\"))", subj)}
	var binds []patternBinding
	add := func(r patternResult) {
		if r.cond != "true" {
			conds = append(conds, r.cond)
		}
		binds = append(binds, r.bindings...)
	}

	if restIdx < 0 {
		conds = append(conds, fmt.Sprintf("ballrt.Eq(ballrt.ListLength(%s), int64(%d))", subj, len(elems)))
		for i, el := range elems {
			add(c.compilePattern(fmt.Sprintf("ballrt.Index(%s, int64(%d))", subj, i), el))
		}
		return patternResult{cond: "(" + strings.Join(conds, " && ") + ")", bindings: binds}
	}

	before, after := elems[:restIdx], elems[restIdx+1:]
	conds = append(conds, fmt.Sprintf("ballrt.Gte(ballrt.ListLength(%s), int64(%d))", subj, len(before)+len(after)))
	for i, el := range before {
		add(c.compilePattern(fmt.Sprintf("ballrt.Index(%s, int64(%d))", subj, i), el))
	}
	// `...var tail` binds the middle slice [len(before) .. len(subject)-len(after)].
	restFields := messageCreationFields(elems[restIdx].GetMessageCreation())
	if sp, ok := restFields["subpattern"]; ok {
		slice := fmt.Sprintf("ballrt.ListSlice(%s, int64(%d), ballrt.Sub(ballrt.ListLength(%s), int64(%d)))",
			subj, len(before), subj, len(after))
		add(c.compilePattern(slice, sp))
	}
	// Trailing elements index from the END, so their positions depend on the
	// subject's length, not on a constant.
	for i, el := range after {
		idx := fmt.Sprintf("ballrt.Sub(ballrt.ListLength(%s), int64(%d))", subj, len(after)-i)
		add(c.compilePattern(fmt.Sprintf("ballrt.Index(%s, %s)", subj, idx), el))
	}
	return patternResult{cond: "(" + strings.Join(conds, " && ") + ")", bindings: binds}
}

// compileMapPattern compiles `{'k': p, …}`. Extra keys in the subject are
// allowed (unlike a record).
func (c *Compiler) compileMapPattern(subj string, f map[string]*ballv1.Expression) patternResult {
	// A Ball set is a distinct *Set, so ballrt.IsType(_, "Map") already refuses it
	// — `case {}:` must not match a set (394_mappattern_excludes_set, issue #178).
	conds := []string{fmt.Sprintf("ballrt.Truthy(ballrt.IsType(%s, \"Map\"))", subj)}
	var binds []patternBinding
	for _, entry := range messageList(f, "entries") {
		ef := messageCreationFields(entry)
		if !hasField(ef, "key") {
			continue
		}
		key := c.arg(ef, "key")
		conds = append(conds, fmt.Sprintf("ballrt.Truthy(ballrt.MapContainsKey(%s, %s))", subj, key))
		if vp, ok := ef["value"]; ok {
			r := c.compilePattern(fmt.Sprintf("ballrt.MapGet(%s, %s)", subj, key), vp)
			if r.cond != "true" {
				conds = append(conds, r.cond)
			}
			binds = append(binds, r.bindings...)
		}
	}
	return patternResult{cond: "(" + strings.Join(conds, " && ") + ")", bindings: binds}
}

// compileRecordPattern compiles `(1, var x)` / `(a: 1, b: var y)`.
//
// std.record materializes a Ball record as a *Map keyed by the encoder's 1-based
// positional names ("$1", "$2", …) plus the named fields, so the pattern matches
// THAT shape — matcher and constructor must stay in lockstep. Arity is exact: a
// 2-field pattern must not match a 3-field record.
func (c *Compiler) compileRecordPattern(subj string, f map[string]*ballv1.Expression) patternResult {
	fields := messageList(f, "fields")
	conds := []string{
		fmt.Sprintf("ballrt.Truthy(ballrt.IsType(%s, \"Map\"))", subj),
		fmt.Sprintf("ballrt.Eq(ballrt.MapLength(%s), int64(%d))", subj, len(fields)),
	}
	var binds []patternBinding
	positional := 0
	for _, fmc := range fields {
		ff := messageCreationFields(fmc)
		key := stringField(ff, "name")
		if key == "" {
			positional++
			key = fmt.Sprintf("$%d", positional)
		}
		conds = append(conds, fmt.Sprintf("ballrt.Truthy(ballrt.MapContainsKey(%s, %q))", subj, key))
		if pp, ok := ff["pattern"]; ok {
			r := c.compilePattern(fmt.Sprintf("ballrt.MapGet(%s, %q)", subj, key), pp)
			if r.cond != "true" {
				conds = append(conds, r.cond)
			}
			binds = append(binds, r.bindings...)
		}
	}
	return patternResult{cond: "(" + strings.Join(conds, " && ") + ")", bindings: binds}
}

// compileObjectPattern compiles `Type(field: p, …)`: a type gate plus field
// getters. Extra fields on the subject are fine — this is field access, not
// positional arity.
func (c *Compiler) compileObjectPattern(subj string, f map[string]*ballv1.Expression) patternResult {
	var conds []string
	if t := stringField(f, "type"); t != "" {
		conds = append(conds, c.typeCheckCond(t, subj))
	}
	var binds []patternBinding
	for _, fmc := range messageList(f, "fields") {
		ff := messageCreationFields(fmc)
		name := stringField(ff, "name")
		pp, ok := ff["pattern"]
		if name == "" || !ok {
			continue
		}
		r := c.compilePattern(fmt.Sprintf("ballrt.FieldGet(%s, %q)", subj, name), pp)
		if r.cond != "true" {
			conds = append(conds, r.cond)
		}
		binds = append(binds, r.bindings...)
	}
	if len(conds) == 0 {
		return patternResult{cond: "true", bindings: binds}
	}
	return patternResult{cond: "(" + strings.Join(conds, " && ") + ")", bindings: binds}
}

// patternElements reads a ListLiteral-of-patterns field (a ListPattern's
// `elements`).
func patternElements(f map[string]*ballv1.Expression, key string) []*ballv1.Expression {
	e, ok := f[key]
	if !ok {
		return nil
	}
	lit := e.GetLiteral()
	if lit == nil || lit.GetListValue() == nil {
		return nil
	}
	return lit.GetListValue().GetElements()
}

// dedupeBindings concatenates binding lists, keeping the first accessor for a
// repeated name: the two alternatives of a LogicalOrPattern bind the same names,
// and Go forbids redeclaring a local in one block.
func dedupeBindings(lists ...[]patternBinding) []patternBinding {
	seen := map[string]bool{}
	var out []patternBinding
	for _, l := range lists {
		for _, b := range l {
			if seen[b.name] {
				continue
			}
			seen[b.name] = true
			out = append(out, b)
		}
	}
	return out
}

// bindDecls declares a matched arm's binders as locals, recomputed from the
// subject. Emitted INSIDE the matched block (and inside the guard closure), never
// before the condition — an accessor evaluated on a subject that did not match
// would index a non-list or deref a null.
func (c *Compiler) bindDecls(binds []patternBinding) string {
	var b strings.Builder
	for _, bd := range binds {
		n := sanitize(bd.name)
		fmt.Fprintf(&b, "var %s ballrt.Value = %s\n_ = %s\n", n, bd.acc, n)
	}
	return b.String()
}
