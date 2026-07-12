package compiler

import (
	"fmt"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// Message creation, call dispatch, and list-literal building — the shapes that
// go through the class/runtime machinery. Go flattens every user function/method
// into one package, so a user call is a bare function name (no cross-module
// prefix); a call whose callee is neither a known user function nor a local
// function value is a built-in method call dispatched dynamically.

func (c *Compiler) compileCall(call *ballv1.FunctionCall) string {
	if c.baseModules[call.GetModule()] {
		return c.compileBaseCall(call)
	}
	if c.stubModules[call.GetModule()] {
		return fmt.Sprintf("ballrt.UnsupportedBaseCall(%q, %q)", call.GetModule(), call.GetFunction())
	}

	input := "ballrt.Value(nil)"
	if call.GetInput() != nil {
		input = c.compileExpr(call.GetInput())
	}
	fn := call.GetFunction()
	name := sanitize(fn)

	// A call through a first-class function value held in a local (shadows a
	// top-level namesake).
	if c.isLocal(fn) {
		return fmt.Sprintf("ballrt.CallFunction(%s, %s)", name, input)
	}

	// A callee that is not a known user function is a built-in method call on a
	// core type (x.group(1), list.addAll(y)); dispatch it dynamically.
	if !c.userFuncs[name] {
		return fmt.Sprintf("ballrt.CallMethod(%q, %s)", fn, input)
	}

	// Implicit-`this` injection: a bare this.method(args) call from inside an
	// instance-method body has its receiver injected (the encoder packs only the
	// arguments); an explicit obj.method(args) already carries self.
	if c.inInstanceMethod && c.instanceMethods[name] && !callInputHasExplicitSelf(call) {
		self := c.selfRecvName
		if self == "" {
			self = "self"
		}
		if callInputIsArgMessage(call) || call.GetInput() == nil {
			return fmt.Sprintf("%s(ballrt.WithSelf(%s, %s))", name, input, self)
		}
		return fmt.Sprintf("%s(ballrt.Arg0WithSelf(%s, %s))", name, input, self)
	}

	return fmt.Sprintf("%s(%s)", name, input)
}

func callInputHasExplicitSelf(call *ballv1.FunctionCall) bool {
	mc := call.GetInput().GetMessageCreation()
	if mc == nil {
		return false
	}
	for _, fv := range mc.GetFields() {
		if fv.GetName() == "self" {
			return true
		}
	}
	return false
}

func callInputIsArgMessage(call *ballv1.FunctionCall) bool {
	mc := call.GetInput().GetMessageCreation()
	return mc != nil && mc.GetTypeName() == ""
}

// compileMessageCreation builds a dynamic *Map (anonymous/argument message) or a
// *Message (named instance). A named type with a body-carrying constructor is
// built by invoking that constructor; a bodyless type builds an inline field map
// with field-level defaults for unset fields. Dart core collection constructors
// materialize as native runtime maps/lists.
func (c *Compiler) compileMessageCreation(mc *ballv1.MessageCreation) string {
	short := typeShortName(mc.GetTypeName())

	// A native map constructor with no data argument → a real runtime map.
	if nativeMapConstructors[short] && !anyPositional(mc) {
		return "ballrt.NewMap()"
	}
	// A Dart core-collection copy/fill constructor → native materialization.
	if factory := c.collectionFactory(mc); factory != "" {
		return factory
	}

	// Remap each positional argN field to the constructor's real parameter name.
	ctorParams := c.constructorParamNames(mc.GetTypeName())
	explicit := map[string]bool{}
	type entry struct{ name, value string }
	var entries []entry
	for i, fv := range mc.GetFields() {
		fieldName := fv.GetName()
		if ctorParams != nil && isPositionalArg(fieldName) && i < len(ctorParams) {
			fieldName = ctorParams[i]
		}
		explicit[fieldName] = true
		entries = append(entries, entry{fieldName, c.compileExpr(fv.GetValue())})
	}

	buildMap := func() string {
		var b strings.Builder
		b.WriteString("func() *ballrt.Map {\n\t\t__m := ballrt.NewMap()\n")
		for _, e := range entries {
			fmt.Fprintf(&b, "\t\t__m.Set(%q, %s)\n", e.name, e.value)
		}
		return b.String()
	}

	// A body-carrying constructor MUST be invoked (its body builds the instance).
	if impl, ok := c.bodyConstructorImpl(mc.GetTypeName()); ok {
		mapBuild := buildMap() + "\t\treturn __m\n\t}()"
		return fmt.Sprintf("%s(%s)", impl, mapBuild)
	}

	// A bodyless named type: inline field map + field-level defaults for unset
	// instance fields.
	if mc.GetTypeName() != "" {
		if td, ok := c.typeDefsByShort[short]; ok {
			for _, field := range c.allInstanceFieldNames(td) {
				if explicit[field] {
					continue
				}
				if def := c.fieldDefaultExpr(td, field); def != "" {
					entries = append(entries, entry{field, def})
				}
			}
		}
	}

	body := buildMap()
	if mc.GetTypeName() == "" {
		return "func() ballrt.Value {\n" + body[len("func() *ballrt.Map {\n"):] + "\t\treturn __m\n\t}()"
	}
	return "func() ballrt.Value {\n" + body[len("func() *ballrt.Map {\n"):] +
		fmt.Sprintf("\t\treturn ballrt.NewMessage(%q, __m)\n\t}()", mc.GetTypeName())
}

func anyPositional(mc *ballv1.MessageCreation) bool {
	for _, fv := range mc.GetFields() {
		if isPositionalArg(fv.GetName()) {
			return true
		}
	}
	return false
}

// collectionFactory returns a native-materialization expression for a Dart core
// copy/fill constructor (Map.from, List.of, List.filled, …), or "".
func (c *Compiler) collectionFactory(mc *ballv1.MessageCreation) string {
	var op string
	switch typeShortName(mc.GetTypeName()) {
	case "Map.from", "Map.of", "LinkedHashMap.from", "LinkedHashMap.of",
		"HashMap.from", "HashMap.of", "SplayTreeMap.from", "SplayTreeMap.of":
		op = "MapCopy"
	case "List.from", "List.of":
		op = "ListCopy"
	case "List.filled":
		op = "ListFilled"
	default:
		return ""
	}
	var args []string
	for _, fv := range mc.GetFields() {
		if isPositionalArg(fv.GetName()) {
			args = append(args, c.compileExpr(fv.GetValue()))
		}
	}
	switch {
	case op == "ListFilled" && len(args) >= 2:
		return fmt.Sprintf("ballrt.ListFilled(%s, %s)", args[0], args[1])
	case (op == "MapCopy" || op == "ListCopy") && len(args) >= 1:
		return fmt.Sprintf("ballrt.%s(%s)", op, args[0])
	}
	return ""
}

// ── List literal (with spread / collection elements) ────────────────────────

func (c *Compiler) compileListLiteral(list *ballv1.ListLiteral) string {
	elems := list.GetElements()
	if len(elems) == 0 {
		return "ballrt.NewList()"
	}
	if !anyCollectionElement(elems) {
		parts := make([]string, len(elems))
		for i, el := range elems {
			parts[i] = c.compileExpr(el)
		}
		return "ballrt.NewList(" + strings.Join(parts, ", ") + ")"
	}
	uid := c.uid()
	var b strings.Builder
	fmt.Fprintf(&b, "func() ballrt.Value {\n\t\t__lit%d := ballrt.NewList()\n", uid)
	for _, el := range elems {
		b.WriteString(indent(c.compileCollectionElement(fmt.Sprintf("__lit%d", uid), el), "\t"))
	}
	fmt.Fprintf(&b, "\t\treturn __lit%d\n\t}()", uid)
	return b.String()
}

func anyCollectionElement(elems []*ballv1.Expression) bool {
	for _, el := range elems {
		if collectionElementKind(el) != "" {
			return true
		}
	}
	return false
}

func collectionElementKind(el *ballv1.Expression) string {
	call := el.GetCall()
	if call == nil || call.GetModule() != "std" {
		return ""
	}
	switch call.GetFunction() {
	case "spread", "null_spread", "collection_if", "collection_for":
		return call.GetFunction()
	}
	return ""
}

// compileCollectionElement emits code appending one list-literal element to
// target. A plain element is added; spread splices; collection_if/for compose.
func (c *Compiler) compileCollectionElement(target string, el *ballv1.Expression) string {
	kind := collectionElementKind(el)
	if kind == "" {
		return fmt.Sprintf("%s.Add(%s)\n", target, c.compileExpr(el))
	}
	f := fieldMap(el.GetCall())
	uid := c.uid()
	switch kind {
	case "spread":
		return fmt.Sprintf("for _, __sp%d := range ballrt.SpreadIter(%s) { %s.Add(__sp%d) }\n", uid, c.arg(f, "value"), target, uid)
	case "null_spread":
		return fmt.Sprintf("{ __sp%d := %s; if __sp%d != nil { for _, __e%d := range ballrt.SpreadIter(__sp%d) { %s.Add(__e%d) } } }\n",
			uid, c.arg(f, "value"), uid, uid, uid, target, uid)
	case "collection_if":
		cond := "false"
		if hasField(f, "condition") {
			cond = "ballrt.Truthy(" + c.arg(f, "condition") + ")"
		}
		then := ""
		if e, ok := f["then"]; ok {
			then = c.compileCollectionElement(target, e)
		}
		if e, ok := f["else"]; ok {
			els := c.compileCollectionElement(target, e)
			return fmt.Sprintf("if %s {\n%s} else {\n%s}\n", cond, then, els)
		}
		return fmt.Sprintf("if %s {\n%s}\n", cond, then)
	case "collection_for":
		return c.compileCollectionFor(target, f)
	}
	return ""
}

// compileMapCreate builds a map from a map literal / comprehension. Each `entry`
// field is a {key, value} message; an `element` field is a spread/collection_if/
// collection_for that must be spliced (the map analog of list-literal elements).
// The missing splice previously emptied every internal map (e.g. _buildStdDispatch).
func (c *Compiler) compileMapCreate(call *ballv1.FunctionCall) string {
	mc := call.GetInput().GetMessageCreation()
	if mc == nil {
		return "ballrt.MapCreate()"
	}
	uid := c.uid()
	target := fmt.Sprintf("__map%d", uid)
	var b strings.Builder
	fmt.Fprintf(&b, "func() ballrt.Value {\n\t\t%s := ballrt.NewMap()\n", target)
	for _, fv := range mc.GetFields() {
		switch fv.GetName() {
		case "entry", "entries":
			b.WriteString(indent(c.compileMapEntry(target, fv.GetValue()), "\t"))
		case "element":
			b.WriteString(indent(c.compileMapCollectionElement(target, fv.GetValue()), "\t"))
		}
	}
	fmt.Fprintf(&b, "\t\treturn %s\n\t}()", target)
	return b.String()
}

// compileMapEntry adds one {key, value} entry message to target.
func (c *Compiler) compileMapEntry(target string, el *ballv1.Expression) string {
	if mc := el.GetMessageCreation(); mc != nil {
		ef := messageCreationFields(mc)
		return fmt.Sprintf("%s.Set(ballrt.ToStr(%s), %s)\n", target, c.arg(ef, "key"), c.arg(ef, "value"))
	}
	return c.compileMapCollectionElement(target, el)
}

// compileMapCollectionElement splices one map-literal element into target: a
// spread merges a map, collection_if/for compose, a leaf {key,value} is added.
func (c *Compiler) compileMapCollectionElement(target string, el *ballv1.Expression) string {
	kind := collectionElementKind(el)
	if kind == "" {
		return c.compileMapEntry(target, el)
	}
	f := fieldMap(el.GetCall())
	uid := c.uid()
	switch kind {
	case "spread":
		return fmt.Sprintf("ballrt.MapSpread(%s, %s)\n", target, c.arg(f, "value"))
	case "null_spread":
		return fmt.Sprintf("{ __ms%d := %s; if __ms%d != nil { ballrt.MapSpread(%s, __ms%d) } }\n", uid, c.arg(f, "value"), uid, target, uid)
	case "collection_if":
		cond := "false"
		if hasField(f, "condition") {
			cond = "ballrt.Truthy(" + c.arg(f, "condition") + ")"
		}
		then := ""
		if e, ok := f["then"]; ok {
			then = c.compileMapCollectionElement(target, e)
		}
		if e, ok := f["else"]; ok {
			return fmt.Sprintf("if %s {\n%s} else {\n%s}\n", cond, then, c.compileMapCollectionElement(target, e))
		}
		return fmt.Sprintf("if %s {\n%s}\n", cond, then)
	case "collection_for":
		return c.compileMapCollectionFor(target, f)
	}
	return ""
}

func (c *Compiler) compileMapCollectionFor(target string, f map[string]*ballv1.Expression) string {
	if it, ok := f["iterable"]; ok {
		variable := stringLiteralField(f, "variable")
		if variable == "" {
			variable = "item"
		}
		c.pushScope()
		c.bind(variable)
		body := ""
		if e, ok := f["body"]; ok {
			body = c.compileMapCollectionElement(target, e)
		}
		iter := c.compileExpr(it)
		c.popScope()
		return fmt.Sprintf("for _, %s := range ballrt.Iterate(%s) {\n_ = %s\n%s}\n", sanitize(variable), iter, sanitize(variable), body)
	}
	c.pushScope()
	var b strings.Builder
	b.WriteString("{\n")
	if e, ok := f["init"]; ok {
		b.WriteString(c.compileLoopInit(e))
	}
	cond := "true"
	if hasField(f, "condition") {
		cond = "ballrt.Truthy(" + c.arg(f, "condition") + ")"
	}
	fmt.Fprintf(&b, "for %s {\n", cond)
	if e, ok := f["body"]; ok {
		b.WriteString(c.compileMapCollectionElement(target, e))
	}
	if e, ok := f["update"]; ok {
		fmt.Fprintf(&b, "_ = %s\n", c.compileExpr(e))
	}
	b.WriteString("}\n}\n")
	c.popScope()
	return b.String()
}

func (c *Compiler) compileCollectionFor(target string, f map[string]*ballv1.Expression) string {
	if it, ok := f["iterable"]; ok {
		variable := stringLiteralField(f, "variable")
		if variable == "" {
			variable = "item"
		}
		c.pushScope()
		c.bind(variable)
		body := ""
		if e, ok := f["body"]; ok {
			body = c.compileCollectionElement(target, e)
		}
		iter := c.compileExpr(it)
		c.popScope()
		return fmt.Sprintf("for _, %s := range ballrt.Iterate(%s) {\n_ = %s\n%s}\n", sanitize(variable), iter, sanitize(variable), body)
	}
	c.pushScope()
	var b strings.Builder
	b.WriteString("{\n")
	if e, ok := f["init"]; ok {
		b.WriteString(c.compileLoopInit(e))
	}
	cond := "true"
	if hasField(f, "condition") {
		cond = "ballrt.Truthy(" + c.arg(f, "condition") + ")"
	}
	fmt.Fprintf(&b, "for %s {\n", cond)
	if e, ok := f["body"]; ok {
		b.WriteString(c.compileCollectionElement(target, e))
	}
	if e, ok := f["update"]; ok {
		fmt.Fprintf(&b, "_ = %s\n", c.compileExpr(e))
	}
	b.WriteString("}\n}\n")
	c.popScope()
	return b.String()
}
