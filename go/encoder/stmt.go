package encoder

import (
	"go/ast"
	"go/token"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// compoundOps maps a Go compound-assignment operator to the binary `std` base
// function used to desugar it: `x += y` → `x = std.add(x, y)`. The Go compiler's
// std.assign only performs a plain store, so compound assignment MUST be
// desugared here (mirrors while_sum.ball.json, which spells `sum += i` out as an
// add + assign).
var compoundOps = map[token.Token]string{
	token.ADD_ASSIGN: "add",
	token.SUB_ASSIGN: "subtract",
	token.MUL_ASSIGN: "multiply",
	token.QUO_ASSIGN: "divide",
	token.REM_ASSIGN: "modulo",
	token.AND_ASSIGN: "bitwise_and",
	token.OR_ASSIGN:  "bitwise_or",
	token.XOR_ASSIGN: "bitwise_xor",
	token.SHL_ASSIGN: "left_shift",
	token.SHR_ASSIGN: "right_shift",
}

// encodeBlockStmt encodes a Go block into a Ball `block` Expression. Go blocks
// have no tail-expression-is-value rule (a function's value flows through
// `return`), so the encoded block carries statements and no result.
func (e *Encoder) encodeBlockStmt(block *ast.BlockStmt) *ballv1.Expression {
	if block == nil {
		return blockExpr(nil, nil)
	}
	return blockExpr(e.encodeStmts(block.List), nil)
}

// encodeStmts encodes a sequence of Go statements, flattening a construct that
// expands to several Ball statements (e.g. `x, y := 1, 2` → two lets).
func (e *Encoder) encodeStmts(stmts []ast.Stmt) []*ballv1.Statement {
	var out []*ballv1.Statement
	for _, s := range stmts {
		out = append(out, e.encodeStmt(s)...)
	}
	return out
}

func (e *Encoder) encodeStmt(stmt ast.Stmt) []*ballv1.Statement {
	switch s := stmt.(type) {
	case *ast.ExprStmt:
		return []*ballv1.Statement{exprStmt(e.encodeExpr(s.X))}
	case *ast.DeclStmt:
		return e.encodeDeclStmt(s)
	case *ast.AssignStmt:
		return e.encodeAssign(s)
	case *ast.IncDecStmt:
		return []*ballv1.Statement{exprStmt(e.encodeIncDec(s))}
	case *ast.IfStmt:
		return []*ballv1.Statement{exprStmt(e.encodeIf(s))}
	case *ast.ForStmt:
		return []*ballv1.Statement{exprStmt(e.encodeFor(s))}
	case *ast.RangeStmt:
		return []*ballv1.Statement{exprStmt(e.encodeRange(s))}
	case *ast.ReturnStmt:
		return []*ballv1.Statement{exprStmt(e.encodeReturn(s))}
	case *ast.BranchStmt:
		return []*ballv1.Statement{exprStmt(e.encodeBranch(s))}
	case *ast.BlockStmt:
		return []*ballv1.Statement{exprStmt(e.encodeBlockStmt(s))}
	case *ast.EmptyStmt:
		return nil
	default:
		e.fail("unsupported statement %T", stmt)
		return []*ballv1.Statement{exprStmt(nullLit())}
	}
}

// ── Declarations / assignments ───────────────────────────────────────────────

// encodeDeclStmt handles a `var`/`const` declaration inside a block. Each
// name/value pair becomes a Ball let binding; a `var x T` with no initializer
// gets the type's Go zero value.
func (e *Encoder) encodeDeclStmt(s *ast.DeclStmt) []*ballv1.Statement {
	gd, ok := s.Decl.(*ast.GenDecl)
	if !ok {
		e.fail("unsupported declaration statement %T", s.Decl)
		return nil
	}
	if gd.Tok == token.TYPE {
		e.fail("local type declarations are not supported")
		return nil
	}
	var out []*ballv1.Statement
	for _, spec := range gd.Specs {
		vs, ok := spec.(*ast.ValueSpec)
		if !ok {
			e.fail("unsupported declaration spec %T", spec)
			continue
		}
		for i, name := range vs.Names {
			var value *ballv1.Expression
			switch {
			case i < len(vs.Values):
				value = e.encodeExpr(vs.Values[i])
			case len(vs.Values) == 1 && len(vs.Names) > 1:
				e.fail("multi-value assignment from a single call is not supported (one output per function)")
				value = nullLit()
			default:
				value = e.zeroValue(vs.Type)
			}
			out = append(out, letStmt(name.Name, value))
		}
	}
	return out
}

// zeroValue returns the Ball encoding of a Go type's zero value, for a
// no-initializer `var`. Only the common basic types have a meaningful literal
// zero; anything else is Ball null.
func (e *Encoder) zeroValue(t ast.Expr) *ballv1.Expression {
	id, ok := t.(*ast.Ident)
	if !ok {
		return nullLit()
	}
	switch id.Name {
	case "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "byte", "rune":
		return intLit(0)
	case "float32", "float64":
		return doubleLit(0)
	case "string":
		return stringLit("")
	case "bool":
		return boolLit(false)
	default:
		return nullLit()
	}
}

// encodeAssign handles `:=`, `=`, and compound (`+=` …) assignments.
func (e *Encoder) encodeAssign(s *ast.AssignStmt) []*ballv1.Statement {
	// `x := …` short declarations: one Ball let per name. Independent bindings
	// (parallel evaluation) — a single-RHS multi-name form (`a, b := f()`) needs
	// multiple outputs, which the one-output invariant forbids.
	if s.Tok == token.DEFINE {
		if len(s.Lhs) != len(s.Rhs) {
			e.fail("multi-value short declaration from a single expression is not supported")
			return nil
		}
		out := make([]*ballv1.Statement, 0, len(s.Lhs))
		for i, lhs := range s.Lhs {
			name, ok := lhs.(*ast.Ident)
			if !ok {
				e.fail("unsupported short-declaration target %T", lhs)
				continue
			}
			out = append(out, letStmt(name.Name, e.encodeExpr(s.Rhs[i])))
		}
		return out
	}

	// A compound assignment desugars to `target = <op>(target, value)`.
	if op, ok := compoundOps[s.Tok]; ok {
		if len(s.Lhs) != 1 || len(s.Rhs) != 1 {
			e.fail("compound assignment requires a single target and value")
			return nil
		}
		target := e.encodeExpr(s.Lhs[0])
		value := stdBinary(op, e.encodeExpr(s.Lhs[0]), e.encodeExpr(s.Rhs[0]))
		return []*ballv1.Statement{exprStmt(e.assignCall(target, value))}
	}

	// Plain `=` assignment.
	if s.Tok == token.ASSIGN {
		if len(s.Lhs) != 1 || len(s.Rhs) != 1 {
			// Parallel/tuple assignment (`a, b = b, a`) needs temporaries to
			// preserve Go's evaluate-RHS-first semantics — a documented gap.
			e.fail("multi-target assignment is not supported (needs temporaries for correct evaluation order)")
			return nil
		}
		target := e.encodeExpr(s.Lhs[0])
		value := e.encodeExpr(s.Rhs[0])
		return []*ballv1.Statement{exprStmt(e.assignCall(target, value))}
	}

	e.fail("unsupported assignment operator %s", s.Tok)
	return nil
}

// assignCall builds `std.assign({target, value})`. The Go compiler routes a
// reference target to a local store, a field-access target to FieldSet, and an
// index-call target to SetIndex — so the caller just passes the already-encoded
// l-value expression.
func (e *Encoder) assignCall(target, value *ballv1.Expression) *ballv1.Expression {
	return stdCall("assign", argsMessage(kv{"target", target}, kv{"value", value}))
}

// encodeIncDec desugars `x++` / `x--` to `x = std.add/subtract(x, 1)`.
func (e *Encoder) encodeIncDec(s *ast.IncDecStmt) *ballv1.Expression {
	op := "add"
	if s.Tok == token.DEC {
		op = "subtract"
	}
	target := e.encodeExpr(s.X)
	value := stdBinary(op, e.encodeExpr(s.X), intLit(1))
	return e.assignCall(target, value)
}

// ── Control flow ─────────────────────────────────────────────────────────────

// encodeIf encodes an `if` (with optional `else`/`else if` and an optional init
// statement) as `std.if`. Lazy evaluation is structural: the then/else branches
// are Ball sub-expressions the compiler evaluates only when taken (invariant
// #4). An `if init; cond { … }` wraps the std.if in a block introducing `init`.
func (e *Encoder) encodeIf(s *ast.IfStmt) *ballv1.Expression {
	condition := e.encodeExpr(s.Cond)
	then := e.encodeBlockStmt(s.Body)
	var elseBranch *ballv1.Expression
	switch els := s.Else.(type) {
	case nil:
		elseBranch = nil
	case *ast.IfStmt:
		elseBranch = e.encodeIf(els)
	case *ast.BlockStmt:
		elseBranch = e.encodeBlockStmt(els)
	default:
		e.fail("unsupported else branch %T", s.Else)
	}
	ifExpr := ifCall(condition, then, elseBranch)
	if s.Init != nil {
		return blockExpr(append(e.encodeStmt(s.Init), exprStmt(ifExpr)), nil)
	}
	return ifExpr
}

// encodeFor encodes a Go `for` statement. `for init; cond; post {}` →
// `std.for`; `for cond {}` → `std.while`; `for {}` → `std.while(true)`. Native
// control flow stays a base-function call the compiler lowers to a real Go loop
// evaluated lazily (invariant #4).
func (e *Encoder) encodeFor(s *ast.ForStmt) *ballv1.Expression {
	// A bare `for cond {}` / `for {}` with no init and no post is a while loop.
	if s.Init == nil && s.Post == nil {
		condition := boolLit(true)
		if s.Cond != nil {
			condition = e.encodeExpr(s.Cond)
		}
		return stdCall("while", argsMessage(
			kv{"condition", condition},
			kv{"body", e.encodeBlockStmt(s.Body)},
		))
	}

	fields := []kv{}
	if s.Init != nil {
		fields = append(fields, kv{"init", e.forInit(s.Init)})
	}
	if s.Cond != nil {
		fields = append(fields, kv{"condition", e.encodeExpr(s.Cond)})
	}
	if s.Post != nil {
		fields = append(fields, kv{"update", e.forUpdate(s.Post)})
	}
	fields = append(fields, kv{"body", e.encodeBlockStmt(s.Body)})
	return stdCall("for", argsMessage(fields...))
}

// forInit encodes a for-loop init clause. A `:=` init becomes a forInitBlock of
// hoisted let-bindings (the compiler lifts these into the loop's scope); any
// other init statement is encoded as a plain expression evaluated for effect.
func (e *Encoder) forInit(init ast.Stmt) *ballv1.Expression {
	if a, ok := init.(*ast.AssignStmt); ok && a.Tok == token.DEFINE && len(a.Lhs) == len(a.Rhs) {
		bindings := make([]kv, 0, len(a.Lhs))
		for i, lhs := range a.Lhs {
			name, ok := lhs.(*ast.Ident)
			if !ok {
				e.fail("unsupported for-init target %T", lhs)
				continue
			}
			bindings = append(bindings, kv{name.Name, e.encodeExpr(a.Rhs[i])})
		}
		return forInitBlock(bindings)
	}
	// A reused-variable init (`i = 0`) or other statement: encode its single
	// resulting expression. encodeStmt may yield several statements; wrap them.
	return blockExpr(e.encodeStmt(init), nil)
}

// forUpdate encodes a for-loop post statement (`i++`, `i += 2`, …) as a single
// expression the compiler evaluates each iteration.
func (e *Encoder) forUpdate(post ast.Stmt) *ballv1.Expression {
	switch p := post.(type) {
	case *ast.IncDecStmt:
		return e.encodeIncDec(p)
	case *ast.AssignStmt:
		stmts := e.encodeAssign(p)
		if len(stmts) == 1 {
			if es, ok := stmts[0].GetStmt().(*ballv1.Statement_Expression); ok {
				return es.Expression
			}
		}
		return blockExpr(stmts, nil)
	default:
		e.fail("unsupported for-loop post statement %T", post)
		return nullLit()
	}
}

// encodeRange encodes a `for … range …` loop. Iterating a collection for its
// values (`for _, v := range c`) maps directly to `std.for_in`. Any form that
// needs the index (`for i := range c`, `for i, v := range c`) desugars to a
// C-style `std.for` counting from 0 to `length(c)`, reading each element via
// `std.index` — which matches Go's index semantics for slices/arrays/strings.
func (e *Encoder) encodeRange(s *ast.RangeStmt) *ballv1.Expression {
	keyName := identName(s.Key)
	valName := identName(s.Value)
	iterable := e.encodeExpr(s.X)

	// Values-only: `for _, v := range c` (or `for range c`, valName "").
	if keyName == "" {
		variable := valName
		if variable == "" {
			variable = "_"
		}
		return stdCall("for_in", argsMessage(
			kv{"variable", stringLit(variable)},
			kv{"iterable", iterable},
			kv{"body", e.encodeBlockStmt(s.Body)},
		))
	}

	// Index-bearing forms → counting loop over indices.
	idx := keyName
	// The subject is evaluated once into a temp so `length`/`index` don't
	// re-run any side effects in the range expression.
	subject := "__ball_range_subject"
	bodyStmts := []*ballv1.Statement{}
	if valName != "" {
		bodyStmts = append(bodyStmts, letStmt(valName,
			stdCall("index", argsMessage(kv{"target", ref(subject)}, kv{"index", ref(idx)}))))
	}
	bodyStmts = append(bodyStmts, e.encodeBlockInto(s.Body)...)

	loop := stdCall("for", argsMessage(
		kv{"init", forInitBlock([]kv{{idx, intLit(0)}})},
		kv{"condition", stdBinary("less_than", ref(idx), stdUnary("length", ref(subject)))},
		kv{"update", e.assignCall(ref(idx), stdBinary("add", ref(idx), intLit(1)))},
		kv{"body", blockExpr(bodyStmts, nil)},
	))
	return blockExpr([]*ballv1.Statement{letStmt(subject, iterable)}, loop)
}

// encodeBlockInto returns a Go block's statements (not wrapped in a block
// expression) so a desugared loop body can prepend its own bindings.
func (e *Encoder) encodeBlockInto(block *ast.BlockStmt) []*ballv1.Statement {
	if block == nil {
		return nil
	}
	return e.encodeStmts(block.List)
}

func (e *Encoder) encodeReturn(s *ast.ReturnStmt) *ballv1.Expression {
	switch len(s.Results) {
	case 0:
		return stdCall("return", argsMessage(kv{"value", nullLit()}))
	case 1:
		return stdCall("return", argsMessage(kv{"value", e.encodeExpr(s.Results[0])}))
	default:
		e.fail("multi-value return is not supported (one output per function)")
		return stdCall("return", argsMessage(kv{"value", nullLit()}))
	}
}

func (e *Encoder) encodeBranch(s *ast.BranchStmt) *ballv1.Expression {
	switch s.Tok {
	case token.BREAK:
		if s.Label != nil {
			return stdCall("break", argsMessage(kv{"label", stringLit(s.Label.Name)}))
		}
		return stdCall("break", nil)
	case token.CONTINUE:
		if s.Label != nil {
			return stdCall("continue", argsMessage(kv{"label", stringLit(s.Label.Name)}))
		}
		return stdCall("continue", nil)
	default:
		e.fail("unsupported branch statement %s", s.Tok)
		return nullLit()
	}
}

// identName returns the name of an identifier expression, or "" for a nil /
// blank (`_`) / non-identifier node.
func identName(expr ast.Expr) string {
	id, ok := expr.(*ast.Ident)
	if !ok || id.Name == "_" {
		return ""
	}
	return id.Name
}
