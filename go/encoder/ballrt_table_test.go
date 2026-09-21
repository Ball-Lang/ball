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
// switches in `go/compiler/base_call.go` that emit the helpers. A closed-set
// test that spells the expected names by hand would just be a second copy of
// the table drifting alongside the first, so this one derives the closed set
// from the source of truth — it parses that file and reads the emissions out of
// the AST.
//
// There are TWO dispatchers and TWO tables, and both are pinned the same way
// (issue #691 for `compileCollectionsCall`/[collectionsHelpers], issue #793 for
// `compileBaseCall`'s `std` switch/[stdHelpers] — the sibling half, ~80 entries,
// which until then had no derivation at all and could drift one helper at a
// time with nothing to catch it).
//
// What the guard pins, for each (dispatcher, table) pair:
//
//   - every `ballrt.<Name>` the switch emits is either inverted by the module's
//     table, into the canonical Ball function name the case selects, with one
//     field per emitted argument in order, or named in that module's documented
//     exclusions with a reason;
//   - each inverted field is the compiler's FIRST alias for that argument
//     (`c.arg(f, "value", "callback")` -> "value"), so a re-encoded program
//     compiles back to the same call and the reference engines read the field
//     they prefer;
//   - a helper emitted from BOTH module dispatchers has no single module and
//     must be excluded, never mapped;
//   - a helper the guard cannot read positionally (an argument that is not a
//     `c.arg(…)`/receiver call, a format verb that is not `%s`, or a bare
//     string literal) must be excluded too: mapping it would assert a shape
//     this test cannot check.

// documentedCollectionExclusions names each `compileCollectionsCall` emission
// deliberately left without an inverse, with the reason. Adding a name here is a
// design decision, not a way to silence the guard.
var documentedCollectionExclusions = map[string]string{
	"SetCreate": "emitted by the std switch too (std.set_create), so its module is ambiguous; " +
		"and the Dart reference engine reads a set's members from an `elements` field neither " +
		"module's input descriptor declares, so any inverse would hand engines an empty set",
}

// documentedStdExclusions is the same list for `compileBaseCall`'s `std` switch
// (issue #793). Each entry states WHY the emission has no inverse in
// [stdHelpers]; the reasons are the ones ballrt.go's doc comment already gives —
// an optional argument the compiler fills with a `ballrt.Value(nil)`
// placeholder, an operand that is not an encodable expression, a base function
// the universal `std` module does not declare, and compiled-code plumbing that
// the encoder reads back structurally instead.
var documentedStdExclusions = map[string]string{
	"SetCreate": "emitted by the std_collections switch too, so its module is ambiguous " +
		"(see documentedCollectionExclusions for the rest of the reason)",

	// Optional trailing argument: the compiler substitutes a literal
	// `ballrt.Value(nil)` when the Ball input omits the field, so the arity of
	// the emitted call cannot tell the encoder whether that argument was
	// written. Inverting it would invent an explicit null.
	"Substring":             "optional `end`: the compiler emits `ballrt.Value(nil)` when the input omits it, so an inverse would invent an explicit null argument",
	"ToStringAsExponential": "optional `digits`: same `ballrt.Value(nil)` placeholder as Substring",
	"Assert":                "optional `message`: same `ballrt.Value(nil)` placeholder as Substring",
	"Return":                "`std.return` takes an optional `value`; the compiler emits `ballrt.Return(ballrt.Value(nil))` for the bare form, so arity cannot distinguish the two",

	// Operands that are not encodable expressions.
	"IsType":    "the second operand is a quoted Go type NAME (c.typeName), not an encodable expression",
	"IsNotType": "the second operand is a quoted Go type NAME (c.typeName), not an encodable expression",
	"AsType":    "the second operand is a quoted Go type NAME (c.typeName), not an encodable expression",
	"Break":     "the operand is a quoted label string (strconv.Quote), not an encodable expression",
	"Continue":  "the operand is a quoted label string (strconv.Quote), not an encodable expression",

	// Base functions the universal std module does not declare, so there is no
	// `std.<fn>` to invert into (ballrt.go's second rule).
	"PrintError": "`std.print_error` is not declared in dart/shared/std.json, so there is no universal base function to invert into",
	"MapAddEntry": "`map_add_entry` is declared by no universal module builder (it exists only as this compiler case), " +
		"so there is no base function to invert into",
	"MapSpread": "`map_spread`/`map_merge_into` are declared by no universal module builder (they exist only as this compiler case), " +
		"so there is no base function to invert into",

	// `std.invoke` IS declared, but its InvokeInput descriptor holds a single
	// `callee` field — neither of the two names the compiler's first-alias rule
	// would produce, and no field at all for the argument.
	"Invoke": "`std.invoke`'s InvokeInput declares only `callee`; the compiler emits `function`/`argument`, " +
		"so a first-alias inverse would hand every engine an input message the descriptor does not declare",

	// The std switch is reached for EVERY module except ball_proto and
	// std_collections, so it also lowers std_convert's six functions. Their
	// inverse is `std_convert.<fn>`, and this file has no std_convert table —
	// mapping them here would emit a call to a base function `std` does not
	// declare.
	"JSONEncode":   "`json_encode` belongs to std_convert, not std, and ballrt.go has no std_convert inverse table",
	"JSONDecode":   "`json_decode` belongs to std_convert, not std, and ballrt.go has no std_convert inverse table",
	"UTF8Encode":   "`utf8_encode` belongs to std_convert, not std, and ballrt.go has no std_convert inverse table",
	"UTF8Decode":   "`utf8_decode` belongs to std_convert, not std, and ballrt.go has no std_convert inverse table",
	"Base64Encode": "`base64_encode` belongs to std_convert, not std, and ballrt.go has no std_convert inverse table",
	"Base64Decode": "`base64_decode` belongs to std_convert, not std, and ballrt.go has no std_convert inverse table",

	// Compiled-code plumbing, recognized structurally by the encoder instead.
	"Truthy": "condition glue, not a base call: Ball coerces implicitly, so `ballrt.Truthy(x)` encodes back to x (see ballrtTruthy)",
	"ListCopy": "the `typed_list`/`list_literal` lowering: its primary path is a list LITERAL (compileListLiteral -> ballrt.NewList), " +
		"and the ballrt.ListCopy fallback wraps an already-compiled expression, so it has no fixed base-call shape",
	"Rethrow": "`std.rethrow` takes no input; the compiler emits a bare `ballrt.Rethrow()`, which carries no argument for the guard to read",
}

// compilerEmission is one `ballrt.<helper>(…)` the compiler performs for one
// Ball base function.
type compilerEmission struct {
	ballFn    string   // the base function the case selects
	canonical string   // the FIRST label of that clause — the function's canonical name
	helper    string   // the ballrt helper emitted for it
	fields    []string // the input field each emitted argument reads, in order
	// readable is false when the guard found the emission but could not read
	// its arguments positionally (a non-`%s` verb, an argument that is not a
	// `c.arg(…)`/receiver call, or a bare string literal). Such an emission
	// must be excluded, never mapped.
	readable bool
}

// inverseSpec is one (compiler dispatcher, encoder table) pair the guard pins.
type inverseSpec struct {
	module     string // the base module the dispatcher lowers
	dispatcher string // the func in base_call.go whose switch emits the helpers
	table      string // the name of the inverse table, for messages
	exclusions string // the name of the exclusions map, for messages
	// otherModules names the dispatchers of the OTHER base modules. A helper
	// emitted there as well has no single module and must be excluded.
	otherModules []string
}

var (
	collectionsSpec = inverseSpec{
		module:       moduleCollections,
		dispatcher:   "compileCollectionsCall",
		table:        "collectionsHelpers",
		exclusions:   "documentedCollectionExclusions",
		otherModules: []string{"compileBaseCall", "compileProtoCall"},
	}
	stdSpec = inverseSpec{
		module:     moduleStd,
		dispatcher: "compileBaseCall",
		table:      "stdHelpers",
		exclusions: "documentedStdExclusions",
		// compileBaseCall delegates parts of the std lowering to
		// compileIf/compileAssign/…, so everything in the file EXCEPT the other
		// two module dispatchers is part of the std emission surface.
		otherModules: []string{"compileCollectionsCall", "compileProtoCall"},
	}
)

func TestCollectionsInverseMatchesCompilerSwitch(t *testing.T) {
	assertInverseMatchesCompiler(t, collectionsSpec, collectionsHelpers, documentedCollectionExclusions)
}

// TestStdInverseMatchesCompilerSwitch is the sibling of the collections guard
// above, against `compileBaseCall`'s `std` dispatch switch (issue #793).
func TestStdInverseMatchesCompilerSwitch(t *testing.T) {
	assertInverseMatchesCompiler(t, stdSpec, stdHelpers, documentedStdExclusions)
}

func assertInverseMatchesCompiler(t *testing.T, spec inverseSpec, table map[string]ballrtHelper, exclusions map[string]string) {
	t.Helper()
	emissions, outside := parseModuleEmissions(t, spec)
	if len(emissions) == 0 {
		t.Fatalf("parsed zero emissions out of %s — the guard would pass vacuously", spec.dispatcher)
	}
	if len(table) == 0 {
		t.Fatalf("%s is empty — the guard would pass vacuously", spec.table)
	}
	t.Logf("checked %d %s emissions parsed out of go/compiler/base_call.go against %d %s entries",
		len(emissions), spec.module, len(table), spec.table)
	for _, problem := range compareInverse(spec, emissions, outside, table, exclusions) {
		t.Error(problem)
	}
}

// TestCollectionsInverseGuardCatchesDrift proves the instrument before trusting
// it: each mutation below is a real way the two files could part, and every one
// must be reported. A guard that only ever runs against a correct table cannot
// tell "in step" from "not looking".
func TestCollectionsInverseGuardCatchesDrift(t *testing.T) {
	runDriftMutations(t, collectionsSpec, collectionsHelpers, documentedCollectionExclusions, []driftCase{
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
	})
}

// TestStdInverseGuardCatchesDrift is the same negative-control battery for the
// std half (issue #793) — including the three shapes the std switch has and the
// collections one does not: a case clause carrying several labels, an emission
// whose arguments the guard cannot read positionally, and a helper the
// dispatcher emits only as a bare string literal.
func TestStdInverseGuardCatchesDrift(t *testing.T) {
	runDriftMutations(t, stdSpec, stdHelpers, documentedStdExclusions, []driftCase{
		{
			name:    "a helper loses its inverse",
			mutate:  func(m map[string]ballrtHelper) { delete(m, "Add") },
			wantSub: "has no inverse",
		},
		{
			name: "an inverse names the wrong base function",
			mutate: func(m map[string]ballrtHelper) {
				h := m["Sub"]
				h.fn = "add"
				m["Sub"] = h
			},
			wantSub: "but the compiler emits it for std.subtract",
		},
		{
			name: "an inverse names a non-canonical alias of a multi-label case",
			mutate: func(m map[string]ballrtHelper) {
				h := m["Lte"]
				h.fn = "less_than_or_equal"
				m["Lte"] = h
			},
			wantSub: "but the compiler emits it for std.lte",
		},
		{
			name: "an inverse names the wrong input field",
			mutate: func(m map[string]ballrtHelper) {
				h := m["StrContains"]
				h.fields = []string{"value", "needle"}
				m["StrContains"] = h
			},
			wantSub: "but the compiler reads",
		},
		{
			name: "an inverse takes the second alias instead of the first",
			mutate: func(m map[string]ballrtHelper) {
				h := m["Print"]
				h.fields = []string{"value"}
				m["Print"] = h
			},
			wantSub: "but the compiler reads",
		},
		{
			name: "an inverse invents a helper the compiler never emits",
			mutate: func(m map[string]ballrtHelper) {
				m["MathHypot"] = ballrtHelper{fn: "math_hypot", fields: binary}
			},
			wantSub: "which compileBaseCall does not emit",
		},
		{
			name:          "an ambiguous helper is mapped instead of excluded",
			dropExclusion: "SetCreate",
			mutate: func(m map[string]ballrtHelper) {
				m["SetCreate"] = ballrtHelper{fn: "set_create", fields: []string{"list"}}
			},
			wantSub: "its base module is ambiguous",
		},
		{
			name:          "a helper whose type-name operand is not an expression is mapped instead of excluded",
			dropExclusion: "IsType",
			mutate: func(m map[string]ballrtHelper) {
				m["IsType"] = ballrtHelper{fn: "is_type", fields: []string{"value", "type"}}
			},
			wantSub: "cannot read positionally",
		},
		{
			name:          "an optional-argument helper is mapped instead of excluded",
			dropExclusion: "Return",
			mutate: func(m map[string]ballrtHelper) {
				m["Return"] = ballrtHelper{fn: "return", fields: unary}
			},
			wantSub: "cannot read positionally",
		},
		{
			name:          "a bare-string emission is mapped instead of excluded",
			dropExclusion: "Rethrow",
			mutate: func(m map[string]ballrtHelper) {
				m["Rethrow"] = ballrtHelper{fn: "rethrow", fields: unary}
			},
			wantSub: "cannot read positionally",
		},
	})
}

type driftCase struct {
	name string
	// dropExclusion removes that name from the documented exclusions for the
	// case, so the mutation reaches the check it is aimed at.
	dropExclusion string
	mutate        func(map[string]ballrtHelper)
	wantSub       string
}

func runDriftMutations(t *testing.T, spec inverseSpec, table map[string]ballrtHelper, exclusions map[string]string, cases []driftCase) {
	t.Helper()
	emissions, outside := parseModuleEmissions(t, spec)

	clone := func() map[string]ballrtHelper {
		out := make(map[string]ballrtHelper, len(table))
		for k, v := range table {
			out[k] = ballrtHelper{mod: spec.module, fn: v.fn, fields: append([]string(nil), v.fields...)}
		}
		return out
	}

	// Each case is judged on the problems the MUTATION adds, not on the problem
	// list as a whole: a battery that accepts any non-empty report would pass
	// vacuously whenever the live table already has a finding of its own.
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kept := map[string]string{}
			for k, v := range exclusions {
				if k != tc.dropExclusion {
					kept[k] = v
				}
			}
			mutated := clone()
			tc.mutate(mutated)
			added := newProblems(
				compareInverse(spec, emissions, outside, clone(), kept),
				compareInverse(spec, emissions, outside, mutated, kept),
			)
			if len(added) == 0 {
				t.Fatalf("the drift guard reported nothing new for: %s", tc.name)
			}
			if !strings.Contains(strings.Join(added, "\n"), tc.wantSub) {
				t.Fatalf("the drift guard newly reported %v, which does not mention %q", added, tc.wantSub)
			}
		})
	}

	// A stale exclusion is drift too, in the other direction.
	t.Run("a documented exclusion outlives its emission", func(t *testing.T) {
		stale := map[string]string{"BallTeleport": "not a real emission"}
		for k, v := range exclusions {
			stale[k] = v
		}
		added := newProblems(
			compareInverse(spec, emissions, outside, clone(), exclusions),
			compareInverse(spec, emissions, outside, clone(), stale),
		)
		if len(added) == 0 || !strings.Contains(strings.Join(added, "\n"), "delete the entry") {
			t.Fatalf("a stale exclusion was not reported: %v", added)
		}
	})
}

// newProblems returns the problems in after that baseline did not already
// report.
func newProblems(baseline, after []string) []string {
	known := make(map[string]bool, len(baseline))
	for _, p := range baseline {
		known[p] = true
	}
	var added []string
	for _, p := range after {
		if !known[p] {
			added = append(added, p)
		}
	}
	return added
}

// helperGroup is every emission of one `ballrt.<Name>` helper out of one
// dispatcher, folded together: a helper can be emitted from several case
// clauses, and a clause can carry several labels.
type helperGroup struct {
	canonical []string // the first label of each clause emitting it
	fields    []string // the argument shape, from the readable emissions
	readable  bool     // at least one emission's arguments were readable
	opaque    bool     // at least one emission's arguments were NOT readable
	conflict  bool     // two readable emissions disagree about the argument shape
}

// compareInverse is the whole comparison, as a pure function of the parsed
// emissions and the table, so both the live checks and their negative controls
// drive exactly the same code for both modules.
func compareInverse(
	spec inverseSpec,
	emissions []compilerEmission,
	outside map[string]bool,
	table map[string]ballrtHelper,
	exclusions map[string]string,
) []string {
	var problems []string
	report := func(format string, args ...any) { problems = append(problems, fmt.Sprintf(format, args...)) }

	groups := map[string]*helperGroup{}
	var order []string
	for _, em := range emissions {
		g, ok := groups[em.helper]
		if !ok {
			g = &helperGroup{}
			groups[em.helper] = g
			order = append(order, em.helper)
		}
		if em.canonical != "" && !contains(g.canonical, em.canonical) {
			g.canonical = append(g.canonical, em.canonical)
		}
		if !em.readable {
			g.opaque = true
			continue
		}
		if g.readable && strings.Join(g.fields, ",") != strings.Join(em.fields, ",") {
			g.conflict = true
		}
		if !g.readable {
			g.fields, g.readable = em.fields, true
		}
	}

	for _, name := range order {
		g := groups[name]
		if reason, excluded := exclusions[name]; excluded {
			if _, mapped := table[name]; mapped {
				report("ballrt.%s is BOTH mapped and documented as excluded (%s) — pick one", name, reason)
			}
			continue
		}
		h, ok := table[name]
		if !ok {
			report("ballrt.%s (the emission of %s.%s) has no inverse in %s "+
				"and is not a documented exclusion", name, spec.module, strings.Join(g.canonical, "/"), spec.table)
			continue
		}
		if outside[name] {
			report("ballrt.%s is emitted by %s AND by another module's dispatcher in base_call.go: "+
				"its base module is ambiguous, so it must be added to %s, not mapped", name, spec.dispatcher, spec.exclusions)
		}
		if !g.readable || g.opaque {
			report("ballrt.%s is emitted with arguments this guard cannot read positionally "+
				"(a format verb that is not %%s, a bare string literal, or an argument that is not a c.arg(…) call), "+
				"so %s cannot assert its shape — add it to %s instead of mapping it", name, spec.table, spec.exclusions)
			continue
		}
		if g.conflict {
			report("ballrt.%s is emitted with two different argument shapes by %s, so it has no single inverse",
				name, spec.dispatcher)
			continue
		}
		if !contains(g.canonical, h.fn) {
			report("ballrt.%s inverts to %s.%s, but the compiler emits it for %s.%s",
				name, spec.module, h.fn, spec.module, strings.Join(g.canonical, "/"))
		}
		if strings.Join(h.fields, ",") != strings.Join(g.fields, ",") {
			report("ballrt.%s inverts to fields %v, but the compiler reads %v (the first alias of each argument)",
				name, h.fields, g.fields)
		}
		if h.mod != "" && h.mod != spec.module {
			report("ballrt.%s resolves to module %q, want %q", name, h.mod, spec.module)
		}
	}

	// The other direction: nothing in the table may invent a helper the compiler
	// never emits, and no exclusion may name a helper that is gone.
	for name := range table {
		if _, seen := groups[name]; !seen {
			report("%s maps ballrt.%s, which %s does not emit", spec.table, name, spec.dispatcher)
		}
	}
	for name, reason := range exclusions {
		if _, seen := groups[name]; !seen {
			report("%s names ballrt.%s (%s), which %s does not emit — delete the entry",
				spec.exclusions, name, reason, spec.dispatcher)
		}
	}
	sort.Strings(problems)
	return problems
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}

// parseModuleEmissions reads go/compiler/base_call.go and returns every emission
// inside spec.dispatcher, plus the set of helper names emitted by the OTHER base
// modules' dispatchers (a helper claimed by two modules has no single inverse).
func parseModuleEmissions(t *testing.T, spec inverseSpec) ([]compilerEmission, map[string]bool) {
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
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == spec.dispatcher {
			target = fd
		}
	}
	if target == nil {
		t.Fatalf("go/compiler/base_call.go declares no %s — this guard has lost its source of truth", spec.dispatcher)
	}

	receivers := receiverClosures(target)
	if len(receivers) == 0 {
		t.Fatalf("%s declares no argument closures; the guard would read every receiver argument as unreadable", spec.dispatcher)
	}
	var emissions []compilerEmission
	ast.Inspect(target, func(n ast.Node) bool {
		clause, ok := n.(*ast.CaseClause)
		if !ok || len(clause.List) == 0 {
			return true
		}
		found := emissionsInClause(clause, receivers)
		if len(found) == 0 {
			return true
		}
		labels := make([]string, 0, len(clause.List))
		for _, caseExpr := range clause.List {
			name, ok := goStringLiteral(caseExpr)
			if !ok {
				t.Fatalf("%s has a non-literal case expression; the guard cannot read the closed set", spec.dispatcher)
			}
			labels = append(labels, name)
		}
		for _, em := range found {
			for _, label := range labels {
				emissions = append(emissions, compilerEmission{
					ballFn:    label,
					canonical: labels[0],
					helper:    em.helper,
					fields:    em.fields,
					readable:  em.readable,
				})
			}
		}
		return true
	})

	others := map[string]bool{}
	for _, name := range spec.otherModules {
		others[name] = true
	}
	outside := map[string]bool{}
	seenOther := map[string]bool{}
	ast.Inspect(file, func(n ast.Node) bool {
		fd, ok := n.(*ast.FuncDecl)
		if !ok || !others[fd.Name.Name] {
			return true
		}
		seenOther[fd.Name.Name] = true
		for _, name := range helperNamesIn(fd) {
			outside[name] = true
		}
		return true
	})
	for _, name := range spec.otherModules {
		if !seenOther[name] {
			t.Fatalf("go/compiler/base_call.go declares no %s — the cross-module ambiguity check has lost its source of truth", name)
		}
	}
	return emissions, outside
}

// receiverClosures maps the argument closures declared at the top of a
// dispatcher (`list`/`set`/`mp` for collections, `L`/`R`/`V` for std) to the
// input field each one reads.
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

// clauseEmission is one `ballrt.<helper>` occurrence inside one case clause.
type clauseEmission struct {
	helper   string
	fields   []string
	readable bool
}

// emissionsInClause finds EVERY `ballrt.X` a case clause emits: the readable
// ones (`fmt.Sprintf("ballrt.X(%s, %s)", <c.arg or receiver>, …)`, from which
// the input field of each argument is recovered), and the opaque ones — any
// other string literal mentioning `ballrt.X(`, which the guard records without
// a shape so the comparison demands a documented exclusion rather than silently
// ignoring the emission.
func emissionsInClause(clause *ast.CaseClause, receivers map[string]string) []clauseEmission {
	var out []clauseEmission
	consumed := map[ast.Node]bool{}

	ast.Inspect(clause, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok || !isSprintf(call.Fun) || len(call.Args) == 0 {
			return true
		}
		lit, isLit := call.Args[0].(*ast.BasicLit)
		if !isLit {
			return true
		}
		format, ok := goStringLiteral(call.Args[0])
		if !ok || !strings.HasPrefix(format, ballrtPackage+".") {
			return true
		}
		name, isCall := helperNameAt(format, len(ballrtPackage)+1)
		if !isCall {
			return true
		}
		consumed[lit] = true
		// Every verb must be a `%s` standing for exactly one emitted argument,
		// or the guard cannot line the arguments up with the format.
		if strings.Count(format, "%") != len(call.Args)-1 || strings.Count(format, "%s") != len(call.Args)-1 {
			out = append(out, clauseEmission{helper: name})
			return true
		}
		args := make([]string, 0, len(call.Args)-1)
		for _, a := range call.Args[1:] {
			field, ok := emittedArgField(a, receivers)
			if !ok {
				out = append(out, clauseEmission{helper: name})
				return true
			}
			args = append(args, field)
		}
		out = append(out, clauseEmission{helper: name, fields: args, readable: true})
		return true
	})

	// Every other literal mentioning a helper: a bare `"ballrt.Rethrow()"`
	// return, or a helper nested inside a larger format
	// (`(ballrt.Truthy(%s) && …)`).
	ast.Inspect(clause, func(n ast.Node) bool {
		lit, ok := n.(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING || consumed[lit] {
			return true
		}
		s, err := strconv.Unquote(lit.Value)
		if err != nil {
			return true
		}
		for _, idx := range helperOffsets(s) {
			name, isCall := helperNameAt(s, idx)
			if !isCall || name == ballrtValueConversion {
				// `ballrt.Value(nil)` is the runtime's dynamic-value conversion
				// (see ballrtValueConversion), not a base-call emission.
				continue
			}
			out = append(out, clauseEmission{helper: name})
		}
		return true
	})
	return out
}

// helperOffsets returns the index just past each "ballrt." in s.
func helperOffsets(s string) []int {
	var out []int
	for i := 0; ; {
		idx := strings.Index(s[i:], ballrtPackage+".")
		if idx < 0 {
			return out
		}
		i += idx + len(ballrtPackage) + 1
		out = append(out, i)
	}
}

// helperNameAt reads the identifier at offset i of s and reports whether it is
// immediately followed by `(` — i.e. whether it is a CALL of a runtime helper
// rather than a mention of a type (`ballrt.Value { … }`).
func helperNameAt(s string, i int) (string, bool) {
	j := i
	for j < len(s) && (s[j] == '_' ||
		(s[j] >= 'a' && s[j] <= 'z') ||
		(s[j] >= 'A' && s[j] <= 'Z') ||
		(s[j] >= '0' && s[j] <= '9')) {
		j++
	}
	if j == i || j >= len(s) || s[j] != '(' {
		return "", false
	}
	return s[i:j], true
}

// emittedArgField resolves one emitted argument to the input field it reads:
// either a receiver closure call (`list()`, `V()`) or `c.arg(f, "first", …)`.
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

// helperNamesIn collects every `ballrt.<Name>(` that appears in a string
// literal inside fd.
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
		for _, idx := range helperOffsets(s) {
			if name, isCall := helperNameAt(s, idx); isCall {
				names = append(names, name)
			}
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
