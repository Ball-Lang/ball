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

from . import ballrt_calls as rt
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
            out.extend(self.encode_stmts(stmts))
        finally:
            self._params = saved_params
        return b.block_expr(out, None)

    def _param_names(self, args: ast.arguments) -> list[str]:
        names = [a.arg for a in args.posonlyargs] + [a.arg for a in args.args]
        if args.vararg or args.kwarg or args.kwonlyargs:
            self.fail("*args/**kwargs/keyword-only parameters are not supported")
        return names

    # ── Statements ───────────────────────────────────────────────────────────

    def encode_stmts(self, stmts: list[ast.stmt]) -> list[dict]:
        """Encode a statement LIST.

        Position matters for exactly one shape: the compiler's loop-body
        break/continue trap encodes to its own body inlined, which is only sound
        when nothing follows it — trailing statements are a C-style ``for``'s
        update, and only ``std.for`` runs an update on ``continue``. The
        recognised ``while True:`` lowering handles that case itself
        (:meth:`_compiled_loop`); anything else fails loud rather than silently
        producing a loop that never advances.
        """
        out: list[dict] = []
        last = len(stmts) - 1
        for i, s in enumerate(stmts):
            if isinstance(s, ast.Try) and self._is_loop_trap(s):
                if i != last:
                    self.fail(
                        "the compiled loop-body break/continue trap is followed by "
                        "more statements — those are a C-style `for`'s update, which "
                        "only `std.for` runs on `continue`, so the whole `while True:` "
                        "loop has to be read back at once, not the trap alone")
                out.extend(self.encode_stmts(s.body))
                continue
            out.extend(self.encode_stmt(s))
        return out

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
        if isinstance(stmt, ast.Try):
            return self.encode_try(stmt)
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
            out.extend(self.encode_stmts(stmts))
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
        lowered = self._compiled_loop(s)
        if lowered is not None:
            return lowered
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

        # The loop direction is the sign of the step, which must be known at
        # encode time to pick the counting comparison (`<` ascending, `>`
        # descending). A negative literal step parses as `UnaryOp(USub,
        # Constant)`, never a bare `Constant`, so `_const_int` unwraps the unary
        # sign — otherwise `range(5, 0, -1)` would (wrongly) look non-constant.
        descending = False
        if step is None:
            step_e = b.int_lit(1)
        else:
            step_val = _const_int(step)
            if step_val is None:
                self.fail("range() with a non-constant step is not supported "
                          "(the step's sign must be known at encode time)")
                step_e = self.encode_expr(step)
            elif step_val == 0:
                self.fail("range() step must not be zero")
                step_e = b.int_lit(0)
            else:
                descending = step_val < 0
                step_e = b.int_lit(step_val)

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
        return b.block_expr(self.encode_stmts(stmts), None)

    # ── The compiler's own statement lowerings (issue #690) ──────────────────
    # `python/compiler` does not emit Ball's loop and `try` nodes as anything
    # nameable: it emits SHAPES — a `while True:` carrying a break/continue
    # trap, a `try:` whose handler names one of `ballrt`'s flow exceptions. Each
    # recogniser below is the exact inverse of one compiler method, and anything
    # that is *almost* one of these shapes fails loud rather than being guessed
    # at (issue #55 doctrine): a wrong guess here does not raise, it produces a
    # program that silently never terminates.

    def _rt_attr(self, node: ast.expr | None) -> str | None:
        """The ``X`` of a ``ballrt.X`` attribute reference, else None."""
        if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                and node.value.id == rt.RUNTIME_MODULE):
            return node.attr
        return None

    def _is_loop_trap(self, s: ast.Try) -> bool:
        """``compiler._loop_body`` / ``compiler.run_forin``::

            try:
                <body>
            except ballrt.BallBreak as _brk:
                if _brk.label: raise
                break
            except ballrt.BallContinue as _cnt:
                if _cnt.label: raise

        Pure plumbing: Ball's loop nodes carry ``std.break``/``std.continue``
        natively, so the inverse is ``<body>`` with the trap removed.
        """
        if s.orelse or s.finalbody or len(s.handlers) != 2:
            return False
        brk, cont = s.handlers
        if (self._rt_attr(brk.type), self._rt_attr(cont.type)) != (
                rt.FLOW_BREAK, rt.FLOW_CONTINUE):
            return False
        if not brk.name or not cont.name:
            return False
        return (self._is_label_reraise(brk.body[:1], brk.name)
                and len(brk.body) == 2 and isinstance(brk.body[1], ast.Break)
                and self._is_label_reraise(cont.body, cont.name)
                and len(cont.body) == 1)

    @staticmethod
    def _is_label_reraise(stmts: list[ast.stmt], name: str) -> bool:
        """``if <name>.label: raise`` — the trap's "this jump targets an OUTER
        loop" escape hatch."""
        if len(stmts) != 1 or not isinstance(stmts[0], ast.If):
            return False
        guard = stmts[0]
        test = guard.test
        return (isinstance(test, ast.Attribute) and test.attr == "label"
                and isinstance(test.value, ast.Name) and test.value.id == name
                and not guard.orelse and len(guard.body) == 1
                and isinstance(guard.body[0], ast.Raise)
                and guard.body[0].exc is None)

    def _is_return_wrapper(self, s: ast.Try) -> bool:
        """``compiler.emit_body``::

            try:
                <body>
            except ballrt.BallReturn as _r:
                return _r.value        # or, for a constructor body: pass

        Also plumbing: Ball's ``std.return`` unwinds on its own, so the inverse
        is ``<body>``.
        """
        if s.orelse or s.finalbody or len(s.handlers) != 1:
            return False
        handler = s.handlers[0]
        if self._rt_attr(handler.type) != rt.FLOW_RETURN or len(handler.body) != 1:
            return False
        only = handler.body[0]
        if isinstance(only, ast.Pass):
            return True
        return (isinstance(only, ast.Return) and handler.name is not None
                and isinstance(only.value, ast.Attribute) and only.value.attr == "value"
                and isinstance(only.value.value, ast.Name)
                and only.value.value.id == handler.name)

    def encode_try(self, s: ast.Try) -> list[dict]:
        """One of the four ``try:`` lowerings, or a loud failure."""
        if self._is_loop_trap(s):
            # `encode_stmts` intercepts a trap where it can still see whether
            # anything follows it, so this arm means a caller walked statements
            # without that context — exactly where inlining would be unsound.
            self.fail("the compiled loop-body break/continue trap can only be read "
                      "back in its enclosing block, where a C-style `for`'s update "
                      "is still visible")
            return []
        if self._is_return_wrapper(s):
            return self.encode_stmts(s.body)
        return [b.expr_stmt(self.encode_ball_try(s))]

    def encode_ball_try(self, s: ast.Try) -> dict:
        """``compiler.run_try`` -> ``std.try {body, catches, finally}``.

        The emitted handler is::

            except ballrt.BallThrow as _ex:
                ballrt.flow._caught.append(_ex.value)
                try:
                    <var> = _ex.value                      # catch (e)
                    <st>  = ballrt.stack_trace_of(_ex)     # catch (e, st)
                    <catch body>
                finally:
                    ballrt.flow._caught.pop()

        The ``_caught`` push/pop is the runtime's rethrow stack — the compiler's
        spelling of "a catch is in scope", which ``std.rethrow`` reads. It has no
        Ball expression of its own, so it is consumed by this recogniser rather
        than encoded.

        Since #724 the statements inside that frame may be a typed DISPATCH
        CHAIN rather than one clause's bindings::

            if ballrt.catch_matches(_ex.value, "T1"):
                <clause 1>
            elif ballrt.catch_matches(_ex.value, "T2"):
                <clause 2>
            else:
                <untyped clause>      # or `raise _ex` when every clause is typed

        which reads back as the multi-element ``catches`` list it came from —
        each typed arm carrying its ``type`` field, the ``else`` arm the untyped
        fallback, and a trailing ``raise _ex`` meaning "no untyped clause" (the
        re-raise is ``std.try``'s own semantics, not a clause).
        """
        if s.orelse:
            self.fail("try/else is not a shape `python/compiler` emits")
            return b.null_lit()
        fields: list[tuple[str, dict]] = [("body", self.encode_block(s.body))]
        if s.handlers:
            clauses = self._encode_catch(s.handlers)
            if clauses is None:
                return b.null_lit()
            fields.append(("catches", b.list_lit(clauses)))
        if s.finalbody:
            fields.append(("finally", self.encode_block(s.finalbody)))
        if not s.handlers and not s.finalbody:
            self.fail("a `try:` with neither a handler nor a `finally:` is not a "
                      "shape `python/compiler` emits")
            return b.null_lit()
        return b.std_call("try", b.args_message(*fields))

    def _encode_catch(self, handlers: list[ast.ExceptHandler]) -> list[dict] | None:
        """The single ``except ballrt.BallThrow as _ex:`` handler -> the Ball
        catch messages it lowers. Returns None (having failed loud) for anything
        else."""
        if len(handlers) != 1:
            self.fail(f"a compiled `try:` has exactly one `except "
                      f"{rt.RUNTIME_MODULE}.{rt.FLOW_THROW}` handler, found "
                      f"{len(handlers)}")
            return None
        handler = handlers[0]
        name = handler.name
        if self._rt_attr(handler.type) != rt.FLOW_THROW or not name:
            self.fail(f"unsupported `except` clause: only "
                      f"`{rt.RUNTIME_MODULE}.{rt.FLOW_THROW} as <name>` (a Ball "
                      "`std.try`), the loop break/continue trap and the "
                      f"`{rt.FLOW_RETURN}` body wrapper have Ball inverses")
            return None
        body = self._catch_handler_body(handler, name)
        if body is None:
            return None
        if len(body) == 1 and isinstance(body[0], ast.If) \
                and self._catch_clause_type(body[0].test, name) is not None:
            return self._encode_catch_chain(body[0], name)
        return [self._encode_catch_clause(body, name, None)]

    def _encode_catch_chain(self, node: ast.If, name: str) -> list[dict] | None:
        """The typed dispatch chain (issue #724) -> one clause per arm.

        Walked in the order the compiler emitted it, which is the SOURCE order
        of the Ball `catches` list. The chain ends in one of two `else` arms: the
        untyped fallback clause, or `raise <_ex>` — the re-raise that means the
        clause list was ALL typed, which is `std.try`'s own behaviour and so
        encodes to no clause at all."""
        clauses: list[dict] = []
        current = node
        while True:
            type_name = self._catch_clause_type(current.test, name)
            if type_name is None:
                self.fail("a compiled typed catch arm tests "
                          f"`{rt.RUNTIME_MODULE}.{rt.CATCH_MATCHES}("
                          f"{name}.value, \"<Type>\")`, which this one does not")
                return None
            clauses.append(self._encode_catch_clause(current.body, name, type_name))
            orelse = current.orelse
            if len(orelse) == 1 and isinstance(orelse[0], ast.If) \
                    and self._catch_clause_type(orelse[0].test, name) is not None:
                current = orelse[0]
                continue
            if self._is_catch_reraise(orelse, name):
                return clauses
            if not orelse:
                self.fail("a compiled typed catch chain ends in an `else:` — "
                          "either the untyped clause or the `raise` that re-raises "
                          "an unmatched value — and this one has neither")
                return None
            clauses.append(self._encode_catch_clause(orelse, name, None))
            return clauses

    @staticmethod
    def _is_catch_reraise(stmts: list[ast.stmt], name: str) -> bool:
        """``raise <_ex>`` — the chain's "no clause matched" arm."""
        return (len(stmts) == 1 and isinstance(stmts[0], ast.Raise)
                and stmts[0].cause is None
                and isinstance(stmts[0].exc, ast.Name) and stmts[0].exc.id == name)

    def _catch_clause_type(self, test: ast.expr, name: str) -> str | None:
        """``ballrt.catch_matches(<_ex>.value, "<Type>")`` -> ``"<Type>"``."""
        if not (isinstance(test, ast.Call) and not test.keywords
                and self._rt_attr(test.func) == rt.CATCH_MATCHES
                and len(test.args) == 2):
            return None
        thrown, type_arg = test.args
        if not self._is_thrown_value(thrown, name):
            return None
        if not (isinstance(type_arg, ast.Constant) and isinstance(type_arg.value, str)
                and type_arg.value):
            return None
        return type_arg.value

    def _encode_catch_clause(self, body: list[ast.stmt], name: str,
                             type_name: str | None) -> dict:
        """One clause's bindings + body -> its Ball catch message."""
        clause: list[tuple[str, dict]] = []
        if type_name is not None:
            clause.append(("type", b.string_lit(type_name)))
        # `<var> = _ex.value` / `<st> = ballrt.stack_trace_of(_ex)` are the
        # clause's OWN bindings, not assignments: `_ex` has no Ball existence.
        while body and (binding := self._catch_binding(body[0], name)) is not None:
            kind, bound = binding
            if kind in dict(clause):
                break
            clause.append((kind, b.string_lit(bound)))
            body = body[1:]
        clause.append(("body", self.encode_block(body)))
        order = {"type": 0, "variable": 1, "stack_trace": 2, "body": 3}
        clause.sort(key=lambda kv: order[kv[0]])
        return b.args_message(*clause)

    def _catch_handler_body(self, handler: ast.ExceptHandler,
                            name: str) -> list[ast.stmt] | None:
        """Strip the `_caught` push/pop frame, returning the clause's own
        statements."""
        body = handler.body
        if not (len(body) == 2 and isinstance(body[0], ast.Expr)
                and self._is_caught_call(body[0].value, "append", name)):
            self.fail(f"a compiled catch opens with "
                      f"`{rt.RUNTIME_MODULE}.{rt.FLOW_MODULE}.{rt.CAUGHT_STACK}"
                      ".append(...)`, which this one does not")
            return None
        inner = body[1]
        if not (isinstance(inner, ast.Try) and not inner.handlers and not inner.orelse
                and len(inner.finalbody) == 1
                and isinstance(inner.finalbody[0], ast.Expr)
                and self._is_caught_call(inner.finalbody[0].value, "pop", None)):
            self.fail(f"a compiled catch closes its "
                      f"`{rt.CAUGHT_STACK}` frame in a `finally:`, which this one "
                      "does not")
            return None
        return inner.body

    def _is_caught_call(self, node: ast.expr, method: str, name: str | None) -> bool:
        """``ballrt.flow._caught.<method>(<name>.value)`` (``pop`` takes none)."""
        if not isinstance(node, ast.Call) or node.keywords:
            return False
        func = node.func
        if not (isinstance(func, ast.Attribute) and func.attr == method):
            return False
        stack = func.value
        if not (isinstance(stack, ast.Attribute) and stack.attr == rt.CAUGHT_STACK
                and self._rt_attr(stack.value) == rt.FLOW_MODULE):
            return False
        if name is None:
            return not node.args
        return len(node.args) == 1 and self._is_thrown_value(node.args[0], name)

    @staticmethod
    def _is_thrown_value(node: ast.expr, name: str) -> bool:
        return (isinstance(node, ast.Attribute) and node.attr == "value"
                and isinstance(node.value, ast.Name) and node.value.id == name)

    def _catch_binding(self, stmt: ast.stmt, name: str) -> tuple[str, str] | None:
        """``<var> = _ex.value`` -> ``("variable", var)``;
        ``<st> = ballrt.stack_trace_of(_ex)`` -> ``("stack_trace", st)``."""
        if not (isinstance(stmt, ast.Assign) and len(stmt.targets) == 1
                and isinstance(stmt.targets[0], ast.Name)):
            return None
        bound = stmt.targets[0].id
        value = stmt.value
        if self._is_thrown_value(value, name):
            return ("variable", bound)
        if (isinstance(value, ast.Call)
                and self._rt_attr(value.func) == rt.STACK_TRACE_OF
                and len(value.args) == 1 and isinstance(value.args[0], ast.Name)
                and value.args[0].id == name):
            return ("stack_trace", bound)
        return None

    def _compiled_loop(self, s: ast.While) -> dict | None:
        """``while True:`` carrying a loop trap -> the Ball loop it came from.

        ``compiler.run_for`` / ``run_while`` / ``run_dowhile`` all lower to a
        ``while True:``; what separates them is where the exit guard sits and
        whether anything follows the trap::

            while True:                      while True:
                if not truthy(C): break          <trap BODY>
                <trap BODY>                      if not truthy(C): break
                <UPDATE>                     -> std.do_while {body, condition}

            UPDATE empty -> std.while {condition, body}
            otherwise    -> std.for   {condition, update, body}

        ``std.for`` rather than a ``std.while`` whose body ends with the update:
        the compiled `except ballrt.BallContinue` falls THROUGH to the update, and
        only ``std.for`` runs an update on ``continue``. A ``std.while`` would be
        a loop that never advances — and it would hang, not raise.

        The C-style loop's ``init`` stays where the compiler put it (ordinary
        statements before the loop), which is exactly equivalent to a ``std.for``
        whose ``init`` has already run.
        """
        if not (isinstance(s.test, ast.Constant) and s.test.value is True):
            return None
        body = s.body
        if body and isinstance(body[0], ast.Try) and self._is_loop_trap(body[0]):
            if len(body) != 2:
                return None
            condition = self._exit_guard(body[1])
            if condition is None:
                return None
            return b.std_call("do_while", b.args_message(
                ("body", b.block_expr(self.encode_stmts(body[0].body), None)),
                ("condition", self.encode_expr(condition)),
            ))
        if len(body) < 2 or not (isinstance(body[1], ast.Try)
                                 and self._is_loop_trap(body[1])):
            return None
        condition = self._exit_guard(body[0])
        if condition is None:
            return None
        loop_body = b.block_expr(self.encode_stmts(body[1].body), None)
        update = body[2:]
        if not update:
            return b.std_call("while", b.args_message(
                ("condition", self.encode_expr(condition)),
                ("body", loop_body),
            ))
        return b.std_call("for", b.args_message(
            ("condition", self.encode_expr(condition)),
            ("update", self._as_expression(update)),
            ("body", loop_body),
        ))

    def _exit_guard(self, stmt: ast.stmt) -> ast.expr | None:
        """``if not ballrt.truthy(C): break`` -> ``C``, the loop's condition."""
        if not (isinstance(stmt, ast.If) and not stmt.orelse
                and len(stmt.body) == 1 and isinstance(stmt.body[0], ast.Break)):
            return None
        test = stmt.test
        if not (isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not)):
            return None
        call = test.operand
        if not (isinstance(call, ast.Call) and len(call.args) == 1
                and self._rt_attr(call.func) == rt.TRUTHY):
            return None
        return call.args[0]

    def _as_expression(self, stmts: list[ast.stmt]) -> dict:
        """A ``std.for``'s ``update`` is an EXPRESSION; the compiler emits it as
        statements. One expression statement is that expression; anything else
        becomes a block expression, which evaluates the same way."""
        encoded = self.encode_stmts(stmts)
        if len(encoded) == 1 and "expression" in encoded[0]:
            return encoded[0]["expression"]
        return b.block_expr(encoded, None)

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
            # A Ball Python runtime helper (`ballrt.add(...)`) — `python/compiler`
            # emits every base call as one of these, so recognizing them is what
            # lets the encoder read the compiler's own output back (issue #642,
            # see ballrt_calls.py).
            if isinstance(func.value, ast.Name) and func.value.id == rt.RUNTIME_MODULE:
                return self.encode_ballrt_call(func.attr, node.args)
            # Any other method / qualified call (`obj.method(...)`). Only
            # single-argument prints and free functions are in scope; other
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

    def encode_ballrt_call(self, name: str, args: list[ast.expr]) -> dict:
        """Encode a ``ballrt.<name>(args…)`` call.

        Most are one universal ``std`` base call, per ``ballrt_calls.HELPERS``.
        The shapes that are not — a ``fieldAccess`` node, an assignment l-value,
        a bare type-NAME operand, an adapter with no Ball spelling — are named
        constants in that module and handled explicitly first."""
        if name in rt.PASSTHROUGH:
            # An adapter whose Ball semantics are implicit in the consuming node
            # (condition truthiness, `for_in`/`spread` iteration).
            if len(args) != 1:
                self.fail(f"ballrt.{name}() expects exactly one argument")
                return b.null_lit()
            return self.encode_expr(args[0])
        if name == rt.FIELD_GET:
            return self.encode_field_get(args)
        if name == rt.FIELD_SET:
            return self.encode_field_set(args)
        if name == rt.INDEX_SET:
            return self.encode_index_set(args)
        if name in rt.TYPE_OPS:
            return self.encode_type_op(name, args)
        if name in rt.LABEL_OPS:
            return self.encode_label_op(name, args)
        if name == rt.RETHROW:
            if args:
                self.fail(f"ballrt.{name}() takes no arguments, got {len(args)}")
            return b.std_call(rt.RETHROW, None)
        if name == rt.ENTRY_WRAPPER:
            self.fail(f"ballrt.{name}() is the compiled entry-point wrapper and is "
                      "encodable only inside an `if __name__ == \"__main__\":` guard "
                      "alongside the entry function it names")
            return b.null_lit()
        entry = rt.HELPERS.get(name)
        if entry is None:
            self.fail(f"unsupported runtime helper ballrt.{name}() (ball_encoder/"
                      "ballrt_calls.py lists the helpers that have a universal std inverse)")
            return b.null_lit()
        fn, fields = entry
        if len(args) != len(fields):
            self.fail(f"ballrt.{name}() expects {len(fields)} argument(s), got {len(args)}")
            return b.null_lit()
        return b.std_call(fn, b.args_message(
            *((field, self.encode_expr(arg)) for field, arg in zip(fields, args))))

    def _name_operand(self, helper: str, arg: ast.expr, what: str) -> str | None:
        """The bare string literal a non-expression operand must be.

        ``getfield``/``setfield`` take a field NAME and ``is_type``/``as_type`` a
        TYPE NAME; the compiler always emits those as string literals. A computed
        operand is a shape this encoder cannot represent — it fails loud rather
        than guessing at a name (issue #55 doctrine)."""
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
            return arg.value
        self.fail(f"ballrt.{helper}() needs a literal {what}, not a computed one")
        return None

    def encode_field_get(self, args: list[ast.expr]) -> dict:
        """``ballrt.getfield(obj, "name")`` -> a ``fieldAccess`` expression."""
        if len(args) != 2:
            self.fail(f"ballrt.{rt.FIELD_GET}() expects 2 argument(s), got {len(args)}")
            return b.null_lit()
        field = self._name_operand(rt.FIELD_GET, args[1], "field name")
        obj = self.encode_expr(args[0])
        return b.field_access(obj, field) if field is not None else b.null_lit()

    def encode_field_set(self, args: list[ast.expr]) -> dict:
        """``ballrt.setfield(obj, "name", v)`` -> ``std.assign`` onto a
        ``fieldAccess`` l-value — exactly what the compiler reads back as a
        field set."""
        if len(args) != 3:
            self.fail(f"ballrt.{rt.FIELD_SET}() expects 3 argument(s), got {len(args)}")
            return b.null_lit()
        field = self._name_operand(rt.FIELD_SET, args[1], "field name")
        obj = self.encode_expr(args[0])
        value = self.encode_expr(args[2])
        if field is None:
            return b.null_lit()
        return self.assign_to(b.field_access(obj, field), value)

    def encode_index_set(self, args: list[ast.expr]) -> dict:
        """``ballrt.index_set(target, key, v)`` -> ``std.assign`` onto the
        ``std.index`` call that is Ball's index l-value."""
        if len(args) != 3:
            self.fail(f"ballrt.{rt.INDEX_SET}() expects 3 argument(s), got {len(args)}")
            return b.null_lit()
        target = b.std_call("index", b.args_message(
            ("target", self.encode_expr(args[0])),
            ("index", self.encode_expr(args[1])),
        ))
        return self.assign_to(target, self.encode_expr(args[2]))

    def encode_type_op(self, helper: str, args: list[ast.expr]) -> dict:
        """``ballrt.is_type(v, "T")`` / ``ballrt.as_type(v, "T")`` -> ``std.is`` /
        ``std.as``, whose ``type`` field carries the type NAME as a string."""
        if len(args) != 2:
            self.fail(f"ballrt.{helper}() expects 2 argument(s), got {len(args)}")
            return b.null_lit()
        type_name = self._name_operand(helper, args[1], "type name")
        value = self.encode_expr(args[0])
        if type_name is None:
            return b.null_lit()
        return b.std_call(rt.TYPE_OPS[helper], b.args_message(
            ("value", value), ("type", b.string_lit(type_name))))

    def encode_label_op(self, helper: str, args: list[ast.expr]) -> dict:
        """``ballrt.brk(label)`` / ``ballrt.cont(label)`` -> ``std.break`` /
        ``std.continue``.

        The operand is a label NAME, not an expression, and the compiler always
        passes one — EMPTY for an unlabelled jump, which is the *absence* of the
        ``label`` field in Ball (the shape ``dart/encoder`` produces, and what
        every engine's "innermost loop" path tests for)."""
        fn = rt.LABEL_OPS[helper]
        if len(args) != 1:
            self.fail(f"ballrt.{helper}() expects 1 argument(s), got {len(args)}")
            return b.null_lit()
        label = self._name_operand(helper, args[0], "label")
        if label is None:
            return b.null_lit()
        if not label:
            return b.std_call(fn, None)
        return b.std_call(fn, b.args_message(("label", b.string_lit(label))))

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


# ── Compile-time constant helpers ────────────────────────────────────────────


def _const_int(node: ast.expr) -> int | None:
    """The integer value of a compile-time integer constant, unwrapping a unary
    sign (``-1`` parses as ``UnaryOp(USub, Constant(1))``). Returns ``None`` for
    anything not statically an ``int`` (a name, a call, a float …). ``bool`` is
    excluded — a `range(..., True)` step is not a meaningful integer step."""
    if isinstance(node, ast.Constant) and isinstance(node.value, int) and not isinstance(node.value, bool):
        return node.value
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
        inner = _const_int(node.operand)
        if inner is not None:
            return -inner if isinstance(node.op, ast.USub) else inner
    return None


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
        elif isinstance(node, ast.Try):
            # Every loop body `python/compiler` emits lives inside a
            # break/continue trap, so a `try:` the scan does not descend into
            # hides most of the corpus's locals: they would be `std.assign`ed
            # without ever being declared (issue #690). The handlers' OWN names
            # (`_ex`, `_brk`, …) are not assignments and are consumed by the
            # recognisers, so they never reach here.
            for s in node.body + node.orelse + node.finalbody:
                walk(s)
            for handler in node.handlers:
                for s in handler.body:
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
