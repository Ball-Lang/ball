package encoder

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// The inverse tables in ballrt.go are only correct relative to ONE thing: the
// switch in `go/compiler/base_call.go` that emits the helpers. A closed-set test
// that spells the expected names by hand would just be a second copy of the
// table drifting alongside the first, so this one derives the closed set from
// the source of truth — it parses that file and reads the emissions out of the
// AST.
//
// What it pins, for `compileCollectionsCall` (issue #691):
//
//   - every `ballrt.<Name>` the switch emits is either inverted by
//     [collectionsHelpers], into the SAME Ball function name the case selects,
//     with one field per emitted argument in order, or named in
//     [documentedCollectionExclusions] with a reason;
//   - each inverted field is the compiler's FIRST alias for that argument
//     (`c.arg(f, "value", "callback")` -> "value"), so a re-encoded program
//     compiles back to the same call and the reference engines read the field
//     they prefer;
//   - a helper emitted from BOTH this switch and the `std` one has no single
//     module and must be excluded, never mapped.

// documentedCollectionExclusions names each `compileCollectionsCall` emission
// deliberately left without an inverse, with the reason. Adding a name here is a
// design decision, not a way to silence the guard.
var documentedCollectionExclusions = map[string]string{
	"SetCreate": "emitted by the std switch too (std.set_create), so its module is ambiguous; " +
		"and the Dart reference engine reads a set's members from an `elements` field neither " +
		"module's input descriptor declares, so any inverse would hand engines an empty set",
}

// compilerEmission is one `fmt.Sprintf("ballrt.<helper>(…)", …)` the compiler
// performs for one Ball base function.
type compilerEmission struct {
	ballFn string   // the base function the case selects
	helper string   // the ballrt helper emitted for it
	fields []string // the input field each emitted argument reads, in order
}

func TestCollectionsInverseMatchesCompilerSwitch(t *testing.T) {
	emissions, outside := parseBaseCallEmissions(t)
	if len(emissions) == 0 {
		t.Fatal("parsed zero emissions out of compileCollectionsCall — the guard would pass vacuously")
	}
	t.Logf("checked %d std_collections emissions parsed out of go/compiler/base_call.go", len(emissions))
	for _, problem := range compareCollectionsInverse(emissions, outside, collectionsHelpers, documentedCollectionExclusions) {
		t.Error(problem)
	}
}

// TestCollectionsInverseGuardCatchesDrift proves the instrument before trusting
// it: each mutation below is a real way the two files could part, and every one
// must be reported. A guard that only ever runs against a correct table cannot
// tell "in step" from "not looking".
func TestCollectionsInverseGuardCatchesDrift(t *testing.T) {
	emissions, outside := parseBaseCallEmissions(t)

	clone := func() map[string]ballrtHelper {
		out := make(map[string]ballrtHelper, len(collectionsHelpers))
		for k, v := range collectionsHelpers {
			out[k] = ballrtHelper{mod: moduleCollections, fn: v.fn, fields: append([]string(nil), v.fields...)}
		}
		return out
	}

	cases := []struct {
		name string
		// dropExclusion removes that name from the documented exclusions for the
		// case, so the mutation reaches the check it is aimed at.
		dropExclusion string
		mutate        func(map[string]ballrtHelper)
		wantSub       string
	}{
		{
			name:    "a helper loses its inverse",
			mutate:  func(m map[string]ballrtHelper) { delete(m, "ListGet") },
			wantSub: "has no inverse",
		},
		{
			name: "an inverse names the wrong base function",
			mutate: func(m map[string]ballrtHelper) {
				h := m["MapGet"]
				h.fn = "map_set"
				m["MapGet"] = h
			},
			wantSub: "but the compiler emits it for std_collections.map_get",
		},
		{
			name: "an inverse names the wrong input field",
			mutate: func(m map[string]ballrtHelper) {
				h := m["ListPush"]
				h.fields = []string{"list", "element"}
				m["ListPush"] = h
			},
			wantSub: "but the compiler reads",
		},
		{
			name: "an inverse invents a helper the compiler never emits",
			mutate: func(m map[string]ballrtHelper) {
				m["ListShuffle"] = ballrtHelper{fn: "list_shuffle", fields: []string{"list"}}
			},
			wantSub: "which compileCollectionsCall does not emit",
		},
		{
			name:          "an ambiguous helper is mapped instead of excluded",
			dropExclusion: "SetCreate",
			mutate: func(m map[string]ballrtHelper) {
				m["SetCreate"] = ballrtHelper{fn: "set_create", fields: []string{"list"}}
			},
			wantSub: "its base module is ambiguous",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			table := clone()
			tc.mutate(table)
			exclusions := map[string]string{}
			for k, v := range documentedCollectionExclusions {
				if k != tc.dropExclusion {
					exclusions[k] = v
				}
			}
			problems := compareCollectionsInverse(emissions, outside, table, exclusions)
			if len(problems) == 0 {
				t.Fatalf("the drift guard reported nothing for: %s", tc.name)
			}
			if !strings.Contains(strings.Join(problems, "\n"), tc.wantSub) {
				t.Fatalf("the drift guard reported %v, which does not mention %q", problems, tc.wantSub)
			}
		})
	}

	// A stale exclusion is drift too, in the other direction.
	problems := compareCollectionsInverse(emissions, outside, clone(),
		map[string]string{"ListTeleport": "not a real emission"})
	if len(problems) == 0 || !strings.Contains(strings.Join(problems, "\n"), "delete the entry") {
		t.Fatalf("a stale exclusion was not reported: %v", problems)
	}
}

// compareCollectionsInverse is the whole comparison, as a pure function of the
// parsed emissions and the table, so both the live check and its negative
// controls drive exactly the same code.
func compareCollectionsInverse(
	emissions []compilerEmission,
	outside map[string]bool,
	table map[string]ballrtHelper,
	exclusions map[string]string,
) []string {
	var problems []string
	report := func(format string, args ...any) { problems = append(problems, fmt.Sprintf(format, args...)) }

	seen := map[string]bool{}
	for _, em := range emissions {
		seen[em.helper] = true
		if reason, excluded := exclusions[em.helper]; excluded {
			if _, mapped := table[em.helper]; mapped {
				report("ballrt.%s is BOTH mapped and documented as excluded (%s) — pick one", em.helper, reason)
			}
			continue
		}
		h, ok := table[em.helper]
		if !ok {
			report("ballrt.%s (the emission of std_collections.%s) has no inverse in collectionsHelpers "+
				"and is not a documented exclusion", em.helper, em.ballFn)
			continue
		}
		if outside[em.helper] {
			report("ballrt.%s is emitted by compileCollectionsCall AND elsewhere in base_call.go: "+
				"its base module is ambiguous, so it must be added to documentedCollectionExclusions, not mapped", em.helper)
		}
		if h.fn != em.ballFn {
			report("ballrt.%s inverts to std_collections.%s, but the compiler emits it for std_collections.%s",
				em.helper, h.fn, em.ballFn)
		}
		if strings.Join(h.fields, ",") != strings.Join(em.fields, ",") {
			report("ballrt.%s inverts to fields %v, but the compiler reads %v (the first alias of each argument)",
				em.helper, h.fields, em.fields)
		}
		if h.mod != "" && h.mod != moduleCollections {
			report("ballrt.%s resolves to module %q, want %q", em.helper, h.mod, moduleCollections)
		}
	}

	// The other direction: nothing in the table may invent a helper the compiler
	// never emits, and no exclusion may name a helper that is gone.
	for name := range table {
		if !seen[name] {
			report("collectionsHelpers maps ballrt.%s, which compileCollectionsCall does not emit", name)
		}
	}
	for name, reason := range exclusions {
		if !seen[name] {
			report("documentedCollectionExclusions names ballrt.%s (%s), which compileCollectionsCall does not emit — delete the entry", name, reason)
		}
	}
	sort.Strings(problems)
	return problems
}

// parseBaseCallEmissions reads go/compiler/base_call.go and returns every
// emission inside compileCollectionsCall, plus the set of helper names emitted
// ANYWHERE ELSE in that file.
func parseBaseCallEmissions(t *testing.T) ([]compilerEmission, map[string]bool) {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("..", "compiler", "base_call.go"))
	if err != nil {
		t.Fatalf("resolve the compiler's base_call.go: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("go/compiler/base_call.go is the source of truth for this guard and was not found: %v", err)
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
	if err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}

	var target *ast.FuncDecl
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == "compileCollectionsCall" {
			target = fd
		}
	}
	if target == nil {
		t.Fatal("go/compiler/base_call.go declares no compileCollectionsCall — this guard has lost its source of truth")
	}

	receivers := receiverClosures(target)
	var emissions []compilerEmission
	ast.Inspect(target, func(n ast.Node) bool {
		clause, ok := n.(*ast.CaseClause)
		if !ok || len(clause.List) == 0 {
			return true
		}
		helper, fields, found := emissionInClause(clause, receivers)
		if !found {
			return true
		}
		for _, caseExpr := range clause.List {
			name, ok := goStringLiteral(caseExpr)
			if !ok {
				t.Fatalf("compileCollectionsCall has a non-literal case expression; the guard cannot read the closed set")
			}
			emissions = append(emissions, compilerEmission{ballFn: name, helper: helper, fields: fields})
		}
		return true
	})

	outside := map[string]bool{}
	ast.Inspect(file, func(n ast.Node) bool {
		fd, ok := n.(*ast.FuncDecl)
		if !ok || fd == target {
			return true
		}
		for _, name := range helperNamesIn(fd) {
			outside[name] = true
		}
		return true
	})
	return emissions, outside
}

// receiverClosures maps the `list`/`set`/`mp` closures declared at the top of
// compileCollectionsCall to the field each one reads.
func receiverClosures(fd *ast.FuncDecl) map[string]string {
	out := map[string]string{}
	for _, stmt := range fd.Body.List {
		assign, ok := stmt.(*ast.AssignStmt)
		if !ok || len(assign.Lhs) != 1 || len(assign.Rhs) != 1 {
			continue
		}
		name, ok := assign.Lhs[0].(*ast.Ident)
		if !ok {
			continue
		}
		lit, ok := assign.Rhs[0].(*ast.FuncLit)
		if !ok || lit.Body == nil || len(lit.Body.List) != 1 {
			continue
		}
		ret, ok := lit.Body.List[0].(*ast.ReturnStmt)
		if !ok || len(ret.Results) != 1 {
			continue
		}
		if field, ok := argField(ret.Results[0]); ok {
			out[name.Name] = field
		}
	}
	return out
}

// emissionInClause finds the single `fmt.Sprintf("ballrt.X(…)", args…)` (or the
// bare `"ballrt.X(…)"` string) a case clause returns, and the input field each
// emitted argument reads.
func emissionInClause(clause *ast.CaseClause, receivers map[string]string) (string, []string, bool) {
	var helper string
	var fields []string
	found := false
	ast.Inspect(clause, func(n ast.Node) bool {
		if found {
			return false
		}
		call, ok := n.(*ast.CallExpr)
		if !ok || !isSprintf(call.Fun) || len(call.Args) == 0 {
			return true
		}
		format, ok := goStringLiteral(call.Args[0])
		if !ok || !strings.HasPrefix(format, "ballrt.") {
			return true
		}
		name := strings.TrimSuffix(strings.SplitN(strings.TrimPrefix(format, "ballrt."), "(", 2)[0], "(")
		if name == "" || strings.Count(format, "%s") != len(call.Args)-1 {
			return true
		}
		args := make([]string, 0, len(call.Args)-1)
		for _, a := range call.Args[1:] {
			field, ok := emittedArgField(a, receivers)
			if !ok {
				return true
			}
			args = append(args, field)
		}
		helper, fields, found = name, args, true
		return false
	})
	return helper, fields, found
}

// emittedArgField resolves one emitted argument to the input field it reads:
// either a receiver closure call (`list()`) or `c.arg(f, "first", …)`.
func emittedArgField(expr ast.Expr, receivers map[string]string) (string, bool) {
	if call, ok := expr.(*ast.CallExpr); ok {
		if id, isIdent := call.Fun.(*ast.Ident); isIdent && len(call.Args) == 0 {
			field, known := receivers[id.Name]
			return field, known
		}
	}
	return argField(expr)
}

// argField reads the FIRST alias out of a `c.arg(f, "a", "b", …)` call.
func argField(expr ast.Expr) (string, bool) {
	call, ok := expr.(*ast.CallExpr)
	if !ok || len(call.Args) < 2 {
		return "", false
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != "arg" {
		return "", false
	}
	return goStringLiteral(call.Args[1])
}

// helperNamesIn collects every `ballrt.<Name>(` that appears in a format string
// inside fd.
func helperNamesIn(fd *ast.FuncDecl) []string {
	var names []string
	ast.Inspect(fd, func(n ast.Node) bool {
		lit, ok := n.(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			return true
		}
		s, err := strconv.Unquote(lit.Value)
		if err != nil {
			return true
		}
		for _, part := range strings.Split(s, "ballrt.")[1:] {
			idx := strings.IndexByte(part, '(')
			if idx <= 0 {
				continue
			}
			names = append(names, part[:idx])
		}
		return true
	})
	sort.Strings(names)
	return names
}

func isSprintf(fn ast.Expr) bool {
	sel, ok := fn.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != "Sprintf" {
		return false
	}
	pkg, ok := sel.X.(*ast.Ident)
	return ok && pkg.Name == "fmt"
}

func goStringLiteral(expr ast.Expr) (string, bool) {
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

// TestHelperTablesAreDisjoint proves the merge that gives each helper its module
// rejects a name claimed by two modules rather than letting map order decide.
func TestHelperTablesAreDisjoint(t *testing.T) {
	for name := range stdHelpers {
		if _, dup := collectionsHelpers[name]; dup {
			t.Errorf("ballrt.%s is in both stdHelpers and collectionsHelpers", name)
		}
	}
	if len(ballrtHelpers) != len(stdHelpers)+len(collectionsHelpers) {
		t.Fatalf("merged table holds %d helpers, want %d + %d",
			len(ballrtHelpers), len(stdHelpers), len(collectionsHelpers))
	}
	for name, h := range ballrtHelpers {
		if h.mod != moduleStd && h.mod != moduleCollections {
			t.Errorf("ballrt.%s resolves to module %q, which is neither base module", name, h.mod)
		}
		if len(h.fields) == 0 {
			t.Errorf("ballrt.%s maps to %s.%s with no input fields", name, h.mod, h.fn)
		}
	}
}

// TestMergeHelperTablesRejectsAmbiguity is the negative control for the merge:
// with a real collision present it must panic, so the disjointness above is
// enforced rather than merely observed.
func TestMergeHelperTablesRejectsAmbiguity(t *testing.T) {
	const clash = "ListGet"
	stdHelpers[clash] = ballrtHelper{fn: "index", fields: []string{"target", "index"}}
	defer delete(stdHelpers, clash)

	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("merging tables that both map ballrt.ListGet did not panic")
		}
		if msg := fmt.Sprint(r); !strings.Contains(msg, clash) {
			t.Fatalf("panic message does not name the clashing helper: %s", msg)
		}
	}()
	mergeHelperTables()
}
