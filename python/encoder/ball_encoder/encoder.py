"""Python → Ball encoder (Ball epic #445, Phase 3).

Parses Python source with the standard library's :mod:`ast` (no third-party
parser) and walks the tree, emitting a Ball ``Program`` as the **raw proto3-JSON
dict view** the Ball → Python compiler (``python/compiler``) consumes directly.
It is the inverse of that compiler and the Python sibling of ``go/encoder`` and
``rust/encoder``.

Core invariants (see root ``CLAUDE.md``):

* **No ``python_std``.** Every Python construct — operators, control flow,
  ``print``, indexing — expands into a tree of calls against the UNIVERSAL
  ``std`` (and ``std_collections``) base module, exactly as the Go/Rust encoders
  expand into ``std`` with no ``go_std``/``rust_std``. A conformant Ball engine
  that has never heard of Python still runs the result.

* **One input, one output (invariant #1).** A 0-parameter function takes no
  input; a 1-parameter function keeps its parameter name; a 2+-parameter call
  packs its arguments into one anonymous message keyed by the callee's real
  parameter names, which the compiler's parameter prologue reads back by name.

* **Fail loud (issue #55).** An unsupported Python construct records an error and
  :func:`encode` raises :class:`EncodeError` listing every unsupported site,
  rather than silently dropping semantic content or emitting a placeholder the
  caller might mistake for a faithful encoding.

# Python scoping vs. Ball let/assign

Python has no ``let``/``=`` distinction — a name is a function-scoped local the
first assignment declares and later assignments mutate. Ball distinguishes a
``LetBinding`` (declaration, block-scoped) from ``std.assign`` (mutation). To map
faithfully, each function is scanned for its assigned names, which are **hoisted**
as ``let <name> = null`` at the top of the function body; every actual assignment
(including the first) then compiles to ``std.assign``, so it mutates the single
function-scoped binding exactly as Python does. Parameters are already bound by
the compiler's prologue and are excluded from the hoist set.
"""

from __future__ import annotations

import ast

from . import builders as b

# Operators handled directly as universal-`std` base functions.
_BINOP_TABLE = {
    ast.Add: "add",
    ast.Sub: "subtract",
    ast.Mult: "multiply",
    ast.Mod: "modulo",
    ast.LShift: "left_shift",
    ast.RShift: "right_shift",
    ast.BitOr: "bitwise_or",
    ast.BitAnd: "bitwise_and",
    ast.BitXor: "bitwise_xor",
}

# Compound-assignment operators (`+=` …) desugar to `x = <op>(x, y)` because the
# compiler's std.assign is a plain store.
_AUGOP_TABLE = {
    ast.Add: "add",
    ast.Sub: "subtract",
    ast.Mult: "multiply",
    ast.Div: "divide_double",
    ast.FloorDiv: "divide",
    ast.Mod: "modulo",
    ast.Pow: None,  # power handled specially (2-arg base/exponent)
    ast.LShift: "left_shift",
    ast.RShift: "right_shift",
    ast.BitOr: "bitwise_or",
    ast.BitAnd: "bitwise_and",
    ast.BitXor: "bitwise_xor",
}

_CMP_TABLE = {
    ast.Lt: "less_than",
    ast.Gt: "greater_than",
    ast.LtE: "lte",
    ast.GtE: "gte",
    ast.Eq: "equals",
    ast.NotEq: "not_equals",
    # `is`/`is not` are almost always the `x is None` idiom; Ball's equals treats
    # null identity correctly, so map them to value (in)equality.
    ast.Is: "equals",
    ast.IsNot: "not_equals",
}

# Built-in single-argument conversions / functions → a `std` unary call.
_BUILTIN_UNARY = {
    "str": "to_string",
    "int": "to_int",
    "float": "to_double",
    "len": "length",
    "abs": "math_abs",
}


class EncodeError(Exception):
    """A Python construct the encoder does not support (fail-loud, issue #55)."""


def encode(source: str) -> dict:
    """Parse Python source and encode it into a Ball ``Program`` dict.

    Raises :class:`EncodeError` if the source fails to parse or contains a
    construct outside the encoder's supported surface. The Program is returned
    only on success — a fail-loud run raises and yields nothing usable.
    """
    return _Encoder().encode(source)


class _Encoder:
    def __init__(self) -> None:
        self.errors: list[str] = []
        # Every def's parameter names (top-level and nested), so a 2+-argument
        # call site can pack its message with the callee's real parameter names.
        self.fn_params: dict[str, list[str]] = {}
        # Names bound as parameters of the function currently being encoded — a
        # reassignment to one of these must not be hoisted (the prologue owns it).
        self._params: set[str] = set()

    # ── Entry point ──────────────────────────────────────────────────────────

    def encode(self, source: str) -> dict:
        try:
            module = ast.parse(source)
        except SyntaxError as ex:
            raise EncodeError(f"parse python source: {ex}") from ex

        # Pass 1: record every def's parameter names (nested defs included, so a
        # call that textually precedes the def still packs correctly).
        for node in ast.walk(module):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self.fn_params[node.name] = self._param_names(node.args)

        # Pass 2: partition top-level declarations.
        top_defs: list[ast.FunctionDef] = []
        loose: list[ast.stmt] = []
        guard_body: list[ast.stmt] = []
        for node in module.body:
            if isinstance(node, ast.FunctionDef):
                top_defs.append(node)
            elif isinstance(node, ast.AsyncFunctionDef):
                self.fail("async functions are not supported")
            elif isinstance(node, (ast.Import, ast.ImportFrom)):
                continue  # imports carry no runtime semantics to encode
            elif isinstance(node, ast.ClassDef):
                self.fail(f"top-level class {node.name!r} is not supported (classes are deferred)")
            elif self._is_main_guard(node):
                guard_body = node.body
            elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
                continue  # a module docstring / bare literal is a no-op
            else:
                loose.append(node)

        functions: list[dict] = [self.encode_func(d) for d in top_defs]

        has_main_def = any(d.name == "main" for d in top_defs)
        if has_main_def:
            if loose:
                self.fail("top-level statements alongside a main() function are ambiguous "
                          "(put all top-level code inside main(), or drop main())")
            entry_present = True
        else:
            # Synthesise `main` from the loose top-level statements, unwrapping an
            # `if __name__ == "__main__":` guard into it.
            main_body = loose + guard_body
            functions.append(self.encode_synthetic_main(main_body))
            entry_present = True

        if not entry_present:
            self.fail("a Ball Program requires a `main` entry point")

        program = self.build_program(functions)
        if self.errors:
            raise EncodeError(
                f"python->ball: {len(self.errors)} unsupported construct(s):\n  - "
                + "\n  - ".join(dict.fromkeys(self.errors))
            )
        return program

    # ── Program assembly ─────────────────────────────────────────────────────

    def build_program(self, functions: list[dict]) -> dict:
        """Assemble the Program: a ``main`` module of user functions, preceded by
        base modules declaring exactly the base functions the program calls."""
        used: dict[str, set[str]] = {}
        for f in functions:
            _collect_used(f.get("body"), used)

        module_imports = [{"name": "std"}]
        for name in sorted(used):
            if name != "std":
                module_imports.append({"name": name})

        main_module = {
            "name": "main",
            "functions": functions,
            "moduleImports": module_imports,
        }

        modules = [_base_module("std", used.get("std", set()))]
        for name in sorted(used):
            if name != "std":
                modules.append(_base_module(name, used[name]))
        modules.append(main_module)

        return {
            "name": "encoded_python_program",
            "version": "1.0.0",
            "modules": modules,
            "entryModule": "main",
            "entryFunction": "main",
        }

    # ── Functions ────────────────────────────────────────────────────────────

    def encode_func(self, fd: ast.FunctionDef) -> dict:
        params = self._param_names(fd.args)
        body = self.encode_function_body(fd.body, params)
        fn: dict = {
            "name": fd.name,
            "outputType": _return_type(fd),
            "body": body,
            "metadata": b.func_metadata(params),
        }
        if len(params) == 1:
            fn["inputType"] = "dynamic"
        return fn

    def encode_synthetic_main(self, stmts: list[ast.stmt]) -> dict:
        body = self.encode_function_body(stmts, [])
        return {
            "name": "main",
            "outputType": "void",
            "body": body,
            "metadata": b.func_metadata([]),
        }

    def encode_function_body(self, stmts: list[ast.stmt], params: list[str]) -> dict:
        """Encode a function body block: hoisted local declarations followed by the
        encoded statements. Returns flow through ``std.return`` signals, so the
        block itself has no tail result."""
        saved_params = self._params
        self._params = set(params)
        try:
            hoist = [n for n in _collect_locals(stmts) if n not in self._params]
            out: list[dict] = [b.let_stmt(n, b.null_lit()) for n in hoist]
            for s in stmts:
                out.extend(self.encode_stmt(s))
        finally:
            self._params = saved_params
        return b.block_expr(out, None)

    def _param_names(self, args: ast.arguments) -> list[str]:
        names = [a.arg for a in args.posonlyargs] + [a.arg for a in args.args]
        if args.vararg or args.kwarg or args.kwonlyargs:
            self.fail("*args/**kwargs/keyword-only parameters are not supported")
        return names

    # ── Statements ───────────────────────────────────────────────────────────

    def encode_stmt(self, stmt: ast.stmt) -> list[dict]:
        if isinstance(stmt, ast.Expr):
            if isinstance(stmt.value, ast.Constant):
                return []  # bare literal / docstring — no-op
            return [b.expr_stmt(self.encode_expr(stmt.value))]
        if isinstance(stmt, ast.FunctionDef):
            return self.encode_nested_def(stmt)
        if isinstance(stmt, ast.Return):
            return [b.expr_stmt(self.encode_return(stmt))]
        if isinstance(stmt, ast.Assign):
            return self.encode_assign(stmt)
        if isinstance(stmt, ast.AugAssign):
            return [b.expr_stmt(self.encode_aug_assign(stmt))]
        if isinstance(stmt, ast.AnnAssign):
            return self.encode_ann_assign(stmt)
        if isinstance(stmt, ast.If):
            return [b.expr_stmt(self.encode_if(stmt))]
        if isinstance(stmt, ast.While):
            return [b.expr_stmt(self.encode_while(stmt))]
        if isinstance(stmt, ast.For):
            return [b.expr_stmt(self.encode_for(stmt))]
        if isinstance(stmt, (ast.Break, ast.Continue)):
            return [b.expr_stmt(self.encode_branch(stmt))]
        if isinstance(stmt, ast.Pass):
            return []
        self.fail(f"unsupported statement {type(stmt).__name__}")
        return []

    def encode_nested_def(self, fd: ast.FunctionDef) -> list[dict]:
        """A nested ``def`` becomes an assignment of a lambda to a (hoisted) local,
        so a following reference/call resolves to it through the compiler's
        first-class-function path. Closures capture enclosing locals by read
        (Python's own capture); mutating a captured outer variable needs
        ``nonlocal``, which is a documented gap."""
        params = self._param_names(fd.args)
        lam = {
            "outputType": _return_type(fd),
            "body": self.encode_lambda_body(fd.body, params),
            "metadata": b.func_metadata(params),
        }
        return [b.expr_stmt(self.assign_to(b.ref(fd.name), b.lambda_expr(lam)))]

    def encode_lambda_body(self, stmts: list[ast.stmt], params: list[str]) -> dict:
        saved_params = self._params
        self._params = set(params)
        try:
            hoist = [n for n in _collect_locals(stmts) if n not in self._params]
            out: list[dict] = [b.let_stmt(n, b.null_lit()) for n in hoist]
            for s in stmts:
                out.extend(self.encode_stmt(s))
        finally:
            self._params = saved_params
        return b.block_expr(out, None)

    def encode_assign(self, s: ast.Assign) -> list[dict]:
        # `a = b = v` assigns v to each target (Python evaluates v once; the
        # targets here are simple l-values with no side effects, so re-emitting
        # the encoded value per target preserves semantics).
        value = self.encode_expr(s.value)
        out: list[dict] = []
        for target in s.targets:
            if isinstance(target, (ast.Tuple, ast.List)):
                self.fail("tuple/list unpacking assignment is not supported "
                          "(one output per function)")
                continue
            out.append(b.expr_stmt(self.assign_to(self.encode_target(target), value)))
        return out

    def encode_aug_assign(self, s: ast.AugAssign) -> dict:
        op = type(s.op)
        target_expr = self.encode_target(s.target)
        target_read = self.encode_target(s.target)
        rhs = self.encode_expr(s.value)
        if op is ast.Pow:
            value = b.std_call("math_pow", b.args_message(("base", target_read), ("exponent", rhs)))
        else:
            fn = _AUGOP_TABLE.get(op)
            if fn is None:
                self.fail(f"unsupported augmented-assignment operator {op.__name__}")
                return b.null_lit()
            value = b.std_binary(fn, target_read, rhs)
        return self.assign_to(target_expr, value)

    def encode_ann_assign(self, s: ast.AnnAssign) -> list[dict]:
        # `x: int = v` is a plain assignment (the annotation is cosmetic). A bare
        # `x: int` with no value is a declaration only — the hoist already covers
        # it, so nothing to emit.
        if s.value is None:
            return []
        if not isinstance(s.target, (ast.Name, ast.Attribute, ast.Subscript)):
            self.fail("unsupported annotated-assignment target")
            return []
        value = self.encode_expr(s.value)
        return [b.expr_stmt(self.assign_to(self.encode_target(s.target), value))]

    def assign_to(self, target: dict, value: dict) -> dict:
        """Build ``std.assign({target, value})``. The compiler routes a reference
        target to a local store, a fieldAccess target to a field set, and an
        index-call target to an index set — so the caller passes the already-
        encoded l-value."""
        return b.std_call("assign", b.args_message(("target", target), ("value", value)))

    def encode_target(self, target: ast.expr) -> dict:
        """Encode an assignment l-value. A Subscript target becomes the same
        ``std.index`` call the compiler recognises as an index l-value."""
        if isinstance(target, ast.Name):
            return b.ref(target.id)
        if isinstance(target, ast.Attribute):
            return b.field_access(self.encode_expr(target.value), target.attr)
        if isinstance(target, ast.Subscript):
            return self.encode_subscript(target)
        self.fail(f"unsupported assignment target {type(target).__name__}")
        return b.null_lit()

    def encode_return(self, s: ast.Return) -> dict:
        value = self.encode_expr(s.value) if s.value is not None else b.null_lit()
        return b.std_call("return", b.args_message(("value", value)))

    def encode_branch(self, s: ast.stmt) -> dict:
        # Python has no loop labels, so break/continue are always unlabelled.
        return b.std_call("break" if isinstance(s, ast.Break) else "continue", None)

    # ── Control flow ─────────────────────────────────────────────────────────

    def encode_if(self, s: ast.If) -> dict:
        condition = self.encode_expr(s.test)
        then = self.encode_block(s.body)
        else_branch: dict | None = None
        if s.orelse:
            # `elif` is a single nested If in orelse — keep it as a nested std.if
            # so each branch stays lazily evaluated.
            if len(s.orelse) == 1 and isinstance(s.orelse[0], ast.If):
                else_branch = self.encode_if(s.orelse[0])
            else:
                else_branch = self.encode_block(s.orelse)
        return b.if_call(condition, then, else_branch)

    def encode_while(self, s: ast.While) -> dict:
        if s.orelse:
            self.fail("while/else is not supported")
        return b.std_call("while", b.args_message(
            ("condition", self.encode_expr(s.test)),
            ("body", self.encode_block(s.body)),
        ))

    def encode_for(self, s: ast.For) -> dict:
        if s.orelse:
            self.fail("for/else is not supported")
        if not isinstance(s.target, ast.Name):
            self.fail("only a single loop variable is supported "
                      "(tuple targets / unpacking are not)")
            return b.null_lit()
        var = s.target.id

        # `for x in range(...)` → a C-style std.for counting `x` (the compiler
        # lowers this to a real native loop, evaluated lazily — invariant #4).
        rng = self._range_args(s.iter)
        if rng is not None:
            return self.encode_range_for(var, rng, s.body)

        # `for x in <iterable>` → std.for_in over the collection's values.
        return b.std_call("for_in", b.args_message(
            ("variable", b.string_lit(var)),
            ("iterable", self.encode_expr(s.iter)),
            ("body", self.encode_block(s.body)),
        ))

    def encode_range_for(self, var: str, rng: tuple, body: list[ast.stmt]) -> dict:
        start, stop, step = rng
        start_e = self.encode_expr(start) if start is not None else b.int_lit(0)
        stop_e = self.encode_expr(stop)
        step_e = self.encode_expr(step) if step is not None else b.int_lit(1)

        # Direction is taken from a literal step's sign; a non-literal step can't
        # pick a comparison direction syntactically, so require a constant.
        descending = False
        if step is not None:
            if not (isinstance(step, ast.Constant) and isinstance(step.value, int)):
                self.fail("range() with a non-constant step is not supported")
            elif step.value < 0:
                descending = True
            elif step.value == 0:
                self.fail("range() step must not be zero")

        cmp_fn = "greater_than" if descending else "less_than"
        init = b.block_expr([b.expr_stmt(self.assign_to(b.ref(var), start_e))])
        condition = b.std_binary(cmp_fn, b.ref(var), stop_e)
        update = self.assign_to(b.ref(var), b.std_binary("add", b.ref(var), step_e))
        return b.std_call("for", b.args_message(
            ("init", init),
            ("condition", condition),
            ("update", update),
            ("body", self.encode_block(body)),
        ))

    def encode_block(self, stmts: list[ast.stmt]) -> dict:
        out: list[dict] = []
        for s in stmts:
            out.extend(self.encode_stmt(s))
        return b.block_expr(out, None)

    def _range_args(self, node: ast.expr):
        """If ``node`` is a ``range(...)`` call, return ``(start, stop, step)`` AST
        nodes (``start``/``step`` may be ``None``); otherwise ``None``."""
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == "range"):
            return None
        if node.keywords:
            self.fail("range() with keyword arguments is not supported")
            return None
        args = node.args
        if len(args) == 1:
            return (None, args[0], None)
        if len(args) == 2:
            return (args[0], args[1], None)
        if len(args) == 3:
            return (args[0], args[1], args[2])
        self.fail("range() expects 1-3 arguments")
        return None

    # ── Expressions ──────────────────────────────────────────────────────────

    def encode_expr(self, node: ast.expr) -> dict:
        if isinstance(node, ast.Constant):
            return self.encode_constant(node)
        if isinstance(node, ast.Name):
            return b.ref(node.id)
        if isinstance(node, ast.BinOp):
            return self.encode_binop(node)
        if isinstance(node, ast.UnaryOp):
            return self.encode_unaryop(node)
        if isinstance(node, ast.BoolOp):
            return self.encode_boolop(node)
        if isinstance(node, ast.Compare):
            return self.encode_compare(node)
        if isinstance(node, ast.Call):
            return self.encode_call(node)
        if isinstance(node, ast.Subscript):
            return self.encode_subscript(node)
        if isinstance(node, ast.Attribute):
            return b.field_access(self.encode_expr(node.value), node.attr)
        if isinstance(node, ast.List):
            return self.encode_list(node)
        if isinstance(node, ast.IfExp):
            return b.if_call(self.encode_expr(node.test),
                             self.encode_expr(node.body),
                             self.encode_expr(node.orelse))
        if isinstance(node, ast.JoinedStr):
            return self.encode_fstring(node)
        if isinstance(node, ast.Lambda):
            return self.encode_lambda(node)
        self.fail(f"unsupported expression {type(node).__name__}")
        return b.null_lit()

    def encode_constant(self, node: ast.Constant) -> dict:
        v = node.value
        if isinstance(v, bool):  # bool before int — bool is an int subclass
            return b.bool_lit(v)
        if isinstance(v, int):
            return b.int_lit(v)
        if isinstance(v, float):
            return b.double_lit(v)
        if isinstance(v, str):
            return b.string_lit(v)
        if v is None:
            return b.null_lit()
        self.fail(f"unsupported literal of type {type(v).__name__}")
        return b.null_lit()

    def encode_binop(self, node: ast.BinOp) -> dict:
        op = type(node.op)
        left = self.encode_expr(node.left)
        right = self.encode_expr(node.right)
        if op is ast.Div:
            return b.std_binary("divide_double", left, right)  # Python `/` is always float
        if op is ast.FloorDiv:
            return b.std_binary("divide", left, right)  # truncating; matches `//` for non-negatives
        if op is ast.Pow:
            return b.std_call("math_pow", b.args_message(("base", left), ("exponent", right)))
        fn = _BINOP_TABLE.get(op)
        if fn is None:
            self.fail(f"unsupported binary operator {op.__name__}")
            return b.null_lit()
        return b.std_binary(fn, left, right)

    def encode_unaryop(self, node: ast.UnaryOp) -> dict:
        op = type(node.op)
        if op is ast.USub:
            return b.std_unary("negate", self.encode_expr(node.operand))
        if op is ast.Not:
            return b.std_unary("not", self.encode_expr(node.operand))
        if op is ast.UAdd:
            return self.encode_expr(node.operand)  # unary `+` is identity
        if op is ast.Invert:
            return b.std_unary("bitwise_not", self.encode_expr(node.operand))
        self.fail(f"unsupported unary operator {op.__name__}")
        return b.null_lit()

    def encode_boolop(self, node: ast.BoolOp) -> dict:
        # `a and b and c` folds left into nested short-circuiting std.and calls;
        # the compiler lowers std.and/or to native Python and/or (invariant #4).
        fn = "and" if isinstance(node.op, ast.And) else "or"
        acc = self.encode_expr(node.values[0])
        for val in node.values[1:]:
            acc = b.std_binary(fn, acc, self.encode_expr(val))
        return acc

    def encode_compare(self, node: ast.Compare) -> dict:
        # A chained comparison `a < b < c` is `(a < b) and (b < c)` with the
        # middle operands re-encoded. Python evaluates a shared operand once; the
        # operands in practice are side-effect-free, so re-encoding is equivalent
        # (a documented simplification for side-effecting middles).
        operands = [node.left] + list(node.comparators)
        parts: list[dict] = []
        for i, op in enumerate(node.ops):
            fn = _CMP_TABLE.get(type(op))
            if fn is None:
                self.fail(f"unsupported comparison operator {type(op).__name__} "
                          "(in/not-in are not supported)")
                return b.null_lit()
            parts.append(b.std_binary(fn, self.encode_expr(operands[i]),
                                      self.encode_expr(operands[i + 1])))
        acc = parts[0]
        for p in parts[1:]:
            acc = b.std_binary("and", acc, p)
        return acc

    def encode_call(self, node: ast.Call) -> dict:
        if node.keywords:
            self.fail("keyword arguments are not supported")
        func = node.func
        if isinstance(func, ast.Attribute):
            # A method / qualified call (`obj.method(...)`, `fmt.Println(...)`).
            # Only single-argument prints and free functions are in scope; other
            # method calls need receiver types the syntactic encoder lacks.
            self.fail(f"method call .{func.attr}(...) is not supported")
            return b.null_lit()
        if not isinstance(func, ast.Name):
            self.fail(f"unsupported call target {type(func).__name__}")
            return b.null_lit()
        name = func.id
        if name == "print":
            return self.encode_print(node.args)
        if name == "range":
            self.fail("range() is only supported as a for-loop iterable")
            return b.null_lit()
        if name in _BUILTIN_UNARY:
            if len(node.args) != 1:
                self.fail(f"{name}() expects exactly one argument")
                return b.null_lit()
            return b.std_unary(_BUILTIN_UNARY[name], self.encode_expr(node.args[0]))
        return self.encode_user_call(name, node.args)

    def encode_print(self, args: list[ast.expr]) -> dict:
        # print() → newline only; the runtime's print always appends "\n".
        if len(args) == 0:
            return b.std_call("print", b.args_message(("message", b.string_lit(""))))
        message = self.encode_expr(args[0])
        # print(a, b, …) joins arguments with a single space (Python's default
        # sep); concat stringifies each operand.
        for extra in args[1:]:
            message = b.std_call("concat", b.args_message(
                ("left", b.std_call("concat", b.args_message(
                    ("left", message), ("right", b.string_lit(" "))))),
                ("right", self.encode_expr(extra))))
        return b.std_call("print", b.args_message(("message", message)))

    def encode_user_call(self, name: str, args: list[ast.expr]) -> dict:
        encoded = [self.encode_expr(a) for a in args]
        if len(encoded) == 0:
            input_expr = None
        elif len(encoded) == 1:
            input_expr = encoded[0]
        else:
            names = self.fn_params.get(name)
            if names is None or len(names) != len(encoded):
                # Unknown callee arity (a first-class function value, or an
                # out-of-scope name): fall back to positional arg0/arg1/… keys,
                # which the compiler's prologue reads by the same positional name.
                names = [f"arg{i}" for i in range(len(encoded))]
            input_expr = b.args_message(*zip(names, encoded))
        return b.call("", name, input_expr)

    def encode_subscript(self, node: ast.Subscript) -> dict:
        if isinstance(node.slice, ast.Slice):
            self.fail("slice subscription is not supported")
            return b.null_lit()
        return b.std_call("index", b.args_message(
            ("target", self.encode_expr(node.value)),
            ("index", self.encode_expr(node.slice)),
        ))

    def encode_list(self, node: ast.List) -> dict:
        elements: list[dict] = []
        for el in node.elts:
            if isinstance(el, ast.Starred):
                self.fail("starred elements in a list literal are not supported")
                continue
            elements.append(self.encode_expr(el))
        return b.list_lit(elements)

    def encode_fstring(self, node: ast.JoinedStr) -> dict:
        # An f-string folds into a std.concat chain (concat stringifies both
        # operands). Plain `{expr}` interpolations are supported; a conversion
        # (`!r`/`!a`) or a format-spec (`:.2f`) is a documented gap.
        segments: list[dict] = []
        all_const = True
        for part in node.values:
            if isinstance(part, ast.Constant) and isinstance(part.value, str):
                segments.append(b.string_lit(part.value))
            elif isinstance(part, ast.FormattedValue):
                all_const = False
                if part.conversion not in (-1, ord("s")) or part.format_spec is not None:
                    self.fail("f-string conversions/format-specs are not supported "
                              "(only plain {expr})")
                segments.append(self.encode_expr(part.value))
            else:
                self.fail("unsupported f-string segment")
        if not segments:
            return b.string_lit("")
        if all_const:
            return b.string_lit("".join(s["literal"]["stringValue"] for s in segments))
        # Seed with "" so the very first concat stringifies even a lone {expr}.
        acc = b.string_lit("")
        for seg in segments:
            acc = b.std_call("concat", b.args_message(("left", acc), ("right", seg)))
        return acc

    def encode_lambda(self, node: ast.Lambda) -> dict:
        params = self._param_names(node.args)
        saved_params = self._params
        self._params = set(params)
        try:
            # A lambda body is a single expression; returning it is the value.
            body = b.std_call("return", b.args_message(("value", self.encode_expr(node.body))))
        finally:
            self._params = saved_params
        lam = {"body": b.block_expr([b.expr_stmt(body)], None), "metadata": b.func_metadata(params)}
        return b.lambda_expr(lam)

    # ── Helpers ──────────────────────────────────────────────────────────────

    def _is_main_guard(self, node: ast.stmt) -> bool:
        """True for an ``if __name__ == "__main__":`` guard (encoded by unwrapping
        its body into the synthesised main)."""
        if not isinstance(node, ast.If):
            return False
        test = node.test
        if not (isinstance(test, ast.Compare) and len(test.ops) == 1
                and isinstance(test.ops[0], ast.Eq)):
            return False
        left, right = test.left, test.comparators[0]
        return (isinstance(left, ast.Name) and left.id == "__name__"
                and isinstance(right, ast.Constant) and right.value == "__main__")

    def fail(self, message: str) -> None:
        self.errors.append(message)


# ── Local-variable collection (for hoisting) ─────────────────────────────────


def _collect_locals(stmts: list[ast.stmt]) -> list[str]:
    """Ordered unique names assigned anywhere in ``stmts`` — the function's local
    variables to hoist. Does not descend into nested function/lambda scopes (those
    own their own locals)."""
    seen: dict[str, None] = {}

    def add(name: str) -> None:
        if name not in seen:
            seen[name] = None

    def targets(t: ast.expr) -> None:
        if isinstance(t, ast.Name):
            add(t.id)
        elif isinstance(t, (ast.Tuple, ast.List)):
            for el in t.elts:
                targets(el)
        # Attribute/Subscript targets mutate an existing object, not a new local.

    def walk(node: ast.stmt) -> None:
        if isinstance(node, ast.Assign):
            for tgt in node.targets:
                targets(tgt)
        elif isinstance(node, (ast.AugAssign, ast.AnnAssign)):
            if isinstance(node.target, ast.Name):
                add(node.target.id)
        elif isinstance(node, ast.For):
            targets(node.target)
            for s in node.body:
                walk(s)
            for s in node.orelse:
                walk(s)
        elif isinstance(node, (ast.While, ast.If)):
            for s in node.body:
                walk(s)
            for s in node.orelse:
                walk(s)
        elif isinstance(node, ast.FunctionDef):
            # A nested def binds its own name in the enclosing function scope.
            add(node.name)

    for s in stmts:
        walk(s)
    return list(seen.keys())


# ── Base-module accumulation ─────────────────────────────────────────────────


def _collect_used(expr, used: dict[str, set[str]]) -> None:
    """Walk an encoded Expression dict, recording every ``(module, function)`` a
    base call references, so :meth:`_Encoder.build_program` declares only the base
    functions actually called. An empty module name (a user call) is skipped."""
    if not isinstance(expr, dict):
        return
    if "call" in expr:
        c = expr["call"]
        mod = c.get("module", "")
        if mod:
            used.setdefault(mod, set()).add(c.get("function", ""))
        _collect_used(c.get("input"), used)
    elif "literal" in expr:
        lv = expr["literal"].get("listValue")
        if lv:
            for el in lv.get("elements", []):
                _collect_used(el, used)
    elif "fieldAccess" in expr:
        _collect_used(expr["fieldAccess"].get("object"), used)
    elif "messageCreation" in expr:
        for fv in expr["messageCreation"].get("fields", []):
            _collect_used(fv.get("value"), used)
    elif "block" in expr:
        blk = expr["block"]
        for stmt in blk.get("statements", []):
            if "let" in stmt:
                _collect_used(stmt["let"].get("value"), used)
            elif "expression" in stmt:
                _collect_used(stmt["expression"], used)
        if blk.get("result") is not None:
            _collect_used(blk["result"], used)
    elif "lambda" in expr:
        _collect_used(expr["lambda"].get("body"), used)


def _base_module(name: str, fn_names: set[str]) -> dict:
    """Declare exactly ``fn_names`` as base functions (``isBase: true``, no body —
    invariant #3)."""
    functions = [{"name": n, "isBase": True} for n in sorted(fn_names)]
    module: dict = {"name": name, "functions": functions}
    if name == "std":
        module["description"] = "Universal standard library base module"
    return module


def _return_type(fd: ast.FunctionDef) -> str:
    """A cosmetic string for the declared return annotation, or ``void``."""
    if fd.returns is None:
        return "void"
    try:
        return ast.unparse(fd.returns)
    except Exception:
        return "dynamic"
