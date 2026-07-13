// Package compiler implements the Ball → Go compiler: it walks a Ball `Program`
// protobuf and emits Go source as a string (the string-emission approach shared
// by the C++/Rust/C# compilers, rather than an AST builder like Dart's
// code_builder).
//
// # Shape of the emitted code
//
// Every Ball expression compiles to a Go expression that evaluates to a
// `ballrt.Value` (package `github.com/ball-lang/ball/go/runtime`) — there are no
// "void" expressions, so every position (block tail, if/else arm, function
// body) stays type-uniform, exactly like the Rust/C# compilers. Go has no
// block/if/loop *expressions*, so anything used in value position that needs
// statements is wrapped in an immediately-invoked function expression (IIFE),
// `func() ballrt.Value { … }()` — the same device C++ uses. Crucially,
// `return`/`break`/`continue`/`throw` compile to `ballrt` flow signals (panics)
// recovered at the enclosing function/loop, so they cross IIFE boundaries
// correctly — a bare Go `return` inside an IIFE could not (invariant #4).
//
// # Two output modes
//
//   - Program mode (Compile) — a runnable `package main` with `func main()`
//     inlining the entry function (the fixtures / user programs).
//   - Library mode (CompileLibrary) — a named package with NO `func main()`,
//     every function/class-member emitted as a flat top-level func, for the
//     self-hosted engine (epic #426 Phase 4): the reference engine is itself a
//     Ball program whose public surface is classes (BallEngine/StdModuleHandler)
//     the wrapper constructs and drives.
package compiler

import (
	"fmt"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// runtimeImportPath is the module path of the emitted code's runtime dependency.
const runtimeImportPath = "github.com/ball-lang/ball/go/runtime"

// Compiler holds the lookup tables needed to compile one Program.
type Compiler struct {
	prog *ballv1.Program

	// libraryMode emits a named package with no func main (the self-hosted
	// engine); false emits a runnable `package main` (fixtures / user programs).
	libraryMode bool
	pkgName     string

	// baseModules is the set of module names whose functions are all base
	// (is_base = true) — e.g. "std", "std_collections". A call into one of
	// these dispatches through compileBaseCall.
	baseModules map[string]bool

	// stubModules are import-only modules (declared but carrying no functions,
	// types, or enums — e.g. dart.math/dart.io/protobuf, the external libraries
	// the self-host source imports). A call into one is an unimplemented external
	// base function (fail-loud), not a phantom class member.
	stubModules map[string]bool

	// userFuncs is the set of sanitized names of every callable top-level user
	// function / class-member short name (the direct-call / tear-off targets).
	userFuncs map[string]bool

	// instanceMethods is the set of sanitized instance-method short names — the
	// implicit-`this` injection targets.
	instanceMethods map[string]bool

	// topLevelVars is the set of sanitized top-level variable/getter names (a
	// bare reference invokes the nullary getter, not a function tear-off).
	topLevelVars map[string]bool

	// classMembers groups a class's members (methods/getters/setters/ctors) by
	// their owner TypeDefinition.Name.
	classMembers map[string][]*ballv1.FunctionDefinition
	// classMemberOrder preserves first-seen owner order for deterministic output.
	classMemberOrder []string

	// typeDefsByShort maps a type's short name to its TypeDefinition.
	typeDefsByShort map[string]*ballv1.TypeDefinition

	// bodyCtorImpl maps a class short name to the impl func of its body-carrying
	// constructor (if any) — the target CompileMessageCreation invokes.
	bodyCtorImpl map[string]string

	// volatileByOwner caches the reassigned-field set per owner TypeDefinition.
	volatileByOwner map[string]map[string]bool

	// scopes is the lexical scope stack of sanitized local names.
	scopes []map[string]bool

	// gotoSwitches is the stack of enclosing labelled (goto) switches, innermost
	// last — the targets a `continue <caseLabel>` can jump to.
	gotoSwitches []gotoSwitch

	// Per-body instance-method context (for implicit-`this` injection).
	inInstanceMethod bool
	selfRecvName     string
	volatileFields   map[string]bool

	// inputIsParam is true when the current function/method/lambda declares a
	// parameter literally named "input" (e.g. _callBaseFunction(module, function,
	// input)); a reference("input") then resolves to that bound local rather than
	// the raw method-wrapper parameter.
	inputIsParam bool

	// errs accumulates fail-loud compile errors (issue #55 doctrine).
	errs []string

	tempCounter int
}

// gotoSwitch is one enclosing labelled switch being compiled: the state variable
// its arms are selected by, the synthetic break label its driver recovers, and
// the Ball case label → arm index map a `continue <label>` resolves through.
type gotoSwitch struct {
	stateVar string
	label    string
	labels   map[string]int
}

// New builds a Compiler for prog in program mode.
func New(prog *ballv1.Program) *Compiler { return newCompiler(prog, false, "main") }

// newLibrary builds a Compiler for prog in library mode targeting pkgName.
func newLibrary(prog *ballv1.Program, pkgName string) *Compiler {
	return newCompiler(prog, true, pkgName)
}

func newCompiler(prog *ballv1.Program, libraryMode bool, pkgName string) *Compiler {
	c := &Compiler{
		prog:            prog,
		libraryMode:     libraryMode,
		pkgName:         pkgName,
		baseModules:     map[string]bool{},
		stubModules:     map[string]bool{},
		userFuncs:       map[string]bool{},
		instanceMethods: map[string]bool{},
		topLevelVars:    map[string]bool{},
		classMembers:    map[string][]*ballv1.FunctionDefinition{},
		typeDefsByShort: map[string]*ballv1.TypeDefinition{},
		bodyCtorImpl:    map[string]string{},
		volatileByOwner: map[string]map[string]bool{},
		volatileFields:  map[string]bool{},
	}
	for _, m := range prog.GetModules() {
		fns := m.GetFunctions()
		allBase := len(fns) > 0
		for _, f := range fns {
			if !f.GetIsBase() {
				allBase = false
				break
			}
		}
		switch {
		case allBase:
			c.baseModules[m.GetName()] = true
		case len(fns) == 0 && len(m.GetTypeDefs()) == 0 && len(m.GetEnums()) == 0:
			c.stubModules[m.GetName()] = true
		}
	}
	for _, m := range prog.GetModules() {
		if c.baseModules[m.GetName()] || c.stubModules[m.GetName()] {
			continue
		}
		for _, td := range m.GetTypeDefs() {
			c.typeDefsByShort[typeShortName(td.GetName())] = td
		}
		for _, f := range m.GetFunctions() {
			if f.GetIsBase() {
				continue
			}
			if owner, member, ok := splitMemberName(f.GetName()); ok {
				if _, seen := c.classMembers[owner]; !seen {
					c.classMemberOrder = append(c.classMemberOrder, owner)
				}
				c.classMembers[owner] = append(c.classMembers[owner], f)
				c.userFuncs[sanitize(member)] = true
				if metaString(f.GetMetadata(), "kind") != "constructor" && !metaBool(f.GetMetadata(), "is_static") {
					c.instanceMethods[sanitize(member)] = true
				}
				continue
			}
			// A standalone function (entry included — it is emitted too, just not
			// as the direct callable in program mode).
			if !(m.GetName() == prog.GetEntryModule() && f.GetName() == prog.GetEntryFunction()) {
				c.userFuncs[sanitize(f.GetName())] = true
			}
			if metaString(f.GetMetadata(), "kind") == "top_level_variable" {
				c.topLevelVars[sanitize(f.GetName())] = true
			}
		}
	}
	c.indexConstructors()
	return c
}

// Compile compiles the whole Program to a runnable Go source string (program
// mode). Returns an error if any expression shape or base function was
// unsupported (fail-loud).
func Compile(prog *ballv1.Program) (string, error) { return New(prog).compile() }

// CompileLibrary compiles the whole Program to a Go library in package pkgName
// (no func main) — used for the self-hosted engine (epic #426 Phase 4).
func CompileLibrary(prog *ballv1.Program, pkgName string) (string, error) {
	return newLibrary(prog, pkgName).compile()
}

func (c *Compiler) compile() (string, error) {
	var b strings.Builder
	if c.libraryMode {
		fmt.Fprintf(&b, "// Code generated by the Ball Go compiler from program %q v%s. DO NOT EDIT.\n",
			c.prog.GetName(), c.prog.GetVersion())
		fmt.Fprintf(&b, "//go:build selfhost\n\npackage %s\n\n", c.pkgName)
		fmt.Fprintf(&b, "import ballrt %q\n\n", runtimeImportPath)
	} else {
		entryMod, entryFn := c.entryPoint()
		if entryFn == nil {
			return "", fmt.Errorf("entry function %q not found in module %q",
				c.prog.GetEntryFunction(), c.prog.GetEntryModule())
		}
		_ = entryMod
		fmt.Fprintf(&b, "// Code generated by the Ball Go compiler from program %q v%s. DO NOT EDIT.\n",
			c.prog.GetName(), c.prog.GetVersion())
		b.WriteString("package main\n\n")
		fmt.Fprintf(&b, "import ballrt %q\n\n", runtimeImportPath)
	}

	// Enum namespaces + the subtype-hierarchy init (both modes).
	b.WriteString(c.compileEnums())
	b.WriteString(c.compileSubtypeInit())

	// Standalone (non-base, non-member) functions.
	for _, m := range c.prog.GetModules() {
		if c.baseModules[m.GetName()] || c.stubModules[m.GetName()] {
			continue
		}
		for _, f := range m.GetFunctions() {
			if f.GetIsBase() {
				continue
			}
			if _, _, ok := splitMemberName(f.GetName()); ok {
				continue
			}
			if !c.libraryMode && m.GetName() == c.prog.GetEntryModule() && f.GetName() == c.prog.GetEntryFunction() {
				continue // inlined into main below
			}
			b.WriteString(c.compileFunction(f))
			b.WriteString("\n")
		}
	}

	// Class members (dispatchers + impls + constructors) for every owner.
	b.WriteString(c.compileClassMembers())

	// Oneof discriminator namespaces (Expression_Expr, …).
	b.WriteString(c.compileOneofDiscriminators())

	// The entry point (program mode only).
	if !c.libraryMode {
		_, entryFn := c.entryPoint()
		b.WriteString(c.compileEntry(entryFn))
	}

	if len(c.errs) > 0 {
		return b.String(), fmt.Errorf("ball→go: %d unsupported construct(s):\n  - %s",
			len(c.errs), strings.Join(dedupe(c.errs), "\n  - "))
	}
	return b.String(), nil
}

func (c *Compiler) entryPoint() (*ballv1.Module, *ballv1.FunctionDefinition) {
	for _, m := range c.prog.GetModules() {
		if m.GetName() != c.prog.GetEntryModule() {
			continue
		}
		for _, f := range m.GetFunctions() {
			if f.GetName() == c.prog.GetEntryFunction() {
				return m, f
			}
		}
	}
	return nil, nil
}

// ── Function emission ───────────────────────────────────────────────────────

// compileFunction emits a standalone function as
// `func name(input ballrt.Value) (__ret ballrt.Value) { … }` (invariant #1).
func (c *Compiler) compileFunction(f *ballv1.FunctionDefinition) string {
	name := sanitize(f.GetName())
	c.pushScope()
	prevInput := c.inputIsParam
	c.inputIsParam = hasInputParam(f)
	prologue := c.paramPrologue(f)
	body := c.compileBody(f)
	c.inputIsParam = prevInput
	c.popScope()

	// A top-level variable (Dart `const`/`final`/`var` at library scope) is a
	// SINGLETON: its initializer runs once and every read yields the SAME value.
	// Compiling it to a plain function that re-evaluates the initializer on each
	// read breaks reference identity — e.g. `const _sentinel = Object()`, used as
	// the getter/setter "not found" marker via `result != _sentinel`, minted a
	// fresh object each read, so the comparison was always true and the sentinel
	// leaked out as a real field value (map `.length`/`.values` returned the
	// sentinel `main:Object`). Memoize the first computed value; the engine runs
	// on one goroutine, so no lock is needed.
	if metaString(f.GetMetadata(), "kind") == "top_level_variable" {
		var b strings.Builder
		fmt.Fprintf(&b, "var %s__val ballrt.Value\nvar %s__init bool\n", name, name)
		fmt.Fprintf(&b, "func %s(input ballrt.Value) ballrt.Value {\n\t_ = input\n", name)
		fmt.Fprintf(&b, "\tif !%s__init {\n\t\t%s__init = true\n", name, name)
		fmt.Fprintf(&b, "\t\t%s__val = func() (__ret ballrt.Value) {\n", name)
		b.WriteString(indent(prologue, "\t\t"))
		b.WriteString("\t\t\tdefer ballrt.CatchReturn(&__ret)\n")
		fmt.Fprintf(&b, "\t\t\t__ret = %s\n\t\t\treturn\n\t\t}()\n\t}\n", body)
		fmt.Fprintf(&b, "\treturn %s__val\n}\n", name)
		return b.String()
	}

	var b strings.Builder
	fmt.Fprintf(&b, "func %s(input ballrt.Value) (__ret ballrt.Value) {\n", name)
	b.WriteString("\t_ = input\n")
	b.WriteString(prologue)
	b.WriteString("\tdefer ballrt.CatchReturn(&__ret)\n")
	fmt.Fprintf(&b, "\t__ret = %s\n", body)
	b.WriteString("\treturn\n}\n")
	return b.String()
}

// compileEntry inlines the entry function's body into Go's func main.
func (c *Compiler) compileEntry(f *ballv1.FunctionDefinition) string {
	c.pushScope()
	prevInput := c.inputIsParam
	c.inputIsParam = hasInputParam(f)
	prologue := c.paramPrologue(f)
	body := c.compileBody(f)
	c.inputIsParam = prevInput
	c.popScope()

	var b strings.Builder
	b.WriteString("func main() {\n")
	b.WriteString("\tballrt.RunEntry(func() ballrt.Value {\n")
	if prologue != "" {
		b.WriteString(indent(prologue, "\t"))
	}
	fmt.Fprintf(&b, "\t\treturn %s\n", body)
	b.WriteString("\t})\n}\n")
	return b.String()
}

func (c *Compiler) compileBody(f *ballv1.FunctionDefinition) string {
	if f.GetBody() == nil {
		return "ballrt.Value(nil)"
	}
	return c.compileExpr(f.GetBody())
}

// paramPrologue emits the `let`-style aliases binding a function's declared
// parameter names to its single `input` (invariant #1). One positional parameter
// is passed directly; multiple parameters read by name-or-positional slot from
// the packed input (ArgGet: prefer the name, fall back to argN).
func (c *Compiler) paramPrologue(f *ballv1.FunctionDefinition) string {
	params := funcParams(f)
	if len(params) == 0 {
		return ""
	}
	var b strings.Builder
	if len(params) == 1 {
		n := sanitize(params[0])
		c.bind(params[0])
		fmt.Fprintf(&b, "\t%s := input\n\t_ = %s\n", n, n)
		return b.String()
	}
	for i, p := range params {
		n := sanitize(p)
		c.bind(p)
		fmt.Fprintf(&b, "\t%s := ballrt.ArgGet(input, %q, %q)\n\t_ = %s\n", n, p, fmt.Sprintf("arg%d", i), n)
	}
	return b.String()
}

// ── Expression compilation (the 7 node types) ───────────────────────────────

func (c *Compiler) compileExpr(e *ballv1.Expression) string {
	if e == nil || e.GetExpr() == nil {
		return "ballrt.Value(nil)"
	}
	switch x := e.GetExpr().(type) {
	case *ballv1.Expression_Literal:
		return c.compileLiteral(x.Literal)
	case *ballv1.Expression_Reference:
		return c.compileReference(x.Reference)
	case *ballv1.Expression_Call:
		return c.compileCall(x.Call)
	case *ballv1.Expression_FieldAccess:
		return c.compileFieldAccess(x.FieldAccess)
	case *ballv1.Expression_MessageCreation:
		return c.compileMessageCreation(x.MessageCreation)
	case *ballv1.Expression_Block:
		return c.compileBlock(x.Block)
	case *ballv1.Expression_Lambda:
		return c.compileLambda(x.Lambda)
	default:
		c.fail("unhandled expression node %T", x)
		return "ballrt.Value(nil)"
	}
}

func (c *Compiler) compileLiteral(l *ballv1.Literal) string {
	switch v := l.GetValue().(type) {
	case *ballv1.Literal_IntValue:
		return fmt.Sprintf("int64(%d)", v.IntValue)
	case *ballv1.Literal_DoubleValue:
		return fmt.Sprintf("float64(%s)", goFloat(v.DoubleValue))
	case *ballv1.Literal_StringValue:
		return quoteGo(v.StringValue)
	case *ballv1.Literal_BoolValue:
		return fmt.Sprintf("%t", v.BoolValue)
	case *ballv1.Literal_BytesValue:
		return goBytes(v.BytesValue)
	case *ballv1.Literal_ListValue:
		return c.compileListLiteral(v.ListValue)
	default:
		return "ballrt.Value(nil)"
	}
}

// noInitSentinel is the encoders' shared marker for an uninitialized
// late/nullable local; a reference to it reads as Ball null.
const noInitSentinel = "__no_init__"

func (c *Compiler) compileReference(r *ballv1.Reference) string {
	name := r.GetName()
	if name == "input" {
		// A local binding literally named `input` — a `let input = …` or a
		// declared parameter `input` (e.g. _callBaseFunction(module, function,
		// input), or `final input = _evalExpression(call.input)`) — shadows the
		// raw method-wrapper parameter and is emitted as `ball_input`; resolve
		// through it. Only when no such binding exists does `reference("input")`
		// mean the raw single parameter (invariant #1).
		if c.isLocal("input") {
			return sanitize("input")
		}
		return "input"
	}
	if name == noInitSentinel {
		return "ballrt.Value(nil)"
	}
	// `self` is the encoder's name for both `this` (implicit receiver) and any
	// local literally named `self`. A bound local `self` (a `let self` or a
	// declared `self` parameter) wins; otherwise, inside an instance method it is
	// the receiver, emitted under the unshadowable internal name so a nested
	// `let self` cannot capture it.
	if name == "self" {
		if !c.isLocal("self") && c.inInstanceMethod {
			return c.selfRecvName
		}
		return "self"
	}
	// A bound local shadows everything else.
	if c.isLocal(name) {
		return sanitize(name)
	}
	// A reassigned (volatile) instance field is read live through the receiver.
	if c.inInstanceMethod && c.selfRecvName != "" && c.volatileFields[name] {
		return fmt.Sprintf("ballrt.FieldGet(%s, %q)", c.selfRecvName, name)
	}
	// A oneof-discriminator constant (Expression_Expr.call, …).
	if _, ok := oneofDiscriminators[name]; ok {
		return "ballOneof_" + sanitize(name)
	}
	// A bare Dart core type name used as a static receiver / type argument.
	if builtinTypeNames[name] {
		if _, isUser := c.typeDefsByShort[name]; !isUser {
			return fmt.Sprintf("ballrt.TypeLiteral(%q)", name)
		}
	}
	sn := sanitize(name)
	// A bare reference to a top-level variable/getter is a getter invocation.
	if c.topLevelVars[sn] {
		return fmt.Sprintf("%s(ballrt.Value(nil))", sn)
	}
	// A bare reference to an instance method from inside an instance method body
	// is a bound method tear-off — weave the enclosing receiver into whatever
	// argument the value is later called with.
	if c.inInstanceMethod && c.instanceMethods[sn] {
		self := c.selfRecvName
		if self == "" {
			self = "self"
		}
		return fmt.Sprintf("ballrt.Fn(%q, func(__arg ballrt.Value) ballrt.Value { return %s(ballrt.Arg0WithSelf(__arg, %s)) })", name, sn, self)
	}
	if c.userFuncs[sn] {
		return fmt.Sprintf("ballrt.Fn(%q, %s)", name, sn)
	}
	// Unresolvable: fail loud at runtime rather than emit an undefined identifier
	// (keeps the engine COMPILING; the base corpus never reaches these paths).
	return fmt.Sprintf("ballrt.UnresolvedReference(%q)", name)
}

func (c *Compiler) compileFieldAccess(fa *ballv1.FieldAccess) string {
	obj := c.compileExpr(fa.GetObject())
	return fmt.Sprintf("ballrt.FieldGet(%s, %q)", obj, fa.GetField())
}

func (c *Compiler) compileBlock(block *ballv1.Block) string {
	c.pushScope()
	defer c.popScope()

	var b strings.Builder
	b.WriteString("func() ballrt.Value {\n")
	b.WriteString(indent(c.compileStatements(block.GetStatements()), "\t"))
	if block.GetResult() != nil {
		fmt.Fprintf(&b, "\t\treturn %s\n", c.compileExpr(block.GetResult()))
	} else {
		b.WriteString("\t\treturn ballrt.Value(nil)\n")
	}
	b.WriteString("\t}()")
	return b.String()
}

func (c *Compiler) compileStatements(stmts []*ballv1.Statement) string {
	var b strings.Builder
	for _, s := range stmts {
		switch st := s.GetStmt().(type) {
		case *ballv1.Statement_Let:
			n := sanitize(st.Let.GetName())
			val := c.compileExpr(st.Let.GetValue())
			c.bind(st.Let.GetName())
			fmt.Fprintf(&b, "var %s ballrt.Value = %s\n_ = %s\n", n, val, n)
		case *ballv1.Statement_Expression:
			fmt.Fprintf(&b, "_ = %s\n", c.compileExpr(st.Expression))
		default:
			c.fail("unhandled statement node %T", st)
		}
	}
	return b.String()
}

func (c *Compiler) compileLambda(f *ballv1.FunctionDefinition) string {
	c.pushScope()
	prevInput := c.inputIsParam
	c.inputIsParam = hasInputParam(f)
	prologue := c.paramPrologue(f)
	body := c.compileBody(f)
	c.inputIsParam = prevInput
	c.popScope()

	var b strings.Builder
	b.WriteString("ballrt.Fn(\"\", func(input ballrt.Value) (__ret ballrt.Value) {\n")
	b.WriteString("\t\t_ = input\n")
	if prologue != "" {
		b.WriteString(indent(prologue, "\t"))
	}
	b.WriteString("\t\tdefer ballrt.CatchReturn(&__ret)\n")
	fmt.Fprintf(&b, "\t\t__ret = %s\n", body)
	b.WriteString("\t\treturn\n\t})")
	return b.String()
}

// ── Scope tracking ──────────────────────────────────────────────────────────

func (c *Compiler) pushScope() { c.scopes = append(c.scopes, map[string]bool{}) }
func (c *Compiler) popScope()  { c.scopes = c.scopes[:len(c.scopes)-1] }

func (c *Compiler) bind(name string) {
	if len(c.scopes) > 0 {
		c.scopes[len(c.scopes)-1][sanitize(name)] = true
	}
}

func (c *Compiler) isLocal(name string) bool {
	sn := sanitize(name)
	for i := len(c.scopes) - 1; i >= 0; i-- {
		if c.scopes[i][sn] {
			return true
		}
	}
	return false
}

func (c *Compiler) fail(format string, args ...any) {
	c.errs = append(c.errs, fmt.Sprintf(format, args...))
}

func (c *Compiler) uid() int { c.tempCounter++; return c.tempCounter }

// hasInputParam reports whether f declares a parameter literally named "input".
func hasInputParam(f *ballv1.FunctionDefinition) bool {
	for _, p := range funcParams(f) {
		if p == "input" {
			return true
		}
	}
	return false
}

func dedupe(xs []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, x := range xs {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	return out
}
