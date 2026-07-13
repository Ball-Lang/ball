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
import re

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

# Dart builtin type names that appear as static-member receivers (`int.tryParse`,
# `double.infinity`, …). A bare reference resolves to a runtime type token; a
# static call/field is dispatched to a dedicated runtime helper.
_BUILTIN_TYPES = frozenset({"int", "num", "double", "String", "List", "Map", "Set", "Function", "DateTime", "Future"})

# Superclass names supplied by the runtime (ball_value.dart) rather than emitted
# as Python classes — a subclass inherits `ballrt.<name>`.
_RUNTIME_BASES = frozenset({"BallValue", "BallMap"})

# Methods every Dart object has; a user class may override them, but the receiver
# can also be a builtin at run time — always route these through call_method.
_UNIVERSAL_METHODS = frozenset({"toString", "hashCode", "noSuchMethod"})


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
        self.top_level_vars: list[dict] = []
        self.top_var_names: set[str] = set()
        self.type_defs: dict[str, dict] = {}
        self.class_members: dict[str, list[dict]] = {}
        self.class_order: list[str] = []
        self.constructors: dict[str, dict] = {}
        self.named_ctors: dict[str, list[dict]] = {}
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
                        mshort = _member_short(fname)
                        # The unnamed constructor (`.new`) is the primary __init__;
                        # named ones (`.subset`, …) become classmethod factories.
                        if mshort == "new" or owner not in self.constructors:
                            self.constructors[owner] = f
                        if mshort != "new":
                            self.named_ctors.setdefault(owner, []).append(f)
                        # A `this.field` constructor param names an instance field;
                        # record it so getter/method bodies resolve bare references
                        # to it even if the descriptor omits it.
                        for p in (f.get("metadata", {}) or {}).get("params", []):
                            if p.get("is_this"):
                                flds = self.instance_fields.setdefault(owner, [])
                                if p.get("name") not in flds:
                                    flds.append(p.get("name", ""))
                elif (f.get("metadata", {}) or {}).get("kind") == "top_level_variable":
                    # A top-level `const`/`final` (encoded as a 0-param function):
                    # emitted as a module-level variable, referenced by name.
                    self.top_level_vars.append(f)
                    self.top_var_names.add(sanitize(fname))
                else:
                    self.user_funcs.add(sanitize(fname))

        # A global set of every (non-constructor) method's bare name, and the
        # superclass map. Used by ``value_call`` to route an implicit-``self``
        # method call (a module-less call, no ``self`` field, whose function is a
        # method of the enclosing class) to ``self.method(...)``, and by
        # ``emit_class`` to emit real Python inheritance for a user superclass.
        # Method names and free-function names do not collide in the self-hosted
        # engine (verified), so a global membership test is unambiguous.
        self.all_method_names: set[str] = set()
        self.extends: dict[str, str] = {}
        for m in self.prog.get("modules", []):
            name = m.get("name", "")
            if name in self.base_modules or name in self.stub_modules:
                continue
            for td in m.get("typeDefs", []):
                meta = td.get("metadata", {}) or {}
                sup = meta.get("superclass") or meta.get("extends") or meta.get("super")
                if isinstance(sup, str) and sup:
                    self.extends[_short(td.get("name", ""))] = _short(sup)
        for owner, members in self.class_members.items():
            for mem in members:
                if (mem.get("metadata", {}) or {}).get("kind") == "constructor":
                    continue
                self.all_method_names.add(sanitize(_member_short(mem.get("name", ""))))

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
                if (f.get("metadata", {}) or {}).get("kind") == "top_level_variable":
                    continue  # emitted below as a module-level variable
                self.emit_function(f)

        for v in self.top_level_vars:
            self.emit_top_level_var(v)

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

    def compile_library(self) -> str:
        """Compile the program as an importable library (no entry-point driver).

        The self-hosted engine (``dart/self_host/engine.ball.json``) is a
        multi-module ``Program`` whose public surface is its classes
        (``BallEngine``/``StdModuleHandler``/…), not a runnable ``main`` — the
        native driver constructs ``BallEngine`` and calls ``run`` itself. This
        emits every enum/class/free-function exactly as :meth:`compile` does but
        omits the ``if __name__ == "__main__"`` block. The Python analog of Go's
        ``CompileLibrary`` / C#'s engine regen. Fails loud on any unsupported
        construct (issue #55)."""
        self.line("# Code generated by the Ball -> Python compiler (library mode). DO NOT EDIT.")
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

        for m in self.prog.get("modules", []):
            name = m.get("name", "")
            if name in self.base_modules or name in self.stub_modules:
                continue
            for fdef in m.get("functions", []):
                if fdef.get("isBase"):
                    continue
                if ":" in fdef.get("name", "") and "." in _short(fdef.get("name", "")):
                    continue  # class member, emitted with its class
                if (fdef.get("metadata", {}) or {}).get("kind") == "top_level_variable":
                    continue  # emitted below as a module-level variable
                self.emit_function(fdef)

        for v in self.top_level_vars:
            self.emit_top_level_var(v)

        if self.errors:
            raise CompileError(
                f"{len(self.errors)} unsupported construct(s):\n  - "
                + "\n  - ".join(dict.fromkeys(self.errors))
            )
        return "\n".join(self.lines) + "\n"

    def emit_top_level_var(self, f: dict):
        """A top-level ``const``/``final`` (kind ``top_level_variable``) becomes a
        module-level assignment, emitted after functions/classes so its
        initializer may reference them."""
        name = sanitize(f.get("name", ""))
        body = f.get("body")
        self.push_scope()
        self.reserved = set()
        if not body or _which(body) is None:
            self.line(f"{name} = None")
        else:
            self.line(f"{name} = {self.value(body)}")
        self.pop_scope()

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
        members = self.class_members.get(short, [])
        getter_names = {sanitize(_member_short(m.get("name", "")))
                        for m in members if (m.get("metadata", {}) or {}).get("is_getter")}
        has_tostring = any(_member_short(m.get("name", "")) == "toString" for m in members)
        # Emit real Python inheritance only when the superclass is another user
        # class we emit; a runtime base type (BallValue/BallMap …) is not a
        # Python class here, so those extends are dropped (dynamic dispatch does
        # not need them). The critical one is StdModuleHandler -> BallModuleHandler.
        sup = self.extends.get(short)
        if sup and sup in self.type_defs:
            base = f"({sanitize(sup)})"
        elif sup in _RUNTIME_BASES:
            base = f"(ballrt.{sup})"
        else:
            base = ""
        self.line(f"class {sanitize(short)}{base}:")
        with self.block():
            self.emit_constructor(short)  # always emits __init__ (class never empty)
            for m in members:
                meta = m.get("metadata", {}) or {}
                if meta.get("kind") == "constructor":
                    continue
                if meta.get("is_getter"):
                    self.emit_accessor(short, m, "getter")
                elif meta.get("is_setter"):
                    nm = sanitize(_member_short(m.get("name", "")))
                    # A property setter attaches to its getter; a lone setter has
                    # nothing to attach to — fail loud rather than emit broken code.
                    if nm not in getter_names:
                        self.fail(f"setter without matching getter: {short}.{nm}")
                        continue
                    self.emit_accessor(short, m, "setter")
                else:
                    self.emit_method(short, m)
            for nc in self.named_ctors.get(short, []):
                self.emit_named_ctor(short, nc)
            # A user `toString` override is what `print`/`to_str` must dispatch to;
            # Python routes str(obj) through __str__.
            if has_tostring:
                self.line("def __str__(self):")
                with self.block():
                    self.line("return self.toString()")
                self.line("")
        self.line("")

    def _field_inits(self, short: str) -> dict:
        """Field-level default initializers (``final Map _x = {}``) from the
        typeDef metadata, as ``{fieldName: rawDartInitializer}``."""
        td = self.type_defs.get(short, {})
        meta = td.get("metadata", {}) or {}
        out = {}
        for fm in meta.get("fields", []) or []:
            if fm.get("initializer") is not None:
                out[fm.get("name", "")] = fm.get("initializer")
        return out

    def _all_field_names(self, short: str) -> list[str]:
        """Every declared field of a class (descriptor + metadata + this-params)."""
        names = list(self.instance_fields.get(short, []))
        td = self.type_defs.get(short, {})
        for fm in (td.get("metadata", {}) or {}).get("fields", []) or []:
            n = fm.get("name", "")
            if n and n not in names:
                names.append(n)
        return names

    def emit_constructor(self, short: str):
        ctor = self.constructors.get(short)
        fields = self._all_field_names(short)
        field_inits = self._field_inits(short)
        if ctor is None:
            # Synthesise an __init__ accepting each field positionally, applying
            # field-level defaults for fields with an initializer.
            self.push_scope()
            self.reserved = {"self"}
            params = [f for f in fields if f not in field_inits]
            for p in params:
                self.bind(p)
            self.line(f"def __init__(self, {', '.join(sanitize(p) for p in params)}):"
                      if params else "def __init__(self):")
            with self.block():
                for fld in fields:
                    if fld in field_inits:
                        self.line(f"self.{fld} = {self._lower_init(field_inits[fld])}")
                    else:
                        self.line(f"self.{fld} = {sanitize(fld)}")
                if not fields:
                    self.line("pass")
            self.line("")
            self.pop_scope()
            return

        param_meta = self._param_meta(ctor)
        names = [p.get("name", "") for p in param_meta]
        initializers = (ctor.get("metadata", {}) or {}).get("initializers", []) or []
        init_fields = {i.get("name") for i in initializers if i.get("kind") == "field"}
        self.push_scope()
        self.enter_method_ctx(short)
        self.reserved = {"self"}
        sig = ", ".join(["self"] + [self._param_decl(p) for p in param_meta])
        self.line(f"def __init__({sig}):")
        with self.block():
            for p in param_meta:
                self.bind(p.get("name", ""))
            for p in param_meta:
                pn = p.get("name", "")
                if p.get("is_this"):
                    self.line(f"self.{pn} = {sanitize(pn)}")
            # Constructor initializer-list field bindings (`fields = fields ?? {}`).
            for init in initializers:
                if init.get("kind") == "field":
                    self.line(f"self.{init.get('name')} = {self._lower_init(init.get('value'))}")
            # Any remaining declared field: its field-level default, else None.
            for fld in fields:
                if fld in init_fields:
                    continue
                if any(p.get("name") == fld and p.get("is_this") for p in param_meta):
                    continue
                if fld in field_inits:
                    self.line(f"self.{fld} = {self._lower_init(field_inits[fld])}")
                else:
                    self.line(f"self.{fld} = None")
            self.emit_body(ctor, DISCARD_BODY=True)
        self.line("")
        self.exit_method_ctx()
        self.pop_scope()

    def _lower_init(self, src) -> str:
        """Lower a raw Dart field/initializer source string to a Python
        expression (the common shapes — the Python analog of Go's
        ``lowerFieldInitializer``). References resolve against bound params."""
        if src is None:
            return "None"
        s = str(src).strip()
        if "??" in s:
            left, right = self._split_coalesce(s)
            if right:
                return f"ballrt.null_coalesce({self._lower_init(left)}, {self._lower_init(right)})"
        s = re.sub(r"^<[^<>]*(?:<[^<>]*>[^<>]*)*>(?=[\[{])", "", s.strip())
        if s == "{}":
            return "{}"
        if s == "[]":
            return "[]"
        if s in ("''", '""'):
            return "''"
        if s == "true":
            return "True"
        if s == "false":
            return "False"
        if s == "null":
            return "None"
        if re.fullmatch(r"-?\d+", s):
            return s
        if re.fullmatch(r"-?\d+\.\d+", s):
            return s
        if re.fullmatch(r"[A-Za-z_]\w*", s):
            local = self.lookup(s)
            if local:
                return local
            if s in self.top_var_names or s in self.user_funcs or sanitize(s) in self.user_funcs:
                return sanitize(s)
        # A zero-arg constructor initializer (`_Scope()` / `StringBuffer()`).
        ctor = re.fullmatch(r"([A-Za-z_]\w*)\(\)", s)
        if ctor:
            cls = ctor.group(1)
            if cls in self.type_defs:
                return f"{sanitize(cls)}()"
            rc = self.runtime_construct(cls, [])
            if rc is not None:
                return rc
        # An initializer shape we do not lower: default to null rather than emit
        # broken code (these are cosmetic defaults; the body sets real values).
        return "None"

    def _split_coalesce(self, s: str):
        depth = 0
        i = 0
        while i < len(s) - 1:
            ch = s[i]
            if ch in "([{<":
                depth += 1
            elif ch in ")]}>":
                depth -= 1
            elif depth == 0 and s[i:i + 2] == "??":
                return s[:i].strip(), s[i + 2:].strip()
            i += 1
        return s, ""

    def emit_named_ctor(self, short: str, ctor: dict):
        """A named constructor (`Foo.bar(...)`) becomes a classmethod factory that
        builds the instance without re-running the primary ``__init__``."""
        name = sanitize(_member_short(ctor.get("name", "")))
        param_meta = self._param_meta(ctor)
        params = [p.get("name", "") for p in param_meta]
        fields = self._all_field_names(short)
        field_inits = self._field_inits(short)
        initializers = (ctor.get("metadata", {}) or {}).get("initializers", []) or []
        init_fields = {i.get("name") for i in initializers if i.get("kind") == "field"}
        self.push_scope()
        self.enter_method_ctx(short)
        self.reserved = {"cls", "self", "_input"}
        self.line("@classmethod")
        self.line(f"def {name}(cls, _input=None):")
        with self.block():
            self.line("self = cls.__new__(cls)")
            self.emit_param_prologue(params)
            for p in param_meta:
                if p.get("is_this"):
                    self.line(f"self.{p.get('name')} = {sanitize(p.get('name'))}")
            for init in initializers:
                if init.get("kind") == "field":
                    self.line(f"self.{init.get('name')} = {self._lower_init(init.get('value'))}")
            for fld in fields:
                if fld in init_fields:
                    continue
                if any(p.get("name") == fld and p.get("is_this") for p in param_meta):
                    continue
                if fld in field_inits:
                    self.line(f"self.{fld} = {self._lower_init(field_inits[fld])}")
                else:
                    self.line(f"self.{fld} = None")
            self.emit_body(ctor, DISCARD_BODY=True)
            self.line("return self")
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

    def emit_accessor(self, short: str, m: dict, kind: str):
        """Emit a Dart getter/setter as a Python @property / @name.setter.

        A getter access is a `fieldAccess` (compiled to `getfield` -> getattr) and
        a setter write is `assign(fieldAccess)` (compiled to `setfield` -> setattr),
        so a @property/@setter is invoked transparently by those paths. Emitting the
        pair also resolves the two-`def`-same-name collision (the setter decorates
        the property object)."""
        name = sanitize(_member_short(m.get("name", "")))
        self.push_scope()
        self.enter_method_ctx(short)
        if kind == "getter":
            self.reserved = {"self"}
            self.line("@property")
            self.line(f"def {name}(self):")
            with self.block():
                self.emit_body(m)
        else:  # setter — one positional parameter (the assigned value)
            params = [p.get("name", "") for p in self._param_meta(m)]
            pname = params[0] if params else "value"
            py = sanitize(pname)
            self.reserved = {"self", py}
            self.scopes[-1][pname] = py  # bind the Ball param name to the positional
            self.line(f"@{name}.setter")
            self.line(f"def {name}(self, {py}):")
            with self.block():
                self.emit_body(m)
        self.line("")
        self.exit_method_ctx()
        self.pop_scope()

    def _inherited_fields(self, short: str) -> set[str]:
        """All fields visible in ``short``'s methods, including those inherited
        from user superclasses and the runtime ``BallMap`` base (``entries``)."""
        out: set[str] = set()
        cur = short
        seen: set[str] = set()
        while cur and cur not in seen:
            seen.add(cur)
            out.update(self._all_field_names(cur))
            sup = self.extends.get(cur)
            if sup == "BallMap":
                out.add("entries")
            cur = sup if (sup and sup in self.type_defs) else None
        return out

    def enter_method_ctx(self, short):
        self.in_method = True
        self.cur_class = short
        self.cur_fields = self._inherited_fields(short)

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

    def _param_decl(self, p: dict) -> str:
        """A positional constructor parameter declaration; an optional/named
        param defaults to None so a shorter constructor call still works."""
        name = sanitize(p.get("name", ""))
        if p.get("is_optional") or p.get("is_named") or p.get("has_default"):
            return f"{name}=None"
        return name

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
                    st = self.str_field(cf, "stack_trace")
                    if st:
                        pst = self.bind(st)
                        self.line(f"{pst} = ballrt.stack_trace_of(_ex)")
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
            obj = fa["object"]
            objref = obj.get("reference", {}).get("name", "") if isinstance(obj, dict) else ""
            if objref in _BUILTIN_TYPES:
                return self.builtin_static_field(objref, fa["field"])
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

    # Proto oneof "which"-case enums (protoc-dart names <Message>_<Oneof>). Their
    # values are the camelCase arm names that the ball_proto discriminators
    # return, so a single runtime object whose attribute access yields the
    # attribute name resolves all of them (`Expression_Expr.call` -> "call").
    _ARM_ENUMS = frozenset({
        "Expression_Expr", "Literal_Value", "Statement_Stmt",
        "ModuleImport_Source", "Value_Kind", "structpb.Value_Kind",
    })

    def reference(self, ref: dict) -> str:
        name = ref.get("name", "")
        if name == "input":
            return self.lookup("input") or "_input"
        # A `__no_init__` placeholder is the encoder's marker for a declared-but-
        # uninitialised (late / nullable) variable; it reads as null.
        if name == "__no_init__":
            return "None"
        if name in self._ARM_ENUMS or name == "io.FileMode":
            return "ballrt.arm"
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
        # A bare method name inside a method is a tear-off of `self`'s bound
        # method (e.g. `list.map(_toJsonSafe)`); Python's bound method carries the
        # receiver, so calling it with one element works.
        if self.in_method and sanitize(name) in self.all_method_names:
            return f"self.{sanitize(name)}"
        if name in _BUILTIN_TYPES:
            return f"ballrt.ty_{name}"
        sn = sanitize(name)
        if sn in self.top_var_names:
            return sn
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
        if tn:
            rc = self.runtime_construct(short, fields)
            if rc is not None:
                return rc
        # An anonymous / argument / record message → a plain dict.
        parts = [f"{pystr(fv.get('name', ''))}: {self.value(fv['value'])}" for fv in fields]
        return "{" + ", ".join(parts) + "}"

    # Constructions of runtime/stub types (ball_value wrappers, RegExp, …) that
    # are not emitted user classes. Returns None for an unrecognised type so the
    # caller falls back to an anonymous message.
    def runtime_construct(self, short: str, fields: list):
        # `type_args` is a cosmetic generic annotation, not a constructor arg.
        real = [fv for fv in fields if fv.get("name") != "type_args"]
        args = [self.value(fv["value"]) for fv in real]
        first = args[0] if args else "None"
        fdict = "{" + ", ".join(
            f"{pystr(fv.get('name', ''))}: {self.value(fv['value'])}" for fv in real) + "}"
        # ball_value.dart scalar/collection wrappers → the raw Python value, so a
        # wrapper never flows into arithmetic (the `is X || is BallX` guards in
        # the engine still match via the raw arm).
        wrappers = {
            "BallList": "ballrt.make_ball_list", "BallMap": "ballrt.make_ball_map",
            "BallDouble": "ballrt.make_ball_double", "BallInt": "ballrt.make_ball_int",
            "BallString": "ballrt.make_ball_string", "BallBool": "ballrt.make_ball_bool",
        }
        if short in wrappers:
            return f"{wrappers[short]}({first})"
        if short == "RegExp":
            return f"ballrt.make_regexp({fdict})"
        if short == "StringBuffer":
            return f"ballrt.make_string_buffer({first if args else ''})"
        if short == "StateError":
            return f"ballrt.make_state_error({first})"
        if short == "Duration":
            return f"ballrt.make_duration({fdict})"
        if short in ("LinkedHashMap", "Map"):
            return "{}"
        if short == "Object":
            return "object()"
        if short == "JsonEncoder":
            return "ballrt.make_json_encoder()"
        if short == "JsonDecoder":
            return "ballrt.make_json_decoder()"
        if short == "Map.from":
            return f"dict({first})"
        if short == "List.of":
            return f"list(ballrt.iterate({first}))"
        if short == "List.filled":
            return f"ballrt.list_filled({args[0]}, {args[1]})" if len(args) >= 2 else "[]"
        return None

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
        inp = call.get("input")
        mc = inp.get("messageCreation") if inp else None
        # A call carrying `self` in its input is a method call on the receiver.
        if mc is not None and any(fv.get("name") == "self" for fv in mc.get("fields", [])):
            self_expr = "None"
            self_raw = None
            rest = []
            for fv in mc.get("fields", []):
                if fv.get("name") == "self":
                    self_raw = fv["value"]
                    self_expr = self.value(fv["value"])
                else:
                    rest.append(fv)
            # A static call on a builtin type (int.tryParse, List.filled, …):
            # route to a dedicated runtime helper with cleanly-extracted args.
            sr = self_raw.get("reference", {}).get("name", "") if isinstance(self_raw, dict) else ""
            if sr in _BUILTIN_TYPES:
                return self.builtin_static(sr, fn, rest)
            method = sanitize(fn)
            # A static / named-constructor call on the class itself
            # (`StdModuleHandler.subset(x)`), not an instance method.
            if sr in self.type_defs and not self.lookup(sr):
                if not rest:
                    return f"{sanitize(sr)}.{method}()"
                if len(rest) == 1:
                    return f"{sanitize(sr)}.{method}({self.value(rest[0]['value'])})"
                packed = "{" + ", ".join(
                    f"{pystr(fv.get('name', ''))}: {self.value(fv['value'])}" for fv in rest) + "}"
                return f"{sanitize(sr)}.{method}({packed})"
            # A Dart-SDK method on a value (not a user method): route to the
            # runtime dispatcher, which applies Dart (not Python) semantics on a
            # builtin receiver and calls a runtime/user object's own method
            # otherwise. User-method and SDK-method names never collide here.
            # Universally-overridable methods (toString/hashCode/…) also route
            # through the dispatcher even though a user class declares them, since
            # the receiver may be a builtin at run time.
            if method not in self.all_method_names or fn in _UNIVERSAL_METHODS:
                sdk_args = ", ".join(self.value(fv["value"]) for fv in rest)
                sep = ", " if rest else ""
                return f"ballrt.call_method({self_expr}, {pystr(fn)}{sep}{sdk_args})"
            if not rest:
                return f"{self_expr}.{method}()"
            if len(rest) == 1:
                return f"{self_expr}.{method}({self.value(rest[0]['value'])})"
            packed = "{" + ", ".join(
                f"{pystr(fv.get('name', ''))}: {self.value(fv['value'])}" for fv in rest) + "}"
            return f"{self_expr}.{method}({packed})"
        # External (stub-module) calls we bridge to the runtime (dart.math, …).
        if mod in self.stub_modules:
            return self.stub_call(mod, fn, inp)
        # A bare local holding a first-class function value.
        if self.lookup(fn):
            return f"ballrt.call_fn({self.lookup(fn)}, {self.value(inp) if inp else 'None'})"
        name = sanitize(fn)
        argstr = self.value(inp) if inp else "None"
        module_less = not mod or mod == self.prog.get("entryModule")
        # `identical(a, b)` — Dart reference identity (a top-level function).
        if module_less and fn == "identical":
            a = self._call_args(inp)
            return f"ballrt.identical({a[0] if a else 'None'}, {a[1] if len(a) > 1 else 'None'})"
        # An implicit call of a function-typed field (`stdout(line)` inside a
        # method): apply the field's stored callable.
        if self.in_method and module_less and name in self.cur_fields:
            return f"ballrt.call_fn(self.{name}, {argstr})"
        # An implicit-`self` method call: inside a method, module-less, and the
        # function is a known (own-or-inherited) method — Python dispatches it.
        # (Method and free-function names do not collide in the engine.)
        if self.in_method and module_less and name in self.all_method_names:
            return f"self.{name}({argstr})"
        if name in self.user_funcs:
            return f"{name}({argstr})"
        # Unknown callee: fail loud (issue #55).
        self.errors.append(f"unknown call target {mod}.{fn}")
        return f"{name}({argstr})"

    def _call_args(self, inp) -> list[str]:
        """Positional argument expressions of a call input (invariant #1):
        a bare value is a single argument; an anonymous message is unpacked in
        field order."""
        if not inp:
            return []
        mc = inp.get("messageCreation")
        if mc is not None and not mc.get("typeName"):
            return [self.value(fv["value"]) for fv in mc.get("fields", [])]
        return [self.value(inp)]

    def stub_call(self, mod: str, fn: str, inp) -> str:
        """Bridge a call into a stubbed external module to the runtime.

        Only the surface the self-hosted engine actually reaches is mapped
        (``dart.math`` transcendentals, ``dart.io`` file/dir ops); anything else
        is a loud runtime raise (never silent-wrong)."""
        args = self._call_args(inp)
        if mod == "dart.math":
            two = {"pow", "atan2"}
            if fn in two and len(args) >= 2:
                return f"ballrt.dm.{fn}({args[0]}, {args[1]})"
            if args:
                return f"ballrt.dm.{fn}({args[0]})"
            return f"ballrt.dm.{fn}()"
        if mod == "dart.io":
            return f"ballrt.io_stub({pystr(fn)}, [{', '.join(args)}])"
        # A stub module we do not bridge: raise at run time, not compile time —
        # the library still compiles (the path may be unreachable in a fixture).
        return f"ballrt.throw({pystr('unsupported external call ' + mod + '.' + fn)})"

    # Static members of Dart builtin types, mapped to runtime helpers.
    _BUILTIN_STATIC = {
        "int.tryParse": "ballrt.int_try_parse", "int.parse": "ballrt.int_parse",
        "num.parse": "ballrt.num_parse", "num.tryParse": "ballrt.num_try_parse",
        "double.parse": "ballrt.double_parse", "double.tryParse": "ballrt.double_try_parse",
        "String.fromCharCode": "ballrt.string_from_char_code",
        "String.fromCharCodes": "ballrt.string_from_char_codes",
        "List.filled": "ballrt.list_filled", "List.generate": "ballrt.list_generate",
        "Map.unmodifiable": "ballrt.map_unmodifiable", "Set.unmodifiable": "ballrt.set_unmodifiable",
        "Function.apply": "ballrt.function_apply",
        "DateTime.now": "ballrt.datetime_now", "DateTime.parse": "ballrt.datetime_parse",
        "DateTime.fromMillisecondsSinceEpoch": "ballrt.datetime_from_ms",
    }

    def builtin_static(self, typ: str, method: str, rest: list) -> str:
        """A static call on a Dart builtin type (int.tryParse, List.filled …)."""
        args = [self.value(fv["value"]) for fv in rest]
        helper = self._BUILTIN_STATIC.get(f"{typ}.{method}")
        if helper is None:
            # A rarely-reached static (async/File …): raise at run time so the
            # library still compiles; never a silent-wrong result (issue #55).
            return f"ballrt.throw({pystr('unsupported static ' + typ + '.' + method)})"
        return f"{helper}({', '.join(args)})"

    def builtin_static_field(self, typ: str, field: str) -> str:
        """A static constant of a Dart builtin type (double.infinity/nan …)."""
        table = {
            "double.infinity": "ballrt.double_infinity",
            "double.negativeInfinity": "ballrt.double_negative_infinity",
            "double.nan": "ballrt.double_nan",
            "double.maxFinite": "ballrt.double_max_finite",
            "double.minPositive": "ballrt.double_min_positive",
        }
        val = table.get(f"{typ}.{field}")
        if val is None:
            return f"ballrt.throw({pystr('unsupported static field ' + typ + '.' + field)})"
        return val

    # ── Base-function dispatch (pure expressions) ────────────────────────────

    def base_expr(self, call: dict) -> str:
        mod, fn = call.get("module", ""), call.get("function", "")
        f = self.fields(call)
        if mod == "std_collections":
            return self.collections_expr(fn, f)
        if mod == "ball_proto":
            return f"ballrt.proto.{fn}({self.value_field(f, 'obj', 'value')})"
        if mod == "std_convert":
            return self.convert_expr(fn, f)

        def a(*names):
            return self.value_field(f, *names)

        # Type test / cast (is / is! / as). The `type` field is a string literal.
        if fn in ("is", "is_not", "as"):
            val = a("value")
            typ = self.str_field(f, "type")
            if fn == "is":
                return f"ballrt.is_type({val}, {pystr(typ)})"
            if fn == "is_not":
                return f"(not ballrt.is_type({val}, {pystr(typ)}))"
            return f"ballrt.as_type({val}, {pystr(typ)})"

        # Collection literals routed through std (map/set literals, typed lists).
        if fn == "map_create":
            return self.map_create(call)
        if fn == "set_create":
            if any(k in f for k in ("list", "elements", "set")):
                return f"ballrt.col.set_create({self.value_field(f, 'list', 'elements', 'set')})"
            return "ballrt.col.set_create(None)"
        if fn == "typed_list":
            el = f.get("elements")
            if isinstance(el, dict) and "literal" in el and "listValue" in el["literal"]:
                return self.list_literal(el["literal"]["listValue"])
            if el is not None:
                return self.value(el)
            return "[]"

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
        if fn == "math_clamp":
            return f"ballrt.math_clamp({V()}, {a('lower', 'lowerLimit', 'min', 'low')}, {a('upper', 'upperLimit', 'max', 'high')})"
        if fn == "math_gcd":
            return f"ballrt.math_gcd({a('left', 'value')}, {a('right', 'other')})"
        if fn in ("round_to_double", "floor_to_double", "ceil_to_double", "truncate_to_double"):
            return f"ballrt.{fn}({V()})"
        if fn == "string_runes":
            return f"ballrt.string_runes({V()})"
        if fn == "math_is_finite":
            return f"ballrt.math_is_finite({V()})"
        if fn == "math_is_infinite":
            return f"ballrt.math_is_infinite({V()})"
        if fn == "string_pad_left":
            pad = a("padding", "pad", "char") if any(k in f for k in ("padding", "pad", "char")) else pystr(" ")
            return f"ballrt.string_pad_left({a('value', 'left')}, {a('width', 'length', 'count')}, {pad})"
        if fn == "string_pad_right":
            pad = a("padding", "pad", "char") if any(k in f for k in ("padding", "pad", "char")) else pystr(" ")
            return f"ballrt.string_pad_right({a('value', 'left')}, {a('width', 'length', 'count')}, {pad})"

        return self.fail(f"unsupported base function {mod}.{fn}")

    def map_create(self, call: dict) -> str:
        """A map literal (``{k: v, …}`` / ``<K,V>{}``). The entries are repeated
        ``entry`` fields (each a ``{key, value}`` message) on the ``map_create``
        input — read from the raw field list, since same-named fields collapse in
        the flattened ``fields()`` view. ``<K,V>{}`` has no ``entry`` → ``{}``."""
        inp = call.get("input") or {}
        mc = inp.get("messageCreation") or {}
        pairs = []
        for fv in mc.get("fields", []):
            if fv.get("name") != "entry":
                continue
            ev = fv.get("value") or {}
            ef = self.mc_fields(ev.get("messageCreation", {})) if "messageCreation" in ev else {}
            if "key" in ef and "value" in ef:
                pairs.append(f"{self.value(ef['key'])}: {self.value(ef['value'])}")
        return "{" + ", ".join(pairs) + "}"

    def convert_expr(self, fn: str, f: dict) -> str:
        val = self.value_field(f, "value", "input", "bytes", "string")
        table = {
            "utf8_encode": "utf8_encode", "utf8_decode": "utf8_decode",
            "base64_encode": "base64_encode", "base64_decode": "base64_decode",
            "json_encode": "json_encode", "json_decode": "json_decode",
        }
        if fn in table:
            return f"ballrt.cvt.{table[fn]}({val})"
        return self.fail(f"unsupported base function std_convert.{fn}")

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
        target = f["target"]
        # Null-aware index assignment (`a?[k] = v`): a no-op when the receiver is
        # null, and the value is not evaluated in that case (Dart short-circuit).
        tk = _which(target)
        if tk == "call" and target["call"].get("function") == "null_aware_index":
            tf = self.fields(target["call"])
            recv = self.value_field(tf, "target", "value", "object")
            tmp = self.newtemp()
            self.line(f"{tmp} = {recv}")
            self.line(f"if {tmp} is not None:")
            with self.block():
                key = self.value_field(tf, "index", "key")
                val = self.value(f["value"])
                combined = self.combine_op(op, f"ballrt.index_get({tmp}, {key})", val)
                self.line(f"ballrt.index_set({tmp}, {key}, {combined})")
            return "None"
        lv = self.lvalue(target)
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


def compile_library(program: dict) -> str:
    """Compile ``program`` as an importable Python library (see
    :meth:`Compiler.compile_library`) — used by the self-hosted engine regen."""
    return Compiler(program).compile_library()
