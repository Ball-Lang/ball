package compiler

import (
	"fmt"
	"sort"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	descriptorpb "google.golang.org/protobuf/types/descriptorpb"
	structpb "google.golang.org/protobuf/types/known/structpb"
)

// Class-member emission, class-hierarchy field resolution, constructor emission,
// oneof-discriminator + enum namespaces, and the message-creation / call dispatch
// that drive self-hosting (epic #426 Phase 4). The Go port of C#'s TypeEmit.cs +
// Constructors.cs + the class-aware parts of CSharpCompiler.cs. An instance is a
// dynamic *ballrt.Message (a type tag + shared field map); a class method
// dispatches on the receiver's runtime type_name.

// oneofDiscriminators are the synthesized proto oneof "enums" the engine's AST
// dispatch reads (whichExpr() == Expression_Expr.call). Each member resolves to
// the case-name string the matching ball_proto discriminator returns.
var oneofDiscriminators = map[string][]string{
	"Expression_Expr":     {"call", "literal", "reference", "fieldAccess", "messageCreation", "block", "lambda", "notSet"},
	"Literal_Value":       {"intValue", "doubleValue", "stringValue", "boolValue", "bytesValue", "listValue", "notSet"},
	"Statement_Stmt":      {"let", "expression", "notSet"},
	"ModuleImport_Source": {"http", "file", "git", "registry", "inline", "notSet"},
	"structpb.Value_Kind": {"nullValue", "numberValue", "stringValue", "boolValue", "structValue", "listValue", "notSet"},
}

// builtinTypeNames are Dart core type names that can appear as a bare reference
// (a static-method receiver or a type argument) — emitted as a TypeLiteral.
var builtinTypeNames = map[string]bool{
	"int": true, "double": true, "num": true, "String": true, "bool": true,
	"List": true, "Map": true, "Set": true, "Function": true, "Object": true,
	"DateTime": true, "Duration": true, "RegExp": true, "Iterable": true,
	"StringBuffer": true, "BigInt": true, "Uri": true, "Type": true, "Symbol": true,
	"Pattern": true, "Match": true, "Comparable": true, "Stopwatch": true,
}

// nativeMapConstructors are Dart core map constructors that materialize as a
// native runtime map (the engine's own instance-map backings).
var nativeMapConstructors = map[string]bool{
	"LinkedHashMap": true, "HashMap": true, "SplayTreeMap": true,
}

// nativeSuperclassFields are the backing instance fields of a native superclass
// (no user TypeDefinition). BallObject extends BallMap inherits `entries`.
var nativeSuperclassFields = map[string][]string{
	"BallMap": {"entries"},
}

// valueModelWrapperFields maps the engine's native value-model wrapper
// constructors (ball_value.dart) to their positional field name.
var valueModelWrapperFields = map[string][]string{
	"BallInt": {"value"}, "BallDouble": {"value"}, "BallString": {"value"},
	"BallBool": {"value"}, "BallList": {"items"}, "BallMap": {"entries"},
}

// indexConstructors records every body-carrying constructor's impl name.
func (c *Compiler) indexConstructors() {
	for _, owner := range c.classMemberOrder {
		for _, member := range c.classMembers[owner] {
			if metaString(member.GetMetadata(), "kind") != "constructor" || member.GetBody() == nil {
				continue
			}
			if _, m, ok := splitMemberName(member.GetName()); ok {
				c.bodyCtorImpl[typeShortName(owner)] = memberImplName(typeShortName(owner), m)
			}
		}
	}
}

// memberImplName is the impl func name for a class member (Owner__member).
func memberImplName(ownerShort, member string) string {
	return sanitize(ownerShort) + "__" + sanitize(member)
}

func (c *Compiler) bodyConstructorImpl(typeName string) (string, bool) {
	if typeName == "" {
		return "", false
	}
	impl, ok := c.bodyCtorImpl[typeShortName(typeName)]
	return impl, ok
}

// ── Enum + oneof + subtype namespaces ───────────────────────────────────────

func (c *Compiler) compileEnums() string {
	var b strings.Builder
	for _, m := range c.prog.GetModules() {
		if c.baseModules[m.GetName()] || c.stubModules[m.GetName()] {
			continue
		}
		for _, en := range m.GetEnums() {
			b.WriteString(c.compileEnumNamespace(en))
		}
	}
	return b.String()
}

// compileEnumNamespace emits a Ball enum as a runtime value: a var holding a
// message of {member: {index,name}, "values": [...]} (enum values are ordinary
// dynamic messages the engine reads .index/.name/.values off).
func (c *Compiler) compileEnumNamespace(en *descriptorpb.EnumDescriptorProto) string {
	full := en.GetName()
	short := sanitize(typeShortName(full))
	var b strings.Builder
	fmt.Fprintf(&b, "var ballEnum_%s = buildBallEnum_%s()\n", short, short)
	fmt.Fprintf(&b, "func buildBallEnum_%s() ballrt.Value {\n", short)
	b.WriteString("\t__ns := ballrt.NewMap()\n\t__values := ballrt.NewList()\n")
	for i, v := range en.GetValue() {
		ordinal := i
		if v.Number != nil {
			ordinal = int(v.GetNumber())
		}
		fmt.Fprintf(&b, "\t__m%d := ballrt.NewMap()\n", i)
		fmt.Fprintf(&b, "\t__m%d.Set(\"index\", int64(%d))\n", i, ordinal)
		fmt.Fprintf(&b, "\t__m%d.Set(\"name\", %q)\n", i, v.GetName())
		fmt.Fprintf(&b, "\t__e%d := ballrt.NewMessage(%q, __m%d)\n", i, full, i)
		fmt.Fprintf(&b, "\t__ns.Set(%q, __e%d)\n", v.GetName(), i)
		fmt.Fprintf(&b, "\t__values.Add(__e%d)\n", i)
	}
	b.WriteString("\t__ns.Set(\"values\", __values)\n")
	fmt.Fprintf(&b, "\treturn ballrt.NewMessage(%q, __ns)\n}\n\n", full)
	return b.String()
}

func (c *Compiler) compileOneofDiscriminators() string {
	names := make([]string, 0, len(oneofDiscriminators))
	for k := range oneofDiscriminators {
		names = append(names, k)
	}
	sort.Strings(names)
	var b strings.Builder
	for _, enumName := range names {
		members := oneofDiscriminators[enumName]
		fmt.Fprintf(&b, "var ballOneof_%s = func() ballrt.Value {\n\t__m := ballrt.NewMap()\n", sanitize(enumName))
		for _, mm := range members {
			fmt.Fprintf(&b, "\t__m.Set(%q, %q)\n", mm, mm)
		}
		fmt.Fprintf(&b, "\treturn ballrt.NewMessage(%q, __m)\n}()\n\n", enumName)
	}
	return b.String()
}

// compileSubtypeInit registers every typeDef's superclass edge so runtime is/as
// tests can walk the hierarchy.
func (c *Compiler) compileSubtypeInit() string {
	var lines []string
	for _, m := range c.prog.GetModules() {
		if c.baseModules[m.GetName()] || c.stubModules[m.GetName()] {
			continue
		}
		for _, td := range m.GetTypeDefs() {
			if sup := metaString(td.GetMetadata(), "superclass"); sup != "" {
				lines = append(lines, fmt.Sprintf("\tballrt.RegisterSubtype(%q, %q)", typeShortName(td.GetName()), typeShortName(sup)))
			}
		}
	}
	if len(lines) == 0 {
		return ""
	}
	return "func init() {\n" + strings.Join(lines, "\n") + "\n}\n\n"
}

// ── Class members (dispatchers + impls + static + constructors) ─────────────

func (c *Compiler) compileClassMembers() string {
	var impls strings.Builder
	// short member name → list of (owner, impl) for the runtime dispatcher.
	dispatch := map[string][]struct{ owner, impl string }{}
	var dispatchOrder []string

	for _, owner := range c.classMemberOrder {
		ownerTd, ok := c.typeDefsByShort[typeShortName(owner)]
		if !ok {
			continue
		}
		for _, member := range c.classMembers[owner] {
			_, memberShort, ok := splitMemberName(member.GetName())
			if !ok {
				continue
			}
			short := sanitize(memberShort)
			implName := memberImplName(typeShortName(owner), memberShort)

			if metaString(member.GetMetadata(), "kind") == "constructor" {
				if member.GetBody() != nil {
					impls.WriteString(c.compileConstructor(implName, ownerTd, member))
					impls.WriteString("\n")
				}
				continue
			}
			if metaBool(member.GetMetadata(), "is_static") {
				impls.WriteString(c.compileStaticMethod(short, member))
				impls.WriteString("\n")
				continue
			}
			impls.WriteString(c.compileMethodImpl(implName, ownerTd, member))
			impls.WriteString("\n")
			if _, seen := dispatch[short]; !seen {
				dispatchOrder = append(dispatchOrder, short)
			}
			dispatch[short] = append(dispatch[short], struct{ owner, impl string }{owner, implName})
		}
	}

	var b strings.Builder
	for _, short := range dispatchOrder {
		b.WriteString(c.compileDispatcher(short, dispatch[short]))
		b.WriteString("\n")
	}
	b.WriteString(impls.String())
	return b.String()
}

// compileDispatcher emits a run-time method dispatcher routing on the receiver's
// type_name to the matching impl.
func (c *Compiler) compileDispatcher(short string, targets []struct{ owner, impl string }) string {
	var b strings.Builder
	fmt.Fprintf(&b, "func %s(input ballrt.Value) ballrt.Value {\n", short)
	b.WriteString("\tself := ballrt.FieldGet(input, \"self\")\n")
	b.WriteString("\t__t := ballrt.ToStr(ballrt.MessageTypeName(self))\n")
	for _, t := range targets {
		fmt.Fprintf(&b, "\tif __t == %q || __t == %q { return %s(input) }\n", t.owner, typeShortName(t.owner), t.impl)
	}
	if short == "toString" {
		b.WriteString("\treturn ballrt.ToStringValue(self)\n")
	} else {
		fmt.Fprintf(&b, "\tpanic(ballrt.Thrown{Value: \"no method '%s' for \" + __t})\n", short)
	}
	b.WriteString("}\n")
	return b.String()
}

// compileStaticMethod emits a static class member as a plain function (no self).
func (c *Compiler) compileStaticMethod(short string, member *ballv1.FunctionDefinition) string {
	c.pushScope()
	prevIn, prevInput := c.inInstanceMethod, c.inputIsParam
	c.inInstanceMethod = false
	c.inputIsParam = hasInputParam(member)
	prologue := c.paramPrologue(member)
	body := c.compileBody(member)
	c.inInstanceMethod = prevIn
	c.inputIsParam = prevInput
	c.popScope()

	var b strings.Builder
	fmt.Fprintf(&b, "func %s(input ballrt.Value) (__ret ballrt.Value) {\n", short)
	b.WriteString("\t_ = input\n")
	b.WriteString(prologue)
	b.WriteString("\tdefer ballrt.CatchReturn(&__ret)\n")
	fmt.Fprintf(&b, "\t__ret = %s\n", body)
	b.WriteString("\treturn\n}\n")
	return b.String()
}

// compileMethodImpl emits an instance-method impl: binds the receiver (self) and
// each owner field as a read alias (Dart implicit-this), plus declared params,
// then the body. A volatile field (reassigned somewhere in the class) is read/
// written live through self, not aliased.
func (c *Compiler) compileMethodImpl(implName string, ownerTd *ballv1.TypeDefinition, member *ballv1.FunctionDefinition) string {
	c.pushScope()

	prevIn, prevSelf, prevVol := c.inInstanceMethod, c.selfRecvName, c.volatileFields
	prevInput := c.inputIsParam
	c.inInstanceMethod = true
	c.selfRecvName = "__self"
	c.volatileFields = c.volatileFieldsOf(ownerTd)
	c.inputIsParam = hasInputParam(member)

	params := funcParams(member)
	shadowed := map[string]bool{"self": true}
	for _, p := range params {
		shadowed[p] = true
	}

	var prologue strings.Builder
	// The receiver: the Dart encoder addresses `this.field` as
	// field_access(reference("self"), field) and implicit-this as
	// reference("self"). It binds an internal `__self` so a nested `let self`
	// (a local literally named self — the engine has several) cannot capture the
	// receiver; reference("self") resolves to `__self` only when no local `self`
	// is in scope (see compileReference).
	prologue.WriteString("\t__self := ballrt.FieldGet(input, \"self\")\n\t_ = __self\n")
	for _, field := range c.allInstanceFieldNames(ownerTd) {
		if shadowed[field] || c.volatileFields[field] {
			continue
		}
		c.bind(field)
		fmt.Fprintf(&prologue, "\t%s := ballrt.FieldGet(__self, %q)\n\t_ = %s\n", sanitize(field), field, sanitize(field))
	}
	for i, p := range params {
		c.bind(p)
		if p == "self" {
			// The one engine method with a param literally named `self`
			// (_dispatchBuiltinInstanceMethod) operates on the param, bound from
			// its positional slot — a real local `self` shadowing the receiver.
			fmt.Fprintf(&prologue, "\tself := ballrt.ArgGet(input, %q, %q)\n\t_ = self\n", fmt.Sprintf("arg%d", i), fmt.Sprintf("arg%d", i))
			continue
		}
		fmt.Fprintf(&prologue, "\t%s := ballrt.ArgGet(input, %q, %q)\n\t_ = %s\n", sanitize(p), p, fmt.Sprintf("arg%d", i), sanitize(p))
	}

	body := c.compileBody(member)

	c.inInstanceMethod, c.selfRecvName, c.volatileFields = prevIn, prevSelf, prevVol
	c.inputIsParam = prevInput
	c.popScope()

	var b strings.Builder
	fmt.Fprintf(&b, "func %s(input ballrt.Value) (__ret ballrt.Value) {\n", implName)
	b.WriteString("\t_ = input\n")
	b.WriteString(prologue.String())
	b.WriteString("\tdefer ballrt.CatchReturn(&__ret)\n")
	fmt.Fprintf(&b, "\t__ret = %s\n", body)
	b.WriteString("\treturn\n}\n")
	return b.String()
}

// compileConstructor emits a body-carrying constructor: bind params, build the
// instance (own + inherited fields defaulted / init-formal-seeded), run the body
// with each field aliased, then return the instance.
func (c *Compiler) compileConstructor(implName string, ownerTd *ballv1.TypeDefinition, ctor *ballv1.FunctionDefinition) string {
	c.pushScope()

	params := funcParams(ctor)
	paramSet := map[string]bool{}
	for _, p := range params {
		paramSet[p] = true
	}

	var b strings.Builder
	fmt.Fprintf(&b, "func %s(input ballrt.Value) ballrt.Value {\n", implName)
	b.WriteString("\t_ = input\n")
	for i, p := range params {
		c.bind(p)
		fmt.Fprintf(&b, "\t%s := ballrt.ArgGet(input, %q, %q)\n\t_ = %s\n", sanitize(p), p, fmt.Sprintf("arg%d", i), sanitize(p))
	}

	fields := c.allInstanceFieldNames(ownerTd)
	b.WriteString("\t__fields := ballrt.NewMap()\n")
	for _, field := range fields {
		var value string
		switch {
		case paramSet[field]:
			value = sanitize(field)
		case c.fieldInitializerParam(ctor, field, paramSet) != "":
			value = sanitize(c.fieldInitializerParam(ctor, field, paramSet))
		default:
			if def := c.fieldDefaultExpr(ownerTd, field); def != "" {
				value = def
			} else {
				value = "ballrt.Value(nil)"
			}
		}
		fmt.Fprintf(&b, "\t__fields.Set(%q, %s)\n", field, value)
	}
	fmt.Fprintf(&b, "\t__self := ballrt.NewMessage(%q, __fields)\n\t_ = __self\n", ownerTd.GetName())

	prevIn, prevSelf, prevVol := c.inInstanceMethod, c.selfRecvName, c.volatileFields
	prevInput := c.inputIsParam
	c.inInstanceMethod = true
	c.selfRecvName = "__self"
	c.volatileFields = c.volatileFieldsOf(ownerTd)
	c.inputIsParam = hasInputParam(ctor)

	for _, field := range fields {
		if c.volatileFields[field] || paramSet[field] {
			continue
		}
		c.bind(field)
		fmt.Fprintf(&b, "\t%s := ballrt.FieldGet(__self, %q)\n\t_ = %s\n", sanitize(field), field, sanitize(field))
	}

	if ctor.GetBody() != nil {
		fmt.Fprintf(&b, "\tballrt.RunBody(func() ballrt.Value { return %s })\n", c.compileExpr(ctor.GetBody()))
	}

	c.inInstanceMethod, c.selfRecvName, c.volatileFields = prevIn, prevSelf, prevVol
	c.inputIsParam = prevInput
	c.popScope()

	b.WriteString("\treturn __self\n}\n")
	return b.String()
}

// ── Class-hierarchy field resolution ────────────────────────────────────────

func (c *Compiler) superclassOf(td *ballv1.TypeDefinition) string {
	return metaString(td.GetMetadata(), "superclass")
}

// allInstanceFieldNames returns every instance-field name of ownerTd (own first,
// then inherited via the superclass chain, then native-base backing fields).
func (c *Compiler) allInstanceFieldNames(ownerTd *ballv1.TypeDefinition) []string {
	var names []string
	seen := map[string]bool{}
	add := func(td *ballv1.TypeDefinition) {
		for _, f := range td.GetDescriptor_().GetField() {
			if n := f.GetName(); n != "" && !seen[n] {
				seen[n] = true
				names = append(names, n)
			}
		}
	}
	add(ownerTd)
	cur := ownerTd
	for i := 0; i < 32; i++ {
		sup := c.superclassOf(cur)
		if sup == "" {
			break
		}
		if superTd, ok := c.typeDefsByShort[typeShortName(sup)]; ok {
			add(superTd)
			cur = superTd
			continue
		}
		for _, n := range nativeSuperclassFields[sup] {
			if !seen[n] {
				seen[n] = true
				names = append(names, n)
			}
		}
		break
	}
	return names
}

// fieldInitializerText returns the field-level initializer source text for a
// field (walking the superclass chain), or "".
func (c *Compiler) fieldInitializerText(td *ballv1.TypeDefinition, field string) string {
	cur := td
	for i := 0; i < 32; i++ {
		for _, entry := range metaList(cur.GetMetadata(), "fields") {
			s := entry.GetStructValue()
			if s == nil {
				continue
			}
			if structString(s, "name") == field {
				return structString(s, "initializer")
			}
		}
		sup := c.superclassOf(cur)
		if sup == "" {
			break
		}
		superTd, ok := c.typeDefsByShort[typeShortName(sup)]
		if !ok {
			break
		}
		cur = superTd
	}
	return ""
}

// fieldDefaultExpr returns a Go expression for field's default value, or "".
func (c *Compiler) fieldDefaultExpr(td *ballv1.TypeDefinition, field string) string {
	if text := c.fieldInitializerText(td, field); text != "" {
		if v := c.lowerFieldInitializer(text, map[string]bool{}); v != "" {
			return v
		}
	}
	return c.nativeInheritedFieldDefault(td, field)
}

// lowerFieldInitializer lowers a field-level initializer's source text to a Go
// BallValue expression for the common literal / zero-arg-constructor shapes.
func (c *Compiler) lowerFieldInitializer(init string, visiting map[string]bool) string {
	s := stripGenericPrefix(strings.TrimSpace(init))
	switch s {
	case "{}":
		return "ballrt.NewMap()"
	case "[]":
		return "ballrt.NewList()"
	case "''", "\"\"":
		return `""`
	case "true":
		return "true"
	case "false":
		return "false"
	case "null":
		return "ballrt.Value(nil)"
	}
	if isIntLiteral(s) {
		return "int64(" + s + ")"
	}
	if strings.HasSuffix(s, "()") {
		typeName := strings.TrimSpace(strings.TrimSuffix(s, "()"))
		if isSimpleIdent(typeName) {
			return c.constructDefaultInstance(typeName, visiting)
		}
	}
	return ""
}

func (c *Compiler) constructDefaultInstance(shortType string, visiting map[string]bool) string {
	if visiting[shortType] {
		return ""
	}
	visiting[shortType] = true
	defer delete(visiting, shortType)

	if nativeMapConstructors[shortType] {
		return "ballrt.NewMap()"
	}
	td, ok := c.typeDefsByShort[shortType]
	if !ok {
		return ""
	}
	if impl, ok := c.bodyConstructorImpl(shortType); ok {
		return impl + "(ballrt.NewMap())"
	}
	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n\t\t__f := ballrt.NewMap()\n")
	for _, field := range c.allInstanceFieldNames(td) {
		def := c.fieldDefaultExpr(td, field)
		if def == "" {
			def = "ballrt.Value(nil)"
		}
		fmt.Fprintf(&b, "\t\t__f.Set(%q, %s)\n", field, def)
	}
	fmt.Fprintf(&b, "\t\treturn ballrt.NewMessage(%q, __f)\n\t}()", td.GetName())
	return b.String()
}

func (c *Compiler) nativeInheritedFieldDefault(td *ballv1.TypeDefinition, field string) string {
	cur := td
	for i := 0; i < 32; i++ {
		sup := c.superclassOf(cur)
		if sup == "" {
			return ""
		}
		if superTd, ok := c.typeDefsByShort[typeShortName(sup)]; ok {
			cur = superTd
			continue
		}
		for _, f := range nativeSuperclassFields[sup] {
			if f == field {
				return "ballrt.NewMap()"
			}
		}
		return ""
	}
	return ""
}

// fieldInitializerParam returns the parameter a metadata.initializers entry sets
// field from (field = param / field = param ?? default), or "".
func (c *Compiler) fieldInitializerParam(ctor *ballv1.FunctionDefinition, field string, paramNames map[string]bool) string {
	for _, init := range metaList(ctor.GetMetadata(), "initializers") {
		s := init.GetStructValue()
		if s == nil || structString(s, "kind") != "field" || structString(s, "name") != field {
			continue
		}
		value := structString(s, "value")
		token := leadingIdent(strings.TrimSpace(value))
		if paramNames[token] {
			return token
		}
		return ""
	}
	return ""
}

// constructorParamNames returns a type's constructor parameter names in order.
func (c *Compiler) constructorParamNames(typeName string) []string {
	if typeName == "" {
		return nil
	}
	short := typeShortName(typeName)
	for _, owner := range c.classMemberOrder {
		if typeShortName(owner) != short {
			continue
		}
		for _, member := range c.classMembers[owner] {
			if metaString(member.GetMetadata(), "kind") == "constructor" {
				return funcParams(member)
			}
		}
	}
	if fields, ok := valueModelWrapperFields[short]; ok {
		return fields
	}
	return nil
}

// ── Mutation analysis (volatile-field detection) ────────────────────────────

func (c *Compiler) volatileFieldsOf(ownerTd *ballv1.TypeDefinition) map[string]bool {
	if cached, ok := c.volatileByOwner[ownerTd.GetName()]; ok {
		return cached
	}
	reassigned := map[string]bool{}
	for _, member := range c.classMembers[ownerTd.GetName()] {
		if member.GetBody() != nil {
			collectReassignedNames(member.GetBody(), reassigned)
		}
	}
	result := map[string]bool{}
	for _, field := range c.allInstanceFieldNames(ownerTd) {
		if reassigned[field] {
			result[field] = true
		}
	}
	c.volatileByOwner[ownerTd.GetName()] = result
	return result
}

// collectReassignedNames collects every bare-name reassignment target anywhere in
// expr (walking into literal.listValue elements, where Dart try catch-bodies live).
func collectReassignedNames(expr *ballv1.Expression, acc map[string]bool) {
	if expr == nil {
		return
	}
	switch x := expr.GetExpr().(type) {
	case *ballv1.Expression_Call:
		call := x.Call
		if (call.GetModule() == "std" || call.GetModule() == "") && isReassignFn(call.GetFunction()) {
			if mc := call.GetInput().GetMessageCreation(); mc != nil {
				for _, fv := range mc.GetFields() {
					if fv.GetName() == "target" || fv.GetName() == "value" {
						if ref := fv.GetValue().GetReference(); ref != nil {
							acc[ref.GetName()] = true
						}
					}
				}
			}
		}
		if call.GetInput() != nil {
			collectReassignedNames(call.GetInput(), acc)
		}
	case *ballv1.Expression_MessageCreation:
		for _, fv := range x.MessageCreation.GetFields() {
			collectReassignedNames(fv.GetValue(), acc)
		}
	case *ballv1.Expression_Literal:
		if lv := x.Literal.GetListValue(); lv != nil {
			for _, el := range lv.GetElements() {
				collectReassignedNames(el, acc)
			}
		}
	case *ballv1.Expression_Block:
		for _, s := range x.Block.GetStatements() {
			if let := s.GetLet(); let != nil {
				collectReassignedNames(let.GetValue(), acc)
			}
			if e := s.GetExpression(); e != nil {
				collectReassignedNames(e, acc)
			}
		}
		collectReassignedNames(x.Block.GetResult(), acc)
	case *ballv1.Expression_FieldAccess:
		collectReassignedNames(x.FieldAccess.GetObject(), acc)
	case *ballv1.Expression_Lambda:
		collectReassignedNames(x.Lambda.GetBody(), acc)
	}
}

func isReassignFn(fn string) bool {
	switch fn {
	case "assign", "pre_increment", "post_increment", "pre_decrement", "post_decrement":
		return true
	}
	return false
}

// ── Metadata helpers ────────────────────────────────────────────────────────

func metaBool(meta *structpb.Struct, key string) bool {
	if meta == nil {
		return false
	}
	if v, ok := meta.GetFields()[key]; ok {
		return v.GetBoolValue()
	}
	return false
}

func metaList(meta *structpb.Struct, key string) []*structpb.Value {
	if meta == nil {
		return nil
	}
	if v, ok := meta.GetFields()[key]; ok {
		if lv := v.GetListValue(); lv != nil {
			return lv.GetValues()
		}
	}
	return nil
}

func structString(s *structpb.Struct, key string) string {
	if s == nil {
		return ""
	}
	if v, ok := s.GetFields()[key]; ok {
		return v.GetStringValue()
	}
	return ""
}

// splitMemberName splits a class-member function name (main:Point.describe) into
// its owner (main:Point) and short member (describe). Returns ok=false for a
// standalone function (no dot after the module colon).
func splitMemberName(name string) (owner, member string, ok bool) {
	if colon := strings.LastIndex(name, ":"); colon >= 0 {
		after := name[colon+1:]
		dot := strings.Index(after, ".")
		if dot < 0 {
			return "", "", false
		}
		return name[:colon+1+dot], after[dot+1:], true
	}
	dot := strings.Index(name, ".")
	if dot < 0 {
		return "", "", false
	}
	return name[:dot], name[dot+1:], true
}
