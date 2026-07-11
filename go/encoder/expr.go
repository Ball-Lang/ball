package encoder

import (
	"go/ast"
	"go/token"
	"strconv"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
)

// encodeExpr dispatches a Go expression to its Ball encoding. Every arm routes
// through the universal `std`/`std_collections` base modules — there is no
// `go_std`. An unhandled expression kind is a fail-loud error (issue #55),
// returning a null placeholder that is only ever reached when Encode is already
// going to return an error.
func (e *Encoder) encodeExpr(expr ast.Expr) *ballv1.Expression {
	switch x := expr.(type) {
	case *ast.BasicLit:
		return e.encodeBasicLit(x)
	case *ast.Ident:
		return e.encodeIdent(x)
	case *ast.ParenExpr:
		return e.encodeExpr(x.X)
	case *ast.StarExpr:
		// Pointer dereference `*p` is transparent in Ball's pointer-free value
		// model (mirrors the C++/Rust encoders inlining dereference at encode
		// time). A `*T` type node never reaches here (types go through
		// typeString), only a value dereference.
		return e.encodeExpr(x.X)
	case *ast.BinaryExpr:
		return e.encodeBinary(x)
	case *ast.UnaryExpr:
		return e.encodeUnary(x)
	case *ast.CallExpr:
		return e.encodeCall(x)
	case *ast.IndexExpr:
		return e.encodeIndex(x)
	case *ast.SelectorExpr:
		return fieldAccess(e.encodeExpr(x.X), x.Sel.Name)
	case *ast.CompositeLit:
		return e.encodeCompositeLit(x)
	case *ast.FuncLit:
		return e.encodeFuncLit(x)
	default:
		e.fail("unsupported expression %T", expr)
		return nullLit()
	}
}

// ── Literals ─────────────────────────────────────────────────────────────────

func (e *Encoder) encodeBasicLit(lit *ast.BasicLit) *ballv1.Expression {
	switch lit.Kind {
	case token.INT:
		// ParseInt base 0 honors Go's 0x/0o/0b prefixes and `_` digit groups.
		v, err := strconv.ParseInt(lit.Value, 0, 64)
		if err != nil {
			e.fail("invalid integer literal %q: %v", lit.Value, err)
			return nullLit()
		}
		return intLit(v)
	case token.FLOAT:
		v, err := strconv.ParseFloat(lit.Value, 64)
		if err != nil {
			e.fail("invalid float literal %q: %v", lit.Value, err)
			return nullLit()
		}
		return doubleLit(v)
	case token.STRING:
		s, err := strconv.Unquote(lit.Value)
		if err != nil {
			e.fail("invalid string literal %q: %v", lit.Value, err)
			return nullLit()
		}
		return stringLit(s)
	case token.CHAR:
		// A Go rune literal is an untyped integer (its code point) — `'A'` is
		// 65, exactly what `fmt.Println('A')` prints — so encode it as an int.
		s, err := strconv.Unquote(lit.Value)
		if err != nil || len(s) == 0 {
			e.fail("invalid rune literal %q", lit.Value)
			return nullLit()
		}
		return intLit(int64([]rune(s)[0]))
	default:
		e.fail("unsupported literal kind %s (%q)", lit.Kind, lit.Value)
		return nullLit()
	}
}

// encodeIdent maps a bare identifier: the predeclared constants true/false/nil,
// otherwise a plain reference the compiler resolves (a local, a parameter alias,
// or a top-level function tear-off).
func (e *Encoder) encodeIdent(id *ast.Ident) *ballv1.Expression {
	switch id.Name {
	case "true":
		return boolLit(true)
	case "false":
		return boolLit(false)
	case "nil":
		return nullLit()
	default:
		return ref(id.Name)
	}
}

// ── Operators ────────────────────────────────────────────────────────────────

// binaryOps maps a Go binary operator to its universal `std` base function.
// Division is special-cased (int-truncating vs always-double) in encodeBinary.
var binaryOps = map[token.Token]string{
	token.ADD:  "add",
	token.SUB:  "subtract",
	token.MUL:  "multiply",
	token.REM:  "modulo",
	token.EQL:  "equals",
	token.NEQ:  "not_equals",
	token.LSS:  "less_than",
	token.GTR:  "greater_than",
	token.LEQ:  "lte",
	token.GEQ:  "gte",
	token.LAND: "and",
	token.LOR:  "or",
	token.AND:  "bitwise_and",
	token.OR:   "bitwise_or",
	token.XOR:  "bitwise_xor",
	token.SHL:  "left_shift",
	token.SHR:  "right_shift",
}

func (e *Encoder) encodeBinary(b *ast.BinaryExpr) *ballv1.Expression {
	left := e.encodeExpr(b.X)
	right := e.encodeExpr(b.Y)
	if b.Op == token.QUO {
		// No static types are available (a syntactic encoder), so pick
		// int-truncating vs always-double division by a best-effort heuristic:
		// a float literal on either side ⇒ `divide_double`, else `divide`
		// (Go's `/` truncates for two ints — the common case). Mirrors the Rust
		// encoder's own `looks_like_float` gate.
		if looksLikeFloat(b.X) || looksLikeFloat(b.Y) {
			return stdBinary("divide_double", left, right)
		}
		return stdBinary("divide", left, right)
	}
	fn, ok := binaryOps[b.Op]
	if !ok {
		e.fail("unsupported binary operator %s", b.Op)
		return nullLit()
	}
	return stdBinary(fn, left, right)
}

func (e *Encoder) encodeUnary(u *ast.UnaryExpr) *ballv1.Expression {
	switch u.Op {
	case token.SUB:
		return stdUnary("negate", e.encodeExpr(u.X))
	case token.NOT:
		return stdUnary("not", e.encodeExpr(u.X))
	case token.ADD:
		// Unary `+` is an identity.
		return e.encodeExpr(u.X)
	case token.AND:
		// Address-of `&x` is transparent (Ball values are already reference
		// types where it matters); `&T{...}` composite → same message value.
		return e.encodeExpr(u.X)
	default:
		e.fail("unsupported unary operator %s", u.Op)
		return nullLit()
	}
}

// ── Calls ────────────────────────────────────────────────────────────────────

// builtinConversions maps a Go built-in numeric/string conversion or function
// used in call position to its `std` equivalent.
var builtinConversions = map[string]string{
	"string":  "to_string",
	"int":     "to_int",
	"int64":   "to_int",
	"int32":   "to_int",
	"float64": "to_double",
	"float32": "to_double",
	"len":     "length",
}

func (e *Encoder) encodeCall(c *ast.CallExpr) *ballv1.Expression {
	switch fn := c.Fun.(type) {
	case *ast.SelectorExpr:
		// A package-qualified call such as `fmt.Println(x)`.
		if pkg, ok := fn.X.(*ast.Ident); ok && pkg.Name == "fmt" {
			return e.encodeFmtCall(fn.Sel.Name, c.Args)
		}
		e.fail("unsupported qualified call %s.%s", typeString(fn.X), fn.Sel.Name)
		return nullLit()
	case *ast.Ident:
		name := fn.Name
		// A built-in conversion / len — a single-argument `std` unary call.
		if std, ok := builtinConversions[name]; ok {
			if len(c.Args) != 1 {
				e.fail("%s expects exactly one argument", name)
				return nullLit()
			}
			return stdUnary(std, e.encodeExpr(c.Args[0]))
		}
		// Otherwise a same-file user function call.
		return e.encodeUserCall(name, c.Args)
	default:
		e.fail("unsupported call target %T", c.Fun)
		return nullLit()
	}
}

// encodeFmtCall maps the fmt package's print verbs. Only single-argument
// Println/Print are supported (the runtime's print always appends a newline,
// matching Println exactly; Print is accepted for convenience but shares that
// newline behavior). Sprintf/Printf and multi-argument forms are a documented
// gap.
func (e *Encoder) encodeFmtCall(verb string, args []ast.Expr) *ballv1.Expression {
	switch verb {
	case "Println", "Print":
		if len(args) != 1 {
			e.fail("fmt.%s with %d arguments is not supported (only a single argument)", verb, len(args))
			return nullLit()
		}
		return stdCall("print", argsMessage(kv{"message", e.encodeExpr(args[0])}))
	default:
		e.fail("unsupported fmt.%s (only single-argument Println/Print are supported)", verb)
		return nullLit()
	}
}

// ── Indexing / composite literals / closures ─────────────────────────────────

func (e *Encoder) encodeIndex(x *ast.IndexExpr) *ballv1.Expression {
	target := e.encodeExpr(x.X)
	index := e.encodeExpr(x.Index)
	return stdCall("index", argsMessage(kv{"target", target}, kv{"index", index}))
}

// encodeCompositeLit encodes a slice/array literal (`[]int{1,2,3}`) as a Ball
// list literal, and a struct literal (`T{...}` / `T{a: 1}`) as a typed
// message_creation. Map literals are a documented gap.
func (e *Encoder) encodeCompositeLit(c *ast.CompositeLit) *ballv1.Expression {
	switch t := c.Type.(type) {
	case *ast.ArrayType:
		elems := make([]*ballv1.Expression, 0, len(c.Elts))
		for _, el := range c.Elts {
			if kve, ok := el.(*ast.KeyValueExpr); ok {
				// Indexed array element `[i]: v` — the value carries the
				// semantics; the sparse index is a documented simplification.
				elems = append(elems, e.encodeExpr(kve.Value))
				continue
			}
			elems = append(elems, e.encodeExpr(el))
		}
		return listLit(elems)
	case *ast.Ident:
		return e.encodeStructLit(t.Name, c.Elts)
	case *ast.SelectorExpr:
		return e.encodeStructLit(t.Sel.Name, c.Elts)
	case *ast.MapType:
		e.fail("map literals are not supported yet")
		return nullLit()
	default:
		e.fail("unsupported composite literal type %T", c.Type)
		return nullLit()
	}
}

func (e *Encoder) encodeStructLit(typeName string, elts []ast.Expr) *ballv1.Expression {
	fields := make([]kv, 0, len(elts))
	for _, el := range elts {
		kve, ok := el.(*ast.KeyValueExpr)
		if !ok {
			e.fail("positional struct literals are not supported (use keyed fields, e.g. Point{x: 1})")
			return nullLit()
		}
		key, ok := kve.Key.(*ast.Ident)
		if !ok {
			e.fail("unsupported struct-literal field key %T", kve.Key)
			return nullLit()
		}
		fields = append(fields, kv{key.Name, e.encodeExpr(kve.Value)})
	}
	return namedMessage(typeName, fields)
}

// encodeFuncLit encodes a Go function literal (closure) as a Ball lambda. It
// follows the same one-input convention as a named function.
func (e *Encoder) encodeFuncLit(fl *ast.FuncLit) *ballv1.Expression {
	params := paramNames(fl.Type)
	body := e.encodeBlockStmt(fl.Body)
	fn := &ballv1.FunctionDefinition{
		Body:     body,
		Metadata: funcMetadata(params),
	}
	return lambdaExpr(fn)
}

// looksLikeFloat reports whether a Go expression syntactically looks like a
// floating-point value (a float literal, or a paren/sign wrapper around one).
// Used only to disambiguate `/`'s truncating vs double semantics.
func looksLikeFloat(expr ast.Expr) bool {
	switch x := expr.(type) {
	case *ast.BasicLit:
		return x.Kind == token.FLOAT
	case *ast.ParenExpr:
		return looksLikeFloat(x.X)
	case *ast.UnaryExpr:
		return looksLikeFloat(x.X)
	default:
		return false
	}
}
