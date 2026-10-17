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

// indexConstructors records every constructor's impl name.
//
// Two indexes, deliberately different (issue #527):
//   - unnamedCtorImpl is the UNNAMED (`new`) constructor only — the one a
//     `messageCreation` for the class invokes. Keying every constructor here
//     made the LAST named constructor win, so `Point(3, 4)` ran
//     `Point.constants()`'s body instead of its own.
//   - ctorImpl is every constructor by "<ClassShort>.<ctorShort>" — the target a
//     `Class.name(args)` call resolves to (compileCall).
func (c *Compiler) indexConstructors() {
	for _, owner := range c.classMemberOrder {
		ownerShort := typeShortName(owner)
		for _, member := range c.classMembers[owner] {
			if metaString(member.GetMetadata(), "kind") != "constructor" {
				continue
			}
			_, m, ok := splitMemberName(member.GetName())
			if !ok {
				continue
			}
			impl := memberImplName(ownerShort, m, false)
			if m == unnamedCtorMember {
				// Two reasons the unnamed constructor needs an impl of its own
				// rather than the inline field map compileMessageCreation
				// builds: a BODY (which must run — issue #300), and an
				// INITIALIZER LIST (`Foo(this.a, int b) : c = b;`). The inline
				// path reads `metadata.params` and nothing else, so a bodyless
				// constructor's initializer list was dropped whole: the
				// instance carried the plain parameter `b` as a bogus field and
				// never carried `c` at all, and `obj.c` then read a missing key
				// and answered `null` — a silent wrong answer (issue #706).
				if member.GetBody() != nil || ctorHasFieldInitializers(member) {
					c.unnamedCtorImpl[ownerShort] = impl
				}
				continue
			}
			// A named constructor always gets an impl emitted (see
			// compileClassMembers), body or not — it is only ever reached
			// through a `Class.name(...)` call.
			c.ctorImpl[ownerShort+"."+m] = impl
		}
	}
}

// unnamedCtorMember is the member short name the encoders give Dart's unnamed
// constructor (`main:Point.new`).
const unnamedCtorMember = "new"

// namedConstructorImpl returns the impl func of class classShort's named
// constructor ctorShort, if there is one.
func (c *Compiler) namedConstructorImpl(classShort, ctorShort string) (string, bool) {
	impl, ok := c.ctorImpl[classShort+"."+ctorShort]
	return impl, ok
}

// memberImplName is the impl func name for a class member: `Owner__member`,
// or `Owner__member__set` for a setter (isSetter). A Dart `get celsius` and
// its `set celsius(value)` carry the SAME Ball function name
// (`main:Temperature.celsius`) — only metadata.is_getter/is_setter tells them
// apart — and Go flattens every class member to one top-level func, so the
// pair collided on one identifier (a duplicate Go declaration, caught only at
// `go build`/`go run`, never by the formatter: issue #813, fixture
// 470_setter_beside_final_field). The `__set` suffix is the Go sibling of
// C#'s MemberImplName (csharp/compiler/src/Constructors.cs) — same reason,
// since C# hits the identical one-name-one-method constraint.
func memberImplName(ownerShort, member string, isSetter bool) string {
	suffix := ""
	if isSetter {
		suffix = "__set"
	}
	return sanitize(ownerShort) + "__" + sanitize(member) + suffix
}

func (c *Compiler) unnamedConstructorImpl(typeName string) (string, bool) {
	if typeName == "" {
		return "", false
	}
	impl, ok := c.unnamedCtorImpl[typeShortName(typeName)]
	return impl, ok
}

// ctorHasFieldInitializers reports whether ctor carries a Dart initializer list
// — a `metadata.initializers` entry of kind "field" (issue #706).
func ctorHasFieldInitializers(ctor *ballv1.FunctionDefinition) bool {
	for _, init := range metaList(ctor.GetMetadata(), "initializers") {
		if s := init.GetStructValue(); s != nil && structString(s, "kind") == "field" {
			return true
		}
	}
	return false
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

// compileOneofDiscriminators emits a `var ballOneof_<Enum>` namespace for every
// synthesized oneof discriminator the program REFERENCES — never the whole
// table. Emitting all of it unconditionally left five dead top-level vars at the
// head of every compiled program (a hello-world included), which is both dead
// code and the bulk of what the Go encoder refuses when it re-reads the
// compiler's own output (issue #642). `usedOneofs` is populated by
// compileReference, the only site that resolves a bare name to one of these, so
// nothing referenced can go unemitted.
func (c *Compiler) compileOneofDiscriminators() string {
	names := make([]string, 0, len(c.usedOneofs))
	for k := range c.usedOneofs {
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
			isGetter := metaBool(member.GetMetadata(), "is_getter")
			isSetter := metaBool(member.GetMetadata(), "is_setter")
			implName := memberImplName(typeShortName(owner), memberShort, isSetter)

			if metaString(member.GetMetadata(), "kind") == "constructor" {
				// A NAMED constructor always needs an impl: it is only ever
				// reached through a `Class.name(...)` call, which compiles to a
				// direct call of this func (issue #527). The unnamed one needs
				// an impl when it carries a body OR an initializer list — the
				// two things compileMessageCreation's inline field map cannot
				// express (issues #300 and #706). Keep this condition identical
				// to indexConstructors': a recorded impl that is never emitted
				// is an undefined identifier in the emitted Go.
				if member.GetBody() != nil || memberShort != unnamedCtorMember ||
					ctorHasFieldInitializers(member) {
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
			if isGetter || isSetter {
				// A getter/setter is reached only through fieldAccess/assign
				// (compileFieldAccess / emitMutation) or an implicit-`this`
				// bare reference (compileReference) — never through an
				// ordinary `obj.name(args)` call — so it is dispatched by the
				// dedicated per-PROPERTY accessor mechanism (compileAccessors)
				// instead of this general per-short-NAME method dispatcher.
				// That separation is required, not cosmetic: a getter and a
				// setter of the SAME name need two DIFFERENT call shapes
				// ({self} vs {self, value}), which one shared dispatcher slot
				// cannot express — grouping them here produced a duplicated,
				// permanently-dead `if __t == ...` branch under the same
				// owner (issue #813).
				continue
			}
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

// ── Property (getter/setter) accessor dispatch (issue #813) ────────────────
//
// A Dart `get celsius` and its `set celsius(value)` carry the SAME Ball
// function name, so Go's general per-short-name method dispatcher
// (compileDispatcher, above) cannot carry both — a getter's call shape is
// `{self}`, a setter's is `{self, value}`, and one generated function cannot
// answer to either shape depending on which arm happens to run first (that
// was the duplicated, permanently-dead branch 470_setter_beside_final_field
// exposed). A property is also never *called* — the IR reaches it as a
// `field_access` (a read, compileFieldAccess), an `std.assign` whose target
// is a `field_access` (a write, emitMutation's "field" case), or an
// implicit-`this` bare `reference` from inside the declaring class
// (compileReference) — so it needs its own dispatch keyed on the PROPERTY
// NAME, resolving the receiver's run-time type through the SAME
// metadata.superclass walk every other class-hierarchy lookup here uses, and
// falling back to a plain ballrt.FieldGet/FieldSet for any receiver that is
// NOT one of those classes (a map, a proto message, a core value, or a user
// class that never declares the property at all). That fallback is exactly
// what every one of those three call sites already emitted for a field
// access before this existed, so routing a name some class exposes as a
// property is a strict superset — never a silent change for any other
// receiver. The Go sibling of C#'s csharp/compiler/src/Accessors.cs.

// indexAccessors records every short member name some class declares as an
// instance getter or setter — called once from newCompiler, before any
// emission, so compileFieldAccess/emitMutation/compileReference can consult
// it while compiling bodies that run EARLIER in program order than the class
// that declares the accessor.
//
// An EXTENSION typeDef's getter/setter is deliberately excluded (merge
// interaction between #670 and #813, caught compiling
// 480_extension_override_selection after this PR absorbed #813): an
// extension carries no `descriptor` (the same reason compileClassMembers'
// C++ sibling skips its struct emission entirely — see the extension-override
// bullet above), so accessorTargets' `td.GetDescriptor_() == nil` guard can
// never find a target for an extension's property, no matter how
// indexAccessors classifies it. Marking it a getter/setter anyway made
// compileAccessors emit a dispatcher whose only statement is an unused
// `__t := ballrt.ToStr(...)` followed by an unconditional fallback — a Go
// compile error (`declared and not used: __t`) on ANY program with an
// extension declaring a getter or setter, extension-override test program
// included. An extension's accessor is reached exclusively through the
// override CALL mechanism (compileCall + extensionMemberImpl) — Dart has no
// `obj.property` syntax that resolves to an extension on an unrelated
// receiver type — so it was never reachable through
// compileFieldAccess/emitMutation/compileReference's redirect in the first
// place; excluding it here loses nothing.
func (c *Compiler) indexAccessors() {
	for _, owner := range c.classMemberOrder {
		// A member whose owner has no TypeDefinition gets no impl emitted (see
		// compileClassMembers), so it can never be dispatched to.
		td, ok := c.typeDefsByShort[typeShortName(owner)]
		if !ok || metaString(td.GetMetadata(), "kind") == "extension" {
			continue
		}
		for _, member := range c.classMembers[owner] {
			if metaString(member.GetMetadata(), "kind") != "method" || metaBool(member.GetMetadata(), "is_static") {
				continue
			}
			_, short, ok := splitMemberName(member.GetName())
			if !ok {
				continue
			}
			if metaBool(member.GetMetadata(), "is_getter") {
				c.getterMembers[short] = true
			} else if metaBool(member.GetMetadata(), "is_setter") {
				c.setterMembers[short] = true
			}
		}
	}
}

// accessorGetFuncName / accessorSetFuncName are the generated per-property
// dispatcher names compileFieldAccess/emitMutation/compileReference call into.
func accessorGetFuncName(member string) string { return "ballAccessorGet_" + sanitize(member) }
func accessorSetFuncName(member string) string { return "ballAccessorSet_" + sanitize(member) }

// resolveAccessorImpl returns the impl func an instance of td resolves the
// getter (or setter) member to — found by walking td's metadata.superclass
// chain so a subclass inherits its parent's property — or ("", false) when no
// class in the chain declares it. A class that declares its OWN plain field
// of this name SHADOWS any inherited accessor (ordinary Dart/OOP override
// semantics: `class B extends A { int x = 5; }` over `A`'s `get x`), so the
// walk stops there rather than running past it to an ancestor's accessor —
// mirrors C#'s Accessors.cs ResolveAccessorImpl, including its #461 fix.
func (c *Compiler) resolveAccessorImpl(td *ballv1.TypeDefinition, member string, setter bool) (string, bool) {
	cur := td
	for i := 0; i < 32; i++ {
		for _, candidate := range c.classMembers[cur.GetName()] {
			if metaString(candidate.GetMetadata(), "kind") != "method" || metaBool(candidate.GetMetadata(), "is_static") {
				continue
			}
			_, short, ok := splitMemberName(candidate.GetName())
			if !ok || short != member {
				continue
			}
			key := "is_getter"
			if setter {
				key = "is_setter"
			}
			if !metaBool(candidate.GetMetadata(), key) {
				continue
			}
			return memberImplName(typeShortName(cur.GetName()), member, setter), true
		}
		for _, f := range cur.GetDescriptor_().GetField() {
			if f.GetName() == member {
				return "", false
			}
		}
		sup := c.superclassOf(cur)
		if sup == "" {
			return "", false
		}
		superTd, ok := c.typeDefsByShort[typeShortName(sup)]
		if !ok {
			return "", false
		}
		cur = superTd
	}
	return "", false
}

// accessorTargets lists every user type (declaration order) resolving the
// property member, paired with the impl it resolves to.
func (c *Compiler) accessorTargets(member string, setter bool) []struct{ owner, impl string } {
	var targets []struct{ owner, impl string }
	for _, m := range c.prog.GetModules() {
		if c.baseModules[m.GetName()] || c.stubModules[m.GetName()] {
			continue
		}
		for _, td := range m.GetTypeDefs() {
			if td.GetDescriptor_() == nil {
				continue
			}
			if impl, ok := c.resolveAccessorImpl(td, member, setter); ok {
				targets = append(targets, struct{ owner, impl string }{td.GetName(), impl})
			}
		}
	}
	return targets
}

// compileAccessors emits, for every property name some class declares as a
// getter or a setter, the dedicated dispatcher(s) compileFieldAccess/
// emitMutation/compileReference call into. Empty when the program declares no
// property.
func (c *Compiler) compileAccessors() string {
	names := map[string]bool{}
	for n := range c.getterMembers {
		names[n] = true
	}
	for n := range c.setterMembers {
		names[n] = true
	}
	if len(names) == 0 {
		return ""
	}
	ordered := make([]string, 0, len(names))
	for n := range names {
		ordered = append(ordered, n)
	}
	sort.Strings(ordered)

	var b strings.Builder
	for _, member := range ordered {
		if c.getterMembers[member] {
			b.WriteString(c.compileGetterAccessor(member))
		}
		if c.setterMembers[member] {
			b.WriteString(c.compileSetterAccessor(member))
		}
	}
	return b.String()
}

// compileGetterAccessor is a property READ: invoke the resolved class's
// getter impl with {self}, else read the field.
func (c *Compiler) compileGetterAccessor(member string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "func %s(obj ballrt.Value) ballrt.Value {\n", accessorGetFuncName(member))
	b.WriteString("\t__t := ballrt.ToStr(ballrt.MessageTypeName(obj))\n")
	for _, t := range c.accessorTargets(member, false) {
		fmt.Fprintf(&b, "\tif __t == %q || __t == %q { return %s(ballrt.WithSelf(ballrt.Value(nil), obj)) }\n", t.owner, typeShortName(t.owner), t.impl)
	}
	fmt.Fprintf(&b, "\treturn ballrt.FieldGet(obj, %q)\n", member)
	b.WriteString("}\n\n")
	return b.String()
}

// compileSetterAccessor is a property WRITE: invoke the resolved class's
// setter impl with {self, arg0}, else write the field. The assigned value is
// returned regardless (an assignment EXPRESSION evaluates to the assigned
// value, even though a setter's own body yields something else or nothing).
func (c *Compiler) compileSetterAccessor(member string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "func %s(obj, value ballrt.Value) ballrt.Value {\n", accessorSetFuncName(member))
	b.WriteString("\t__t := ballrt.ToStr(ballrt.MessageTypeName(obj))\n")
	for _, t := range c.accessorTargets(member, true) {
		fmt.Fprintf(&b, "\tif __t == %q || __t == %q { %s(ballrt.Arg0WithSelf(value, obj)); return value }\n", t.owner, typeShortName(t.owner), t.impl)
	}
	fmt.Fprintf(&b, "\treturn ballrt.FieldSet(obj, %q, value)\n", member)
	b.WriteString("}\n\n")
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
		switch init := c.constructorInitializer(ctor, field, paramSet); {
		case paramSet[field]:
			value = sanitize(field)
		case init != "":
			value = init
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
	if isDoubleLiteral(s) {
		return "float64(" + s + ")"
	}
	if lit, ok := plainStringLiteral(s); ok {
		return fmt.Sprintf("%q", lit)
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
	if impl, ok := c.unnamedConstructorImpl(shortType); ok {
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

// constructorInitializer returns the Go expression a metadata.initializers entry
// gives field, or "" when the constructor has no initializer for it.
//
// The initializer's `value` is cosmetic source text (not an expression tree), so
// two shapes are recognised: a bare parameter reference (`x = a`), and any
// literal / zero-arg-constructor shape lowerFieldInitializer already handles
// (`label = 'pt'`, `y = -3`, `ratio = 0.5`, `on = true`). A richer expression
// still yields "" — the documented best-effort boundary — but it no longer
// silently drops the whole initializer list of a body-carrying constructor
// (issue #527: `label` stayed nil and the body's `label + '!'` then crashed).
func (c *Compiler) constructorInitializer(ctor *ballv1.FunctionDefinition, field string, paramNames map[string]bool) string {
	for _, init := range metaList(ctor.GetMetadata(), "initializers") {
		s := init.GetStructValue()
		if s == nil || structString(s, "kind") != "field" || structString(s, "name") != field {
			continue
		}
		value := strings.TrimSpace(structString(s, "value"))
		if token := leadingIdent(value); paramNames[token] {
			return sanitize(token)
		}
		return c.lowerFieldInitializer(value, map[string]bool{})
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
			// The UNNAMED constructor's parameters are the ones a
			// `messageCreation`'s positional argN fields map onto; a named
			// constructor's are read at its own call site (issue #527).
			if metaString(member.GetMetadata(), "kind") != "constructor" {
				continue
			}
			if _, m, ok := splitMemberName(member.GetName()); ok && m != unnamedCtorMember {
				continue
			}
			return funcParams(member)
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
