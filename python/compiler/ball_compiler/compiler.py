"""Ball → Python compiler.

Emits Python source as strings (the approach the C++/Rust/Go/C# compilers take,
rather than Dart's ``code_builder`` AST). A Ball ``Program`` becomes one Python
module importing :mod:`ballrt`.

Design notes
------------

* **Real Python classes.** A ``typeDefs[]`` entry of kind ``class`` becomes a
  Python ``class`` with an ``__init__`` and its methods, so field access is
  attribute access and method dispatch is Python's own (``obj.method(...)``).
  User instances are ordinary Python objects.

* **Block / control-flow lowering (Python has no statement-expressions).** Two
  contexts drive emission:

    - ``run(expr, dest)`` emits Python *statements* that evaluate ``expr`` and
      send its result to a destination (``return`` / assign a name / discard).
      Blocks, ``if``, and the loops lower here to native Python statements. This
      is the device for "a block is an expression": a block used where a value
      is needed is hoisted (its statements are emitted, its result captured in a
      temp).
    - ``value(expr)`` returns a Python *expression* string, hoisting any
      statement-bearing sub-expression into preceding statements + a temp.

* **Lazy control flow (invariant #4).** ``if``/``for``/``while``/``for_in``
  compile to native Python control flow — branches/bodies are only emitted
  inside the taken arm, never eagerly evaluated. A C-style ``for`` lowers to
  ``while True:`` with the condition re-checked each iteration so a hoisted
  condition re-evaluates correctly.

* **Flow signals (invariant #4).** ``return``/``break``/``continue``/``throw``
  compile to :mod:`ballrt.flow` helper *calls* that raise; function bodies catch
  ``BallReturn`` and loop bodies catch ``BallBreak``/``BallContinue`` (so a
  ``continue`` still runs a C-``for`` update).

* **Fail loud (issue #55).** An unsupported base function or expression shape is
  a :class:`CompileError`, never silently-wrong code.
"""

from __future__ import annotations

import json
import keyword

# Expression node kinds, in the order the proto oneof declares them.
_EXPR_KINDS = ("call", "literal", "reference", "fieldAccess", "messageCreation", "block", "lambda")

# Base functions that lower to Python statements (handled by ``run``), keyed for
# both the run() dispatch and the value()-position "needs hoisting" test.
_CONTROL_HOIST = {
    "if", "for", "while", "for_in", "for_each", "do_while", "switch", "switch_expr", "try",
}
_INCDEC = {"pre_increment", "post_increment", "pre_decrement", "post_decrement"}
_FLOW = {"return", "break", "continue", "throw", "rethrow"}

_PY_RESERVED = set(keyword.kwlist) | {"ballrt", "True", "False", "None", "match", "case"}


class CompileError(Exception):
    """A Ball construct the compiler does not support (fail-loud, issue #55)."""


def _which(e):
    if not isinstance(e, dict):
        return None
    for k in _EXPR_KINDS:
        if k in e:
            return k
    return None


def _short(name: str) -> str:
    """Strip a ``module:Type`` qualifier ("main:Point" → "Point")."""
    return name.rsplit(":", 1)[-1] if ":" in name else name


def _member_short(name: str) -> str:
    """The bare member name of a class member ("main:Point.describe" → "describe")."""
    return _short(name).rsplit(".", 1)[-1]


def _is_positional(name: str) -> bool:
    return name.startswith("arg") and len(name) > 3 and name[3:].isdigit()


def sanitize(name: str) -> str:
    """Turn a Ball identifier into a valid, non-colliding Python identifier."""
    if not name:
        return "_anon"
    out = []
    for i, ch in enumerate(name):
        if (ch.isascii() and ch.isalnum()) or ch == "_":
            if i == 0 and ch.isdigit():
                out.append("_")
            out.append(ch)
        else:
            out.append("_")
    s = "".join(out)
    if s in _PY_RESERVED:
        return "b_" + s
    return s


def pystr(s: str) -> str:
    """A Python string literal for ``s`` (double-quoted, fully escaped).

    ``ensure_ascii=False`` keeps non-BMP characters (emoji, CJK) as themselves —
    ASCII-escaping them would emit lone-surrogate ``\\uXXXX`` pairs that Python's
    literal parser reads as two code points, corrupting the string. The compiled
    module is written and read as UTF-8.
    """
    return json.dumps(s, ensure_ascii=False)


# Destinations for ``run``.
RETURN = ("return",)
DISCARD = ("discard",)


def _assign(name):
    return ("assign", name)


class Compiler:
    def __init__(self, program: dict):
        self.prog = program
        self.lines: list[str] = []
        self.ind = 0
        self.errors: list[str] = []
        self._temp = 0

        # Scope stack of Ball-name -> Python-name, and per-function reserved set.
        self.scopes: list[dict[str, str]] = []
        self.reserved: set[str] = set()

        # Per-method context for implicit-`self` field references.
        self.cur_class: str | None = None
        self.cur_fields: set[str] = set()
        self.in_method = False

        self._classify()

    # ── Program classification ───────────────────────────────────────────────

    def _classify(self):
        self.base_modules: set[str] = set()
        self.stub_modules: set[str] = set()
        self.user_funcs: set[str] = set()
        self.type_defs: dict[str, dict] = {}
        self.class_members: dict[str, list[dict]] = {}
        self.class_order: list[str] = []
        self.constructors: dict[str, dict] = {}
        self.instance_fields: dict[str, list[str]] = {}

        for m in self.prog.get("modules", []):
            fns = m.get("functions", [])
            if fns and all(f.get("isBase") for f in fns):
                self.base_modules.add(m.get("name", ""))
            elif not fns and not m.get("typeDefs") and not m.get("enums"):
                self.stub_modules.add(m.get("name", ""))

        for m in self.prog.get("modules", []):
            name = m.get("name", "")
            if name in self.base_modules or name in self.stub_modules:
                continue
            for td in m.get("typeDefs", []):
                short = _short(td.get("name", ""))
                self.type_defs[short] = td
                self.instance_fields[short] = [
                    fld.get("name", "") for fld in td.get("descriptor", {}).get("field", [])
                ]
            for f in m.get("functions", []):
                if f.get("isBase"):
                    continue
                fname = f.get("name", "")
                if ":" in fname and "." in _short(fname):
                    owner = _short(fname).rsplit(".", 1)[0]
                    if owner not in self.class_members:
                        self.class_order.append(owner)
                        self.class_members[owner] = []
                    self.class_members[owner].append(f)
                    if (f.get("metadata", {}) or {}).get("kind") == "constructor":
                        self.constructors[owner] = f
                else:
                    self.user_funcs.add(sanitize(fname))

    # ── Emission helpers ─────────────────────────────────────────────────────

    def line(self, text: str):
        self.lines.append("    " * self.ind + text if text else "")

    class _Block:
        def __init__(self, c):
            self.c = c

        def __enter__(self):
            self.c.ind += 1

        def __exit__(self, *a):
            self.c.ind -= 1

    def block(self):
        return Compiler._Block(self)

    def newtemp(self) -> str:
        self._temp += 1
        return f"_t{self._temp}"

    def fail(self, msg: str) -> str:
        self.errors.append(msg)
        return f"ballrt.throw({pystr('compile error: ' + msg)})"

    # ── Scope tracking ───────────────────────────────────────────────────────

    def push_scope(self):
        self.scopes.append({})

    def pop_scope(self):
        self.scopes.pop()

    def reserve(self, py_name: str):
        self.reserved.add(py_name)

    def bind(self, ball_name: str) -> str:
        base = sanitize(ball_name)
        py = base
        n = 2
        while py in self.reserved and not self._bound_here(ball_name, py):
            py = f"{base}_{n}"
            n += 1
        self.reserved.add(py)
        self.scopes[-1][ball_name] = py
        return py

    def _bound_here(self, ball_name, py):
        return self.scopes and self.scopes[-1].get(ball_name) == py

    def lookup(self, ball_name: str) -> str | None:
        for sc in reversed(self.scopes):
            if ball_name in sc:
                return sc[ball_name]
        return None

    # ── Top-level compile ────────────────────────────────────────────────────

    def compile(self) -> str:
        self.line("# Code generated by the Ball -> Python compiler. DO NOT EDIT.")
        self.line(f"# Program: {self.prog.get('name', '')} v{self.prog.get('version', '')}")
        self.line("import ballrt")
        self.line("")

        for m in self.prog.get("modules", []):
            name = m.get("name", "")
            if name in self.base_modules or name in self.stub_modules:
                continue
            for en in m.get("enums", []):
                self.emit_enum(en)
            for short in [_short(td.get("name", "")) for td in m.get("typeDefs", [])]:
                self.emit_class(short)

        entry_mod, entry_fn = self.prog.get("entryModule"), self.prog.get("entryFunction")
        for m in self.prog.get("modules", []):
            name = m.get("name", "")
            if name in self.base_modules or name in self.stub_modules:
                continue
            for f in m.get("functions", []):
                if f.get("isBase"):
                    continue
                if ":" in f.get("name", "") and "." in _short(f.get("name", "")):
                    continue  # class member, emitted with its class
                self.emit_function(f)

        entry = self._entry_py_name(entry_mod, entry_fn)
        if entry is None:
            raise CompileError(f"entry function {entry_fn!r} not found in module {entry_mod!r}")
        self.line("")
        self.line('if __name__ == "__main__":')
        with self.block():
            self.line(f"ballrt.run_entry({entry})")

        if self.errors:
            raise CompileError(
                f"{len(self.errors)} unsupported construct(s):\n  - "
                + "\n  - ".join(dict.fromkeys(self.errors))
            )
        return "\n".join(self.lines) + "\n"

    def _entry_py_name(self, entry_mod, entry_fn):
        for m in self.prog.get("modules", []):
            if m.get("name") != entry_mod:
                continue
            for f in m.get("functions", []):
                if f.get("name") == entry_fn:
                    return sanitize(entry_fn)
        return None

    # ── Types ────────────────────────────────────────────────────────────────

    def emit_enum(self, en: dict):
        name = sanitize(en.get("name", ""))
        self.line(f"class {name}:")
        with self.block():
            values = en.get("value", [])
            if not values:
                self.line("pass")
            for v in values:
                self.line(f"{sanitize(v.get('name', ''))} = {int(v.get('number', 0))}")
        self.line("")

    def emit_class(self, short: str):
        td = self.type_defs.get(short, {})
        self.line(f"class {sanitize(short)}:")
        with self.block():
            emitted = False
            self.emit_constructor(short)
            emitted = True
            for m in self.class_members.get(short, []):
                if (m.get("metadata", {}) or {}).get("kind") == "constructor":
                    continue
                self.emit_method(short, m)
                emitted = True
            if not emitted:
                self.line("pass")
        self.line("")

    def emit_constructor(self, short: str):
        ctor = self.constructors.get(short)
        fields = self.instance_fields.get(short, [])
        if ctor is None:
            # Synthesise an __init__ that accepts each field positionally.
            params = list(fields)
            self.line(f"def __init__(self, {', '.join(sanitize(p) for p in params)}):"
                      if params else "def __init__(self):")
            with self.block():
                for p in params:
                    self.line(f"self.{p} = {sanitize(p)}")
                if not params:
                    self.line("pass")
            self.line("")
            return

        param_meta = self._param_meta(ctor)
        names = [p.get("name", "") for p in param_meta]
        self.push_scope()
        self.enter_method_ctx(short)
        self.reserved = {"self"}
        sig = ", ".join(["self"] + [sanitize(n) for n in names])
        self.line(f"def __init__({sig}):")
        with self.block():
            for p in param_meta:
                pn = p.get("name", "")
                self.bind(pn)
                if p.get("is_this"):
                    self.line(f"self.{pn} = {sanitize(pn)}")
            # Any declared field not initialised by a `this.` param defaults to None.
            for fld in fields:
                if not any(p.get("name") == fld and p.get("is_this") for p in param_meta):
                    self.line(f"self.{fld} = None")
            self.emit_body(ctor, DISCARD_BODY=True)
        self.line("")
        self.exit_method_ctx()
        self.pop_scope()

    def emit_method(self, short: str, m: dict):
        name = sanitize(_member_short(m.get("name", "")))
        params = [p.get("name", "") for p in self._param_meta(m)]
        self.push_scope()
        self.enter_method_ctx(short)
        self.reserved = {"self", "_input"}
        self.line(f"def {name}(self, _input=None):")
        with self.block():
            self.emit_param_prologue(params)
            self.emit_body(m)
        self.line("")
        self.exit_method_ctx()
        self.pop_scope()

    def enter_method_ctx(self, short):
        self.in_method = True
        self.cur_class = short
        self.cur_fields = set(self.instance_fields.get(short, []))

    def exit_method_ctx(self):
        self.in_method = False
        self.cur_class = None
        self.cur_fields = set()

    # ── Functions ────────────────────────────────────────────────────────────

    def emit_function(self, f: dict):
        name = sanitize(f.get("name", ""))
        params = [p.get("name", "") for p in self._param_meta(f)]
        self.push_scope()
        self.reserved = {"_input"}
        self.line(f"def {name}(_input=None):")
        with self.block():
            self.emit_param_prologue(params)
            self.emit_body(f)
        self.line("")
        self.pop_scope()

    def emit_param_prologue(self, params: list[str]):
        if not params:
            return
        if len(params) == 1:
            py = self.bind(params[0])
            self.line(f"{py} = _input")
            return
        for i, p in enumerate(params):
            py = self.bind(p)
            self.line(f"{py} = ballrt.arg(_input, {pystr(p)}, {pystr('arg' + str(i))})")

    def emit_body(self, f: dict, DISCARD_BODY: bool = False):
        body = f.get("body")
        if not body or _which(body) is None:
            if not DISCARD_BODY:
                self.line("return None")
            return
        if DISCARD_BODY:
            # Constructor body: run for side effects, no return value.
            self.line("try:")
            with self.block():
                before = len(self.lines)
                self.run(body, DISCARD)
                if len(self.lines) == before:
                    self.line("pass")
            self.line("except ballrt.BallReturn:")
            with self.block():
                self.line("pass")
            return
        self.line("try:")
        with self.block():
            before = len(self.lines)
            self.run(body, RETURN)
            if len(self.lines) == before:
                self.line("pass")
        self.line("except ballrt.BallReturn as _r:")
        with self.block():
            self.line("return _r.value")
        self.line("return None")

    def _param_meta(self, f: dict) -> list[dict]:
        meta = f.get("metadata", {}) or {}
        return meta.get("params", []) or []

    # ── run(expr, dest): statement context ───────────────────────────────────

    def run(self, e: dict, dest):
        k = _which(e)
        if k == "block":
            return self.run_block(e["block"], dest)
        if k == "call":
            call = e["call"]
            mod, fn = call.get("module", ""), call.get("function", "")
            if mod in self.base_modules:
                if fn == "if":
                    return self.run_if(call, dest)
                if fn == "for":
                    return self.run_for(call, dest)
                if fn == "while":
                    return self.run_while(call, dest)
                if fn in ("for_in", "for_each"):
                    return self.run_forin(call, dest)
                if fn == "do_while":
                    return self.run_dowhile(call, dest)
                if fn in ("switch", "switch_expr"):
                    return self.run_switch(call, dest)
                if fn == "try":
                    return self.run_try(call, dest)
                if fn in _FLOW:
                    self.line(self.base_flow_expr(call))
                    return
                if fn == "assign":
                    v = self.stmt_assign(call)
                    if dest[0] != "discard":
                        self.dispatch(dest, v)
                    return
                if fn in _INCDEC:
                    return self.run_incdec(call, fn, dest)
        self.dispatch(dest, self.value(e))

    def dispatch(self, dest, v: str):
        if dest[0] == "discard":
            self.line(v)
        elif dest[0] == "return":
            self.line(f"return {v}")
        else:  # assign
            self.line(f"{dest[1]} = {v}")

    def run_block(self, block: dict, dest):
        self.push_scope()
        for stmt in block.get("statements", []):
            if "let" in stmt:
                let = stmt["let"]
                val = self.value(let["value"]) if let.get("value") else "None"
                py = self.bind(let.get("name", ""))
                self.line(f"{py} = {val}")
            elif "expression" in stmt:
                self.run(stmt["expression"], DISCARD)
        result = block.get("result")
        if result is not None:
            self.run(result, dest)
        elif dest[0] == "assign":
            self.line(f"{dest[1]} = None")
        self.pop_scope()

    def run_if(self, call, dest):
        f = self.fields(call)
        cond = self.value(f["condition"])
        self.line(f"if ballrt.truthy({cond}):")
        with self.block():
            before = len(self.lines)
            if "then" in f:
                self.run(f["then"], dest)
            if len(self.lines) == before:
                self.line("pass")
        if "else" in f:
            self.line("else:")
            with self.block():
                before = len(self.lines)
                self.run(f["else"], dest)
                if len(self.lines) == before:
                    self.line("pass")
        elif dest[0] != "discard":
            self.line("else:")
            with self.block():
                self.dispatch(dest, "None")

    def _loop_body(self, f, label):
        """Emit the try/except that runs a loop body and traps break/continue.

        Returns nothing; the caller has already opened the ``while``/``for``. A
        ``BallBreak`` breaks the Python loop; a ``BallContinue`` falls through so
        a following C-``for`` update still runs (Dart semantics)."""
        self.line("try:")
        with self.block():
            before = len(self.lines)
            if "body" in f:
                self.run(f["body"], DISCARD)
            if len(self.lines) == before:
                self.line("pass")
        self.line("except ballrt.BallBreak as _brk:")
        with self.block():
            self.line("if _brk.label: raise")
            self.line("break")
        self.line("except ballrt.BallContinue as _cnt:")
        with self.block():
            self.line("if _cnt.label: raise")

    def run_for(self, call, dest):
        f = self.fields(call)
        self.push_scope()
        if "init" in f:
            self.run_loop_init(f["init"])
        self.line("while True:")
        with self.block():
            if "condition" in f:
                cond = self.value(f["condition"])
                self.line(f"if not ballrt.truthy({cond}):")
                with self.block():
                    self.line("break")
            self._loop_body(f, "")
            if "update" in f:
                self.run(f["update"], DISCARD)
        self.pop_scope()
        if dest[0] != "discard":
            self.dispatch(dest, "None")

    def run_loop_init(self, e):
        k = _which(e)
        if k == "block":
            # The init block's `let`s must live in the loop's scope so the
            # condition/update/body see them — emit its statements inline, no
            # child scope.
            for stmt in e["block"].get("statements", []):
                if "let" in stmt:
                    let = stmt["let"]
                    val = self.value(let["value"]) if let.get("value") else "None"
                    py = self.bind(let.get("name", ""))
                    self.line(f"{py} = {val}")
                elif "expression" in stmt:
                    self.run(stmt["expression"], DISCARD)
        else:
            self.run(e, DISCARD)

    def run_while(self, call, dest):
        f = self.fields(call)
        self.line("while True:")
        with self.block():
            cond = self.value(f["condition"]) if "condition" in f else "True"
            self.line(f"if not ballrt.truthy({cond}):")
            with self.block():
                self.line("break")
            self._loop_body(f, "")
        if dest[0] != "discard":
            self.dispatch(dest, "None")

    def run_dowhile(self, call, dest):
        f = self.fields(call)
        self.line("while True:")
        with self.block():
            self._loop_body(f, "")
            cond = self.value(f["condition"]) if "condition" in f else "False"
            self.line(f"if not ballrt.truthy({cond}):")
            with self.block():
                self.line("break")
        if dest[0] != "discard":
            self.dispatch(dest, "None")

    def run_forin(self, call, dest):
        f = self.fields(call)
        var = self.str_field(f, "variable") or "_it"
        iterable = self.value_field(f, "iterable", "collection", "list")
        self.push_scope()
        it = self.newtemp()
        self.line(f"for {it} in ballrt.iterate({iterable}):")
        with self.block():
            py = self.bind(var)
            self.line(f"{py} = {it}")
            self.line("try:")
            with self.block():
                before = len(self.lines)
                if "body" in f:
                    self.run(f["body"], DISCARD)
                if len(self.lines) == before:
                    self.line("pass")
            self.line("except ballrt.BallBreak as _brk:")
            with self.block():
                self.line("if _brk.label: raise")
                self.line("break")
            self.line("except ballrt.BallContinue as _cnt:")
            with self.block():
                self.line("if _cnt.label: raise")
        self.pop_scope()
        if dest[0] != "discard":
            self.dispatch(dest, "None")

    def run_switch(self, call, dest):
        f = self.fields(call)
        subj = self.newtemp()
        self.line(f"{subj} = {self.value_field(f, 'subject')}")
        cases = self.message_list(f, "cases")
        default_case = None
        pending: list[str] = []
        emitted_any = False
        expr_mode = call.get("function") == "switch_expr"
        for case_mc in cases:
            cf = self.mc_fields(case_mc)
            if self.bool_field(cf, "is_default"):
                default_case = case_mc
                continue
            cond = self.case_condition(subj, cf)
            body = cf.get("body")
            pending.append(cond)
            if body is None or self.is_empty_switch_body(body):
                continue  # fall-through label
            combined = " or ".join(pending)
            pending = []
            kw = "elif" if emitted_any else "if"
            self.line(f"{kw} {combined}:")
            with self.block():
                before = len(self.lines)
                self.run(body, dest if expr_mode else DISCARD)
                if not expr_mode and dest[0] != "discard":
                    pass
                if len(self.lines) == before:
                    self.line("pass")
            emitted_any = True
        if default_case is not None:
            body = self.mc_fields(default_case).get("body")
            self.line("else:" if emitted_any else "if True:")
            with self.block():
                before = len(self.lines)
                if body is not None:
                    self.run(body, dest if expr_mode else DISCARD)
                if len(self.lines) == before:
                    self.line("pass")
        if not expr_mode and dest[0] != "discard":
            self.dispatch(dest, "None")

    def case_condition(self, subj, cf):
        if "pattern_expr" in cf:
            return self.switch_pattern(subj, cf["pattern_expr"])
        return f"ballrt.truthy(ballrt.equals({subj}, {self.value_field(cf, 'pattern', 'value')}))"

    def switch_pattern(self, subj, pe):
        mc = pe.get("messageCreation") if isinstance(pe, dict) else None
        if mc is not None:
            fields = self.mc_fields(mc)
            short = _short(mc.get("typeName", ""))
            if short == "WildcardPattern":
                # A wildcard carrying a `type` is a type pattern (`case int _`),
                # not a bare `_`; type matching is out of Phase-2 scope.
                if "type" in fields:
                    return self.fail("unsupported switch type pattern")
                return "True"
            if short == "LogicalOrPattern":
                return (f"({self.switch_pattern(subj, fields['left'])} or "
                        f"{self.switch_pattern(subj, fields['right'])})")
            if short == "LogicalAndPattern":
                return (f"({self.switch_pattern(subj, fields['left'])} and "
                        f"{self.switch_pattern(subj, fields['right'])})")
            if short == "ConstPattern":
                return f"ballrt.truthy(ballrt.equals({subj}, {self.value_field(fields, 'value')}))"
            # Relational / type / destructuring patterns are out of Phase-2 scope;
            # fail loud rather than silently defaulting (issue #55).
            return self.fail(f"unsupported switch pattern {short}")
        return f"ballrt.truthy(ballrt.equals({subj}, {self.value(pe)}))"

    def is_empty_switch_body(self, e):
        k = _which(e)
        if k == "block":
            blk = e["block"]
            return not blk.get("statements") and blk.get("result") is None
        if k == "literal":
            return not e["literal"]
        return e is None

    def run_try(self, call, dest):
        f = self.fields(call)
        self.line("try:")
        with self.block():
            before = len(self.lines)
            if "body" in f:
                self.run(f["body"], DISCARD if dest[0] == "discard" else dest)
            if len(self.lines) == before:
                self.line("pass")
        catches = self.message_list(f, "catches")
        if catches:
            cf = self.mc_fields(catches[0])
            var = self.str_field(cf, "variable")
            self.line("except ballrt.BallThrow as _ex:")
            with self.block():
                self.push_scope()
                self.line("ballrt.flow._caught.append(_ex.value)")
                self.line("try:")
                with self.block():
                    if var:
                        py = self.bind(var)
                        self.line(f"{py} = _ex.value")
                    before = len(self.lines)
                    if "body" in cf:
                        self.run(cf["body"], DISCARD if dest[0] == "discard" else dest)
                    if len(self.lines) == before:
                        self.line("pass")
                self.line("finally:")
                with self.block():
                    self.line("ballrt.flow._caught.pop()")
                self.pop_scope()
        if "finally" in f:
            self.line("finally:")
            with self.block():
                before = len(self.lines)
                self.run(f["finally"], DISCARD)
                if len(self.lines) == before:
                    self.line("pass")

    def run_incdec(self, call, fn, dest):
        if dest[0] == "discard":
            f = self.fields(call)
            target = f.get("value") or f.get("target")
            lv = self.lvalue(target)
            op = "+=" if "increment" in fn else "-="
            combined = self.combine_op(op, self.lvalue_read(lv), "1")
            self.emit_store(lv, combined)
        else:
            self.dispatch(dest, self.value_incdec(call, fn))

    # ── value(expr): expression context ──────────────────────────────────────

    def value(self, e: dict) -> str:
        k = _which(e)
        if k is None:
            return "None"
        if k == "literal":
            return self.literal(e["literal"])
        if k == "reference":
            return self.reference(e["reference"])
        if k == "fieldAccess":
            fa = e["fieldAccess"]
            return f"ballrt.getfield({self.value(fa['object'])}, {pystr(fa['field'])})"
        if k == "messageCreation":
            return self.value_msgcreation(e["messageCreation"])
        if k == "block":
            blk = e["block"]
            if not blk.get("statements"):
                return self.value(blk["result"]) if blk.get("result") is not None else "None"
            return self.hoist(e)
        if k == "lambda":
            return self.value_lambda(e["lambda"])
        if k == "call":
            call = e["call"]
            mod, fn = call.get("module", ""), call.get("function", "")
            if mod in self.base_modules:
                if fn in _CONTROL_HOIST:
                    return self.hoist(e)
                if fn in _FLOW:
                    return self.base_flow_expr(call)
                if fn == "assign":
                    return self.value_assign(call)
                if fn in _INCDEC:
                    return self.value_incdec(call, fn)
                return self.base_expr(call)
            return self.value_call(call)
        return self.fail(f"unhandled expression node {k}")

    def hoist(self, e: dict) -> str:
        t = self.newtemp()
        self.line(f"{t} = None")
        self.run(e, _assign(t))
        return t

    def literal(self, lit: dict) -> str:
        if "intValue" in lit:
            return str(int(lit["intValue"]))
        if "doubleValue" in lit:
            return repr(float(lit["doubleValue"]))
        if "stringValue" in lit:
            return pystr(lit["stringValue"])
        if "boolValue" in lit:
            return "True" if lit["boolValue"] else "False"
        if "listValue" in lit:
            return self.list_literal(lit["listValue"])
        if "bytesValue" in lit:
            import base64
            return f"bytearray({list(base64.b64decode(lit['bytesValue']))!r})"
        return "None"

    def list_literal(self, lv: dict) -> str:
        elems = lv.get("elements", [])
        if not any(self._collection_kind(el) for el in elems):
            return "[" + ", ".join(self.value(el) for el in elems) + "]"
        # A list with spread / collection_if / collection_for elements is built
        # imperatively into a temp.
        t = self.newtemp()
        self.line(f"{t} = []")
        for el in elems:
            self.emit_collection_element(t, el)
        return t

    def _collection_kind(self, el):
        c = el.get("call") if isinstance(el, dict) else None
        if c and c.get("module") == "std" and c.get("function") in (
            "spread", "null_spread", "collection_if", "collection_for"):
            return c.get("function")
        return None

    def emit_collection_element(self, target, el):
        kind = self._collection_kind(el)
        if kind is None:
            self.line(f"{target}.append({self.value(el)})")
            return
        f = self.fields(el["call"])
        if kind == "spread":
            self.line(f"{target}.extend(ballrt.iterate({self.value_field(f, 'value')}))")
        elif kind == "null_spread":
            tmp = self.newtemp()
            self.line(f"{tmp} = {self.value_field(f, 'value')}")
            self.line(f"if {tmp} is not None:")
            with self.block():
                self.line(f"{target}.extend(ballrt.iterate({tmp}))")
        elif kind == "collection_if":
            self.line(f"if ballrt.truthy({self.value_field(f, 'condition')}):")
            with self.block():
                if "then" in f:
                    self.emit_collection_element(target, f["then"])
                else:
                    self.line("pass")
            if "else" in f:
                self.line("else:")
                with self.block():
                    self.emit_collection_element(target, f["else"])
        elif kind == "collection_for":
            var = self.str_field(f, "variable") or "item"
            self.push_scope()
            it = self.newtemp()
            self.line(f"for {it} in ballrt.iterate({self.value_field(f, 'iterable')}):")
            with self.block():
                py = self.bind(var)
                self.line(f"{py} = {it}")
                if "body" in f:
                    self.emit_collection_element(target, f["body"])
                else:
                    self.line("pass")
            self.pop_scope()

    def reference(self, ref: dict) -> str:
        name = ref.get("name", "")
        if name == "input":
            return self.lookup("input") or "_input"
        if name in ("self", "this"):
            local = self.lookup(name)
            if local:
                return local
            if self.in_method:
                return "self"
            return "self"
        local = self.lookup(name)
        if local:
            return local
        if self.in_method and name in self.cur_fields:
            return f"self.{name}"
        sn = sanitize(name)
        if sn in self.user_funcs:
            return sn
        # Unresolved reference: fail loud (issue #55) but keep the module valid.
        self.errors.append(f"unresolved reference {name!r}")
        return f"ballrt.throw({pystr('unresolved reference ' + name)})"

    def value_msgcreation(self, mc: dict) -> str:
        tn = mc.get("typeName", "")
        short = _short(tn)
        fields = mc.get("fields", [])
        if tn and short in self.type_defs:
            # A user-class constructor call: pass positional args in field order.
            args = [self.value(fv["value"]) for fv in fields]
            return f"{sanitize(short)}({', '.join(args)})"
        # An anonymous / argument / record message → a plain dict.
        parts = [f"{pystr(fv.get('name', ''))}: {self.value(fv['value'])}" for fv in fields]
        return "{" + ", ".join(parts) + "}"

    def value_lambda(self, lam: dict) -> str:
        params = [p.get("name", "") for p in self._param_meta(lam)]
        name = self.newtemp().replace("_t", "_lam")
        self.push_scope()
        saved = self.reserved
        self.reserved = set(self.reserved) | {"_input"}
        self.line(f"def {name}(_input=None):")
        with self.block():
            self.emit_param_prologue(params)
            self.emit_body(lam)
        self.reserved = saved
        self.pop_scope()
        return name

    def value_call(self, call: dict) -> str:
        mod, fn = call.get("module", ""), call.get("function", "")
        if mod in self.stub_modules:
            return self.fail(f"unsupported external call {mod}.{fn}")
        inp = call.get("input")
        mc = inp.get("messageCreation") if inp else None
        # A call carrying `self` in its input is a method call on the receiver.
        if mc is not None and any(fv.get("name") == "self" for fv in mc.get("fields", [])):
            self_expr = "None"
            rest = []
            for fv in mc.get("fields", []):
                if fv.get("name") == "self":
                    self_expr = self.value(fv["value"])
                else:
                    rest.append(fv)
            method = sanitize(fn)
            if not rest:
                return f"{self_expr}.{method}()"
            if len(rest) == 1:
                return f"{self_expr}.{method}({self.value(rest[0]['value'])})"
            packed = "{" + ", ".join(
                f"{pystr(fv.get('name', ''))}: {self.value(fv['value'])}" for fv in rest) + "}"
            return f"{self_expr}.{method}({packed})"
        # A bare local holding a first-class function value.
        if self.lookup(fn):
            return f"ballrt.call_fn({self.lookup(fn)}, {self.value(inp) if inp else 'None'})"
        name = sanitize(fn)
        if name not in self.user_funcs and not (mod and mod == self.prog.get("entryModule")):
            # Unknown callee that is not a user function → a built-in method call
            # is out of Phase-2 scope; fail loud rather than emit an undefined name.
            if name not in self.user_funcs:
                self.errors.append(f"unknown call target {mod}.{fn}")
        return f"{name}({self.value(inp) if inp else 'None'})"

    # ── Base-function dispatch (pure expressions) ────────────────────────────

    def base_expr(self, call: dict) -> str:
        mod, fn = call.get("module", ""), call.get("function", "")
        f = self.fields(call)
        if mod == "std_collections":
            return self.collections_expr(fn, f)

        def a(*names):
            return self.value_field(f, *names)

        L = lambda: a("left")
        R = lambda: a("right")
        V = lambda: a("value")

        # Logical and/or MUST short-circuit (invariant #4): emit native Python
        # `and`/`or` so the right operand is only evaluated when needed, rather
        # than a runtime call that eagerly evaluates both.
        if fn == "and":
            return f"(ballrt.truthy({L()}) and ballrt.truthy({R()}))"
        if fn == "or":
            return f"(ballrt.truthy({L()}) or ballrt.truthy({R()}))"

        table_2 = {
            "add": "add", "subtract": "subtract", "multiply": "multiply",
            "divide": "intdiv", "divide_double": "divide_double", "modulo": "modulo",
            "bitwise_and": "bitwise_and", "bitwise_or": "bitwise_or", "bitwise_xor": "bitwise_xor",
            "left_shift": "left_shift", "right_shift": "right_shift",
            "unsigned_right_shift": "unsigned_right_shift",
            "equals": "equals", "not_equals": "not_equals",
            "less_than": "less_than", "greater_than": "greater_than",
            "null_coalesce": "null_coalesce",
        }
        if fn in table_2:
            return f"ballrt.{table_2[fn]}({L()}, {R()})"
        if fn in ("lte", "less_than_or_equal"):
            return f"ballrt.lte({L()}, {R()})"
        if fn in ("gte", "greater_than_or_equal"):
            return f"ballrt.gte({L()}, {R()})"

        table_1 = {"negate": "negate", "not": "not_", "bitwise_not": "bitwise_not",
                   "to_int": "to_int", "to_double": "to_double", "null_check": "null_check"}
        if fn in table_1:
            return f"ballrt.{table_1[fn]}({V()})"

        if fn == "print":
            return f"ballrt.print_({a('message', 'value')})"
        if fn == "print_error":
            return f"ballrt.print_error({a('message', 'value')})"
        if fn in ("to_string", "int_to_string", "double_to_string"):
            return f"ballrt.to_str({V()})"
        if fn in ("length", "string_length"):
            return f"ballrt.length({V()})"
        if fn in ("concat", "string_concat"):
            return f"ballrt.concat({a('left', 'value')}, {a('right', 'other')})"
        if fn == "compare_to":
            return f"ballrt.compare_to({a('left', 'value')}, {a('right', 'other')})"
        if fn in ("index", "null_aware_index"):
            return f"ballrt.index_get({a('target', 'value', 'object')}, {a('index', 'key')})"
        if fn == "invoke":
            return (f"ballrt.invoke({a('function', 'target', 'callee')}, "
                    f"{a('argument', 'arg', 'input', 'value', 'arg0')})")
        if fn in ("paren", "parenthesized", "await"):
            return V()
        if fn == "spread":
            return a("value")
        if fn == "record":
            parts = [f"{pystr(fv.get('name', ''))}: {self.value(fv['value'])}"
                     for fv in call.get("input", {}).get("messageCreation", {}).get("fields", [])]
            return "{" + ", ".join(parts) + "}"

        # String ops.
        str_1 = {
            "string_to_upper": "string_to_upper", "string_to_lower": "string_to_lower",
            "string_trim": "string_trim", "string_trim_start": "string_trim_start",
            "string_trim_end": "string_trim_end", "string_is_empty": "string_is_empty",
            "string_to_int": "string_to_int", "string_to_double": "string_to_double",
        }
        if fn in str_1:
            return f"ballrt.{str_1[fn]}({V()})"
        if fn == "string_contains":
            return f"ballrt.string_contains({a('value', 'left')}, {a('search', 'right', 'substring')})"
        if fn == "string_starts_with":
            return f"ballrt.string_starts_with({a('value', 'left')}, {a('prefix', 'right')})"
        if fn == "string_ends_with":
            return f"ballrt.string_ends_with({a('value', 'left')}, {a('suffix', 'right')})"
        if fn == "string_index_of":
            return f"ballrt.string_index_of({a('value', 'left')}, {a('search', 'right', 'substring')})"
        if fn == "string_last_index_of":
            return f"ballrt.string_last_index_of({a('value', 'left')}, {a('search', 'right', 'substring')})"
        if fn == "string_split":
            return f"ballrt.string_split({a('value', 'left')}, {a('separator', 'right')})"
        if fn == "string_replace_all":
            return f"ballrt.string_replace_all({a('value')}, {a('from', 'pattern')}, {a('to', 'replacement')})"
        if fn == "string_replace":
            return f"ballrt.string_replace({a('value')}, {a('from', 'pattern')}, {a('to', 'replacement')})"
        if fn == "string_substring":
            end = a("end") if "end" in f else "None"
            return f"ballrt.string_substring({a('value')}, {a('start')}, {end})"
        if fn == "string_code_unit_at":
            return f"ballrt.string_code_unit_at({a('value')}, {a('index')})"

        # Numeric formatting.
        if fn == "to_string_as_fixed":
            return f"ballrt.to_string_as_fixed({V()}, {a('digits', 'fractionDigits')})"
        if fn == "to_string_as_exponential":
            exp = a("digits", "fractionDigits") if ("digits" in f or "fractionDigits" in f) else "None"
            return f"ballrt.to_string_as_exponential({V()}, {exp})"
        if fn == "to_string_as_precision":
            return f"ballrt.to_string_as_precision({V()}, {a('precision')})"

        # Math.
        math_1 = {"math_abs": "math_abs", "math_floor": "math_floor", "math_ceil": "math_ceil",
                  "math_round": "math_round", "math_sqrt": "math_sqrt", "math_trunc": "math_trunc",
                  "math_sign": "math_sign"}
        if fn in math_1:
            return f"ballrt.{math_1[fn]}({V()})"
        if fn == "math_pow":
            return f"ballrt.math_pow({a('base', 'left', 'x')}, {a('exponent', 'right', 'y')})"
        if fn == "math_min":
            return f"ballrt.math_min({L()}, {R()})"
        if fn == "math_max":
            return f"ballrt.math_max({L()}, {R()})"

        return self.fail(f"unsupported base function {mod}.{fn}")

    def collections_expr(self, fn: str, f: dict) -> str:
        def a(*names):
            return self.value_field(f, *names)

        lst, mp, st = lambda: a("list"), lambda: a("map"), lambda: a("set")
        simple = {
            "list_get": ("list_get", [lst, lambda: a("index")]),
            "list_length": ("list_length", [lst]),
            "list_is_empty": ("list_is_empty", [lst]),
            "list_first": ("list_first", [lst]),
            "list_last": ("list_last", [lst]),
            "list_contains": ("list_contains", [lst, lambda: a("value")]),
            "list_index_of": ("list_index_of", [lst, lambda: a("value")]),
            "list_reverse": ("list_reverse", [lst]),
            "list_concat": ("list_concat", [lst, lambda: a("value", "index")]),
            "list_slice": ("list_slice", [lst, lambda: a("start"), lambda: a("end")]),
            "list_take": ("list_take", [lst, lambda: a("count", "index", "value")]),
            "list_drop": ("list_drop", [lst, lambda: a("count", "index", "value")]),
            "list_push": ("list_push", [lst, lambda: a("value")]),
            "list_pop": ("list_pop", [lst]),
            "list_insert": ("list_insert", [lst, lambda: a("index"), lambda: a("value")]),
            "list_remove_at": ("list_remove_at", [lst, lambda: a("index")]),
            "list_set": ("list_set", [lst, lambda: a("index"), lambda: a("value")]),
            "list_clear": ("list_clear", [lst]),
            "list_map": ("list_map", [lst, lambda: a("value", "callback")]),
            "list_filter": ("list_filter", [lst, lambda: a("value", "callback")]),
            "list_all": ("list_all", [lst, lambda: a("value", "callback")]),
            "list_any": ("list_any", [lst, lambda: a("value", "callback")]),
            "list_sort": ("list_sort", [lst, lambda: a("value", "compare")]),
            "list_join": ("list_join", [lst, lambda: a("separator")]),
            "list_to_list": ("list_to_list", [lst]),
            "map_get": ("map_get", [mp, lambda: a("key")]),
            "map_set": ("map_set", [mp, lambda: a("key"), lambda: a("value")]),
            "map_delete": ("map_delete", [mp, lambda: a("key")]),
            "map_contains_key": ("map_contains_key", [mp, lambda: a("key")]),
            "map_contains_value": ("map_contains_value", [mp, lambda: a("value")]),
            "map_keys": ("map_keys", [mp]),
            "map_values": ("map_values", [mp]),
            "map_length": ("map_length", [mp]),
            "map_is_empty": ("map_is_empty", [mp]),
            "map_put_if_absent": ("map_put_if_absent", [mp, lambda: a("key"), lambda: a("value")]),
            "set_add": ("set_add", [st, lambda: a("value")]),
            "set_remove": ("set_remove", [st, lambda: a("value")]),
            "set_contains": ("set_contains", [st, lambda: a("value")]),
            "set_length": ("set_length", [st]),
            "set_is_empty": ("set_is_empty", [st]),
            "set_to_list": ("set_to_list", [st]),
            "set_union": ("set_union", [lambda: a("left", "set"), lambda: a("right", "other")]),
            "set_intersection": ("set_intersection", [lambda: a("left", "set"), lambda: a("right", "other")]),
            "set_difference": ("set_difference", [lambda: a("left", "set"), lambda: a("right", "other")]),
            "string_join": ("list_join", [lst, lambda: a("separator")]),
        }
        if fn in simple:
            rt, argfns = simple[fn]
            return f"ballrt.col.{rt}({', '.join(g() for g in argfns)})"
        if fn == "set_create":
            if any(k in f for k in ("list", "elements", "set")):
                return f"ballrt.col.set_create({self.value_field(f, 'list', 'elements', 'set')})"
            return "ballrt.col.set_create(None)"
        return self.fail(f"unsupported base function std_collections.{fn}")

    # ── Control-flow expression helpers ──────────────────────────────────────

    def base_flow_expr(self, call: dict) -> str:
        fn = call.get("function", "")
        f = self.fields(call)
        if fn == "return":
            return f"ballrt.ret({self.value_field(f, 'value')})" if "value" in f else "ballrt.ret(None)"
        if fn == "break":
            return f"ballrt.brk({pystr(self.str_field(f, 'label'))})"
        if fn == "continue":
            return f"ballrt.cont({pystr(self.str_field(f, 'label'))})"
        if fn == "throw":
            return f"ballrt.throw({self.value_field(f, 'value', 'exception')})"
        if fn == "rethrow":
            return "ballrt.rethrow()"
        return self.fail(f"unsupported control function {fn}")

    # ── Assignment / mutation ────────────────────────────────────────────────

    def lvalue(self, target):
        k = _which(target)
        if k == "reference":
            name = target["reference"]["name"]
            local = self.lookup(name)
            if local:
                return ("var", local)
            if self.in_method and name in self.cur_fields:
                return ("field", "self", name)
            return ("var", sanitize(name))
        if k == "fieldAccess":
            fa = target["fieldAccess"]
            return ("field", self.value(fa["object"]), fa["field"])
        if k == "call":
            call = target["call"]
            if call.get("module") == "std" and call.get("function") in ("index", "null_aware_index"):
                f = self.fields(call)
                return ("index", self.value_field(f, "target", "value", "object"),
                        self.value_field(f, "index", "key"))
        self.errors.append("assign: unsupported lvalue")
        return ("var", "_bad")

    def lvalue_read(self, lv) -> str:
        if lv[0] == "var":
            return lv[1]
        if lv[0] == "field":
            return f"ballrt.getfield({lv[1]}, {pystr(lv[2])})"
        return f"ballrt.index_get({lv[1]}, {lv[2]})"

    def emit_store(self, lv, value_expr: str):
        if lv[0] == "var":
            self.line(f"{lv[1]} = {value_expr}")
        elif lv[0] == "field":
            self.line(f"ballrt.setfield({lv[1]}, {pystr(lv[2])}, {value_expr})")
        else:
            self.line(f"ballrt.index_set({lv[1]}, {lv[2]}, {value_expr})")

    def stmt_assign(self, call) -> str:
        f = self.fields(call)
        op = self.str_field(f, "op") or "="
        lv = self.lvalue(f["target"])
        val = self.value(f["value"])
        combined = self.combine_op(op, self.lvalue_read(lv), val)
        self.emit_store(lv, combined)
        return lv[1] if lv[0] == "var" else combined

    def value_assign(self, call) -> str:
        return self.stmt_assign(call)

    def value_incdec(self, call, fn) -> str:
        f = self.fields(call)
        target = f.get("value") or f.get("target")
        lv = self.lvalue(target)
        op = "+=" if "increment" in fn else "-="
        pre = fn.startswith("pre")
        combined = self.combine_op(op, self.lvalue_read(lv), "1")
        if pre:
            self.emit_store(lv, combined)
            return self.lvalue_read(lv)
        old = self.newtemp()
        self.line(f"{old} = {self.lvalue_read(lv)}")
        self.emit_store(lv, self.combine_op(op, old, "1"))
        return old

    def combine_op(self, op, left, right) -> str:
        if op in ("=", ""):
            return right
        mapping = {
            "+=": "add", "-=": "subtract", "*=": "multiply", "/=": "divide_double",
            "~/=": "intdiv", "%=": "modulo", "&=": "bitwise_and", "|=": "bitwise_or",
            "^=": "bitwise_xor", "<<=": "left_shift", ">>=": "right_shift",
            ">>>=": "unsigned_right_shift", "??=": "null_coalesce",
        }
        if op in mapping:
            return f"ballrt.{mapping[op]}({left}, {right})"
        return right

    # ── Field / message accessors on the raw JSON view ───────────────────────

    def fields(self, call: dict) -> dict:
        inp = call.get("input")
        if not inp:
            return {}
        mc = inp.get("messageCreation")
        if not mc:
            return {}
        return {fv.get("name", ""): fv.get("value") for fv in mc.get("fields", [])}

    def mc_fields(self, mc: dict) -> dict:
        return {fv.get("name", ""): fv.get("value") for fv in mc.get("fields", [])}

    def value_field(self, f: dict, *names) -> str:
        for n in names:
            if n in f:
                return self.value(f[n])
        return "None"

    def str_field(self, f: dict, name: str) -> str:
        e = f.get(name)
        if isinstance(e, dict) and "literal" in e:
            return e["literal"].get("stringValue", "")
        return ""

    def bool_field(self, f: dict, name: str) -> bool:
        e = f.get(name)
        if isinstance(e, dict) and "literal" in e:
            return bool(e["literal"].get("boolValue", False))
        return False

    def message_list(self, f: dict, key: str) -> list:
        e = f.get(key)
        if not isinstance(e, dict) or "literal" not in e:
            return []
        lv = e["literal"].get("listValue")
        if not lv:
            return []
        return [el["messageCreation"] for el in lv.get("elements", []) if "messageCreation" in el]


def compile_program(program: dict) -> str:
    return Compiler(program).compile()
