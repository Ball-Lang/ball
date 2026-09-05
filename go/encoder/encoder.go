// Package encoder implements the Go → Ball encoder (Phase 3 of epic #426): it
// parses Go source with the standard library's go/parser + go/ast + go/token and
// walks the AST, emitting a Ball `Program` protobuf. It is the inverse of the
// Ball → Go compiler (`go/compiler`).
//
// # Core invariant: no `go_std`
//
// Every Go construct — operators, control flow, `fmt.Println`, indexing —
// expands into a tree of calls against the UNIVERSAL `std` base module (and
// `std_collections` for list/map operations), exactly as the Rust encoder
// expands into `std`/`std_collections` with no `rust_std`, and the Dart encoder
// expands cascade/null-aware-access/spread. A conformant Ball engine that has
// never heard of Go can still run the result. There is deliberately no
// `go_std`.
//
// # The one-input convention (invariant #1)
//
// Every Ball function/lambda has exactly one input. Go's N-parameter functions
// map as follows (matching the reference encoders):
//   - 0 parameters → no input.
//   - 1 parameter  → the parameter keeps its own name as a plain reference; the
//     name is surfaced in `metadata.params` so the compiler's paramPrologue
//     binds `name := input`.
//   - 2+ parameters → the compiler's paramPrologue binds each `name :=
//     ballrt.FieldGet(input, "name")` from `metadata.params`, so the body reads
//     each parameter by a plain reference too, and a call site packs its
//     arguments into one anonymous message keyed by the callee's real parameter
//     names. (Unlike the Rust encoder — whose compiler only aliases a single
//     parameter — the Go compiler aliases every parameter from metadata.params,
//     so the body needs no `field_access(input, name)` rewriting.)
//
// # Fail-loud (issue #55)
//
// An unhandled Go construct records an error via `fail` and Encode returns a
// non-nil error listing every unsupported site, rather than silently dropping
// semantic content or emitting a placeholder the caller might mistake for a
// faithful encoding. The (partial) Program it returns alongside the error must
// not be used.
//
// # Program mode vs. library mode
//
// [Encode] is program mode: it requires a `func main()` entry point, because a
// runnable Ball Program needs one. [EncodeLibrary] is library mode (issue
// #537): the same walk, minus that requirement, for the entry-point-less files
// every real Go library is made of. A library-mode Program carries an empty
// `entry_function` and is deliberately not runnable — never paper over that by
// synthesising a fake entry function. Mirrors the Rust encoder's
// `encode`/`encode_library` and the C# encoder's `Encode`/`EncodeLibrary`.
package encoder

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"sort"
	"strings"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// Encoder holds the mutable state while walking one Go source file.
type Encoder struct {
	// fnParams maps each top-level function's name to its declared parameter
	// names, in order. Populated in a pre-pass so a 2+-argument call site can
	// pack its message with the callee's real parameter names even when the
	// call textually precedes the declaration.
	fnParams map[string][]string

	// errs accumulates fail-loud errors (unsupported constructs). A non-empty
	// errs makes Encode return an error instead of a silently-degraded Program
	// (issue #55 doctrine, mirroring the Go compiler's own error accumulation).
	errs []string
}

// Encode parses Go source and encodes it into a Ball Program. It requires a
// `func main()` entry point (every Ball Program needs one). Returns an error if
// the source fails to parse or contains a construct outside the encoder's
// supported surface (fail-loud) — the accompanying Program is then incomplete
// and must be discarded.
//
// Source with no entry point — a library file — is encoded by [EncodeLibrary]
// instead (`ball encode -lib`).
func Encode(source string) (*ballv1.Program, error) {
	enc, funcs, hasMain, err := encodeFile(source)
	if err != nil {
		return nil, err
	}
	if !hasMain {
		enc.fail("a Ball Program requires a `func main()` entry point")
	}
	return enc.result(funcs, "main")
}

// EncodeLibrary encodes a Go **library** file — the same encoding as [Encode],
// minus the `func main()` requirement (issue #537). Real library files have no
// entry point, so [Encode] rejects every one of them; this is the opt-in that
// accepts them (`ball encode -lib`).
//
// Every top-level function is encoded regardless of reachability (that is
// already true of [Encode]); Go's export rule is name capitalization, so the
// exported surface round-trips in the function names themselves with nothing
// extra to record.
//
// # Deliberately non-runnable
//
// The returned Program carries `entry_module = "main"` — which
// `go/compiler`'s CompileLibrary needs, since that is the module whose
// functions it emits at package scope — but an **empty `entry_function`**.
// `Program.entry_function` is an unconstrained proto3 string
// (`proto/ball/v1/ball.proto`), so an empty one is structurally legal and
// deliberately not runnable: `ball check` reports "missing entry_function" and
// `ball run` has nothing to call. That is the documented boundary, mirroring
// the Rust encoder's `encode_library` and the C# encoder's `EncodeLibrary`
// exactly — never paper over it by synthesising a fake entry function.
func EncodeLibrary(source string) (*ballv1.Program, error) {
	enc, funcs, _, err := encodeFile(source)
	if err != nil {
		return nil, err
	}
	return enc.result(funcs, "")
}

// encodeFile runs the whole Go → Ball walk over source and reports whether the
// file declared a `func main()`. Shared by [Encode] and [EncodeLibrary]: the
// walk is identical, and the entry-point requirement is the caller's business.
// A parse failure is returned as an error (no Encoder to report against);
// unsupported constructs accumulate on the returned Encoder instead.
func encodeFile(source string) (*Encoder, []*ballv1.FunctionDefinition, bool, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "source.go", source, parser.SkipObjectResolution)
	if err != nil {
		return nil, nil, false, fmt.Errorf("parse go source: %w", err)
	}

	enc := &Encoder{fnParams: map[string][]string{}}

	// Pass 1: collect every top-level function's parameter names.
	for _, decl := range file.Decls {
		fd, ok := decl.(*ast.FuncDecl)
		if !ok || fd.Recv != nil {
			continue
		}
		enc.fnParams[fd.Name.Name] = paramNames(fd.Type)
	}

	// Pass 2: encode each declaration.
	var funcs []*ballv1.FunctionDefinition
	hasMain := false
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Recv != nil {
				enc.fail("method with receiver %q is not supported (only free functions are encoded)", d.Name.Name)
				continue
			}
			if d.Name.Name == "main" {
				hasMain = true
			}
			funcs = append(funcs, enc.encodeFunc(d))
		case *ast.GenDecl:
			// `import` declarations carry no runtime semantics to encode.
			// Top-level var/const/type declarations are a documented gap.
			if d.Tok != token.IMPORT {
				enc.fail("top-level %s declaration is not supported (only functions and imports are encoded)", d.Tok)
			}
		default:
			enc.fail("unsupported top-level declaration %T", d)
		}
	}
	return enc, funcs, hasMain, nil
}

// result wraps the encoded functions in a Program with the given entry
// function, surfacing any accumulated fail-loud errors alongside the (then
// incomplete) Program.
func (e *Encoder) result(funcs []*ballv1.FunctionDefinition, entryFunction string) (*ballv1.Program, error) {
	prog := assembleProgram(funcs, entryFunction)
	if len(e.errs) > 0 {
		return prog, fmt.Errorf("go→ball: %d unsupported construct(s):\n  - %s",
			len(e.errs), strings.Join(e.errs, "\n  - "))
	}
	return prog, nil
}

// assembleProgram assembles the final Program: a `main` module holding the
// encoded user functions, preceded by base modules (`std` always, plus any
// others such as `std_collections`) declaring exactly the base functions the
// program calls. Shared by [Encode] and [EncodeLibrary]; entryFunction is the
// *only* difference between the two (`"main"` vs. `""` — see [EncodeLibrary]'s
// "Deliberately non-runnable").
func assembleProgram(funcs []*ballv1.FunctionDefinition, entryFunction string) *ballv1.Program {
	used := map[string]map[string]bool{}
	for _, f := range funcs {
		collectUsed(f.GetBody(), used)
	}

	mainModule := &ballv1.Module{
		Name:      "main",
		Functions: funcs,
		ModuleImports: []*ballv1.ModuleImport{
			{Name: "std"},
		},
	}
	// Import every other base module the program uses (sorted for determinism).
	for _, name := range sortedKeys(used) {
		if name == "std" {
			continue
		}
		mainModule.ModuleImports = append(mainModule.ModuleImports, &ballv1.ModuleImport{Name: name})
	}

	// `std` is always present (even empty), mirroring the reference encoders'
	// unconditional std module; every other base module only when referenced.
	modules := []*ballv1.Module{buildBaseModule("std", used["std"])}
	for _, name := range sortedKeys(used) {
		if name == "std" {
			continue
		}
		modules = append(modules, buildBaseModule(name, used[name]))
	}
	modules = append(modules, mainModule)

	return &ballv1.Program{
		Name:          "encoded_go_program",
		Version:       "1.0.0",
		Modules:       modules,
		EntryModule:   "main",
		EntryFunction: entryFunction,
	}
}

// encodeFunc encodes a top-level function declaration into a Ball
// FunctionDefinition. The body is a Ball block; a Go `return` inside it becomes
// a std.return flow signal (so the block itself needs no tail result).
func (e *Encoder) encodeFunc(fd *ast.FuncDecl) *ballv1.FunctionDefinition {
	params := paramNames(fd.Type)

	body := e.encodeBlockStmt(fd.Body)

	fn := &ballv1.FunctionDefinition{
		Name:       fd.Name.Name,
		OutputType: resultType(fd.Type),
		Body:       body,
		Metadata:   funcMetadata(params),
	}
	if len(params) == 1 {
		fn.InputType = paramType(fd.Type, 0)
	}
	return fn
}

// encodeUserCall packs args as the input to a call targeting a same-file
// function `name` (an empty module — resolved by the compiler through ordinary
// Go name resolution). A 2+-argument call is packed into an anonymous message
// keyed by the callee's real parameter names (from the pre-pass), which the
// compiler's paramPrologue reads back by name.
func (e *Encoder) encodeUserCall(name string, args []ast.Expr) *ballv1.Expression {
	encoded := make([]*ballv1.Expression, len(args))
	for i, a := range args {
		encoded[i] = e.encodeExpr(a)
	}
	var input *ballv1.Expression
	switch len(encoded) {
	case 0:
		input = nil
	case 1:
		input = encoded[0]
	default:
		names := e.fnParams[name]
		if len(names) != len(encoded) {
			// Unknown callee arity (e.g. a variadic or an out-of-file function):
			// fall back to positional arg0/arg1/… field names.
			names = make([]string, len(encoded))
			for i := range names {
				names[i] = fmt.Sprintf("arg%d", i)
			}
		}
		input = argsMessage(pairs(names, encoded)...)
	}
	return call("", name, input)
}

func (e *Encoder) fail(format string, args ...any) {
	e.errs = append(e.errs, fmt.Sprintf(format, args...))
}

// ── std accumulation ─────────────────────────────────────────────────────────

// collectUsed walks an encoded Expression tree, recording every (module,
// function) pair a base call references, so buildProgram declares only the base
// functions actually called (mirrors the Rust encoder's collect_used_functions
// and the Dart encoder's _buildStdModule). An empty module name (a same-file
// user call) is not a base-function reference and is skipped.
func collectUsed(e *ballv1.Expression, used map[string]map[string]bool) {
	if e == nil {
		return
	}
	switch x := e.GetExpr().(type) {
	case *ballv1.Expression_Call:
		if m := x.Call.GetModule(); m != "" {
			if used[m] == nil {
				used[m] = map[string]bool{}
			}
			used[m][x.Call.GetFunction()] = true
		}
		collectUsed(x.Call.GetInput(), used)
	case *ballv1.Expression_Literal:
		if lv, ok := x.Literal.GetValue().(*ballv1.Literal_ListValue); ok {
			for _, el := range lv.ListValue.GetElements() {
				collectUsed(el, used)
			}
		}
	case *ballv1.Expression_FieldAccess:
		collectUsed(x.FieldAccess.GetObject(), used)
	case *ballv1.Expression_MessageCreation:
		for _, fv := range x.MessageCreation.GetFields() {
			collectUsed(fv.GetValue(), used)
		}
	case *ballv1.Expression_Block:
		for _, s := range x.Block.GetStatements() {
			switch st := s.GetStmt().(type) {
			case *ballv1.Statement_Let:
				collectUsed(st.Let.GetValue(), used)
			case *ballv1.Statement_Expression:
				collectUsed(st.Expression, used)
			}
		}
		collectUsed(x.Block.GetResult(), used)
	case *ballv1.Expression_Lambda:
		collectUsed(x.Lambda.GetBody(), used)
	}
}

// buildBaseModule declares exactly fnNames as base functions (is_base = true, no
// body — invariant #3).
func buildBaseModule(name string, fnNames map[string]bool) *ballv1.Module {
	names := make([]string, 0, len(fnNames))
	for n := range fnNames {
		names = append(names, n)
	}
	sort.Strings(names)
	fns := make([]*ballv1.FunctionDefinition, len(names))
	for i, n := range names {
		fns[i] = &ballv1.FunctionDefinition{Name: n, IsBase: true}
	}
	desc := ""
	if name == "std" {
		desc = "Universal standard library base module"
	}
	return &ballv1.Module{Name: name, Functions: fns, Description: desc}
}

func sortedKeys(m map[string]map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// ── Go signature helpers ─────────────────────────────────────────────────────

// paramNames returns a function type's declared parameter names in order,
// flattening grouped parameters (`a, b int` → ["a", "b"]). An unnamed parameter
// (`func(int)`) is given a positional `arg<i>` name so the one-input convention
// still has a stable key.
func paramNames(ft *ast.FuncType) []string {
	if ft.Params == nil {
		return nil
	}
	var names []string
	for _, field := range ft.Params.List {
		if len(field.Names) == 0 {
			names = append(names, fmt.Sprintf("arg%d", len(names)))
			continue
		}
		for _, n := range field.Names {
			names = append(names, n.Name)
		}
	}
	return names
}

// paramType returns the source text of the i-th parameter's type (cosmetic — the
// compiler never parses it back), or "" if out of range.
func paramType(ft *ast.FuncType, i int) string {
	if ft.Params == nil {
		return ""
	}
	idx := 0
	for _, field := range ft.Params.List {
		count := len(field.Names)
		if count == 0 {
			count = 1
		}
		for j := 0; j < count; j++ {
			if idx == i {
				return typeString(field.Type)
			}
			idx++
		}
	}
	return ""
}

// resultType returns a cosmetic string for the function's (first) result type,
// or "void" when it returns nothing.
func resultType(ft *ast.FuncType) string {
	if ft.Results == nil || len(ft.Results.List) == 0 {
		return "void"
	}
	return typeString(ft.Results.List[0].Type)
}

// typeString renders a type AST node as a compact, purely-cosmetic string.
func typeString(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return "*" + typeString(t.X)
	case *ast.ArrayType:
		return "[]" + typeString(t.Elt)
	case *ast.SelectorExpr:
		return typeString(t.X) + "." + t.Sel.Name
	case *ast.MapType:
		return "map[" + typeString(t.Key) + "]" + typeString(t.Value)
	case *ast.InterfaceType:
		return "interface{}"
	default:
		return ""
	}
}
