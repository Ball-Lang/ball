using System.Text;
using Ball.Shared;
using Ball.V1;
using Google.Protobuf.WellKnownTypes;

namespace Ball.Compiler;

/// <summary>
/// Compiles a Ball <see cref="Program"/> into a single, runnable C# source
/// file (issue #381, playbook Phase 2). The C# analog of
/// <c>rust/compiler/src/lib.rs</c> (the closest sibling — string emission,
/// base-call dispatch delegating to a shared runtime helper layer) and
/// <c>dart/compiler/lib/compiler.dart</c> (the canonical base-function
/// dispatch inventory).
///
/// <para><b>Every compiled expression evaluates to a
/// <see cref="BallValue"/></b> — there are no "void" positions. Base-function
/// calls dispatch to <see cref="BallRuntime"/> (arithmetic/comparison/…) or
/// are lowered to native C# (the lazy control-flow constructs); user calls
/// compile to a direct method call or, for a first-class function value held
/// in a local, to <see cref="BallRuntime.CallFunction"/>.</para>
///
/// <para><b>Block-lowering strategy (the C#-specific decision, issue #381).</b>
/// Unlike Rust, C#'s <c>if</c>/<c>for</c>/<c>while</c>/<c>foreach</c>/
/// <c>switch</c>/<c>try</c> and <c>{ … }</c> blocks are <em>statements</em>,
/// not expressions. The compiler therefore has two lowering contexts:
/// <list type="bullet">
/// <item><b>Statement context</b> (<see cref="EmitBlockInner"/> /
/// <see cref="EmitStatement"/>) — used for function bodies and every block
/// statement. Control flow lowers to the <em>native</em> C# statement
/// (<c>if</c>/<c>for</c>/<c>while</c>/<c>foreach</c>/<c>switch</c>/<c>try</c>),
/// and <c>return</c>/<c>break</c>/<c>continue</c> to the real C# keyword — so a
/// compiled program reads almost exactly like its Dart source, and (crucially)
/// a <c>return</c> inside an <c>if</c>-branch returns from the enclosing
/// function, which a pure-IIFE lowering would get wrong.</item>
/// <item><b>Expression context</b> (<see cref="CompileExpression"/>) — used
/// wherever a value is required (a call argument, a <c>let</c> right-hand
/// side, a nested condition). An <c>if</c> becomes a C# ternary; a block or a
/// loop that lands here is wrapped in a <c>Func&lt;BallValue&gt;</c> IIFE
/// (<c>Run(() =&gt; { … })</c>), the C++ precedent — but confined to that
/// narrow case rather than used everywhere.</item>
/// </list>
/// Rejected alternatives: pure-IIFE-everywhere (unreadable, and mis-scopes
/// <c>return</c>); full statement-lowering with temp-var spilling (most
/// readable, but needs an ANF pass — disproportionate for Phase 4).</para>
///
/// <para><b>Output layout:</b> a single file. The entry module's functions
/// become <c>static</c> methods on one <c>BallProgram</c> class; every other
/// user module becomes its own nested <c>static class</c>; base modules
/// (<c>std</c>, …) emit nothing — they <em>are</em> <see cref="BallRuntime"/>.</para>
/// </summary>
public sealed partial class CSharpCompiler
{
    private readonly Program _program;
    private readonly string _entryModule;
    private readonly HashSet<string> _baseModules = new(StringComparer.Ordinal);
    private readonly HashSet<string> _userModuleNames = new(StringComparer.Ordinal);

    /// <summary>
    /// Import-only "stub" modules — declared in the program but carrying no
    /// functions, types, or enums (e.g. <c>dart.math</c>/<c>dart.io</c>/
    /// <c>protobuf</c>, the external libraries the self-host source imports). A
    /// call into one is an unimplemented external base function; route it to a
    /// fail-loud <see cref="BallRuntime.UnsupportedBaseCall"/> rather than an
    /// empty phantom class (which would not compile).
    /// </summary>
    private readonly HashSet<string> _stubModules = new(StringComparer.Ordinal);

    /// <summary>Sanitized names of every callable top-level function / method short name (direct-call targets).</summary>
    private readonly HashSet<string> _callableNames = new(StringComparer.Ordinal);

    /// <summary>Sanitized short names of every instance method — the implicit-<c>this</c> injection targets (issue #383).</summary>
    private readonly HashSet<string> _instanceMethodNames = new(StringComparer.Ordinal);

    /// <summary>Sanitized names of top-level variables/getters (a bare reference invokes the nullary getter, not a function-value tear-off).</summary>
    private readonly HashSet<string> _topLevelVars = new(StringComparer.Ordinal);

    /// <summary>Whether the body currently being compiled is an instance method/constructor (so a bare <c>this.method()</c> call injects the receiver).</summary>
    private bool _inInstanceMethod;

    /// <summary>The C# local holding the current receiver, for implicit-<c>this</c> injection (survives a same-named <c>self</c> parameter shadowing).</summary>
    private string? _selfRecvName;

    /// <summary>
    /// Instance fields of the current method's owner that are <em>reassigned</em>
    /// (a bare <c>field = x</c> rebind) somewhere in the class, and so must be read
    /// and written <em>live</em> through <c>self</c> rather than via a method-entry
    /// alias snapshot. The entry-alias optimization (read each field into a local
    /// once, at method entry) is a read-time snapshot: sound for read-only or
    /// mutate-through-a-shared-backing fields, but wrong for a field that is
    /// rebound and observed across method/closure boundaries mid-run — e.g. the
    /// engine's <c>_activeException</c>, set by <c>_evalLazyTry</c>'s catch handler
    /// and read by the separate <c>rethrow</c> dispatch closure (issue #383). For
    /// a volatile field, references compile to <c>FieldGet(self, name)</c> and
    /// assignments to <c>FieldSet(self, name, …)</c>, matching Dart's implicit-this.
    /// </summary>
    private HashSet<string> _volatileFields = new(StringComparer.Ordinal);

    /// <summary>Per-owner cache of <see cref="_volatileFields"/> (keyed by the owner <see cref="TypeDefinition.Name"/>).</summary>
    private readonly Dictionary<string, HashSet<string>> _volatileFieldsByOwner = new(StringComparer.Ordinal);

    /// <summary>Class members (constructors/methods) grouped by their owner <see cref="TypeDefinition.Name"/>.</summary>
    private readonly Dictionary<string, List<FunctionDefinition>> _classMembersByOwner = new(StringComparer.Ordinal);

    /// <summary>Every user <see cref="TypeDefinition"/> keyed by short name (for constructor-argument remapping).</summary>
    private readonly Dictionary<string, TypeDefinition> _typeDefsByShortName = new(StringComparer.Ordinal);

    /// <summary>
    /// Lexical scope stack. Each frame maps a Ball local's sanitized name to the
    /// C# identifier it is actually emitted as. They usually match, but when a
    /// binding would shadow a name already visible in an enclosing scope — legal
    /// in Dart, a CS0136/CS0128 error in C# — it is emitted under a unique alias
    /// and references resolve through this map (see <see cref="BindLocal"/> /
    /// <see cref="LocalName"/>).
    /// </summary>
    private readonly List<Dictionary<string, string>> _localScopes = new();

    /// <summary>Monotonic counter for globally-unique local aliases (<c>name__L0</c>, …).</summary>
    private int _shadowCounter;

    /// <summary>Monotonic counter for compiler-internal temporaries emitted into a block (e.g. a switch subject).</summary>
    private int _tempCounter;

    /// <summary>
    /// Stack of synthesized C# parameter names for the enclosing
    /// function/method/lambda scopes. Every Ball function's single parameter is
    /// <c>reference("input")</c> (invariant #1); the emitted C# parameter can NOT
    /// literally be <c>input</c>, because (a) a Ball function may itself declare
    /// a parameter/field named <c>input</c> (e.g. the engine's
    /// <c>_callFunction(module, function, input)</c>) — colliding with the C#
    /// parameter — and (b) C# forbids a nested lambda from re-declaring a
    /// parameter named <c>input</c> that an enclosing scope already uses (unlike
    /// Dart, which allows shadowing). Each scope therefore gets a unique
    /// <c>__in{n}</c> name, and <see cref="CompileReference"/> resolves
    /// <c>"input"</c> to the innermost one.
    /// </summary>
    private readonly List<string> _inputNames = new();

    private int _inputCounter;

    private string _currentModule;

    private CSharpCompiler(Program program)
    {
        _program = program;
        _entryModule = program.EntryModule;
        _currentModule = program.EntryModule;

        foreach (var module in program.Modules)
        {
            var allBase = module.Functions.Count > 0 && module.Functions.All(f => f.IsBase);
            if (allBase)
            {
                _baseModules.Add(module.Name);
            }
            else if (module.Functions.Count == 0 && module.TypeDefs.Count == 0 && module.Enums.Count == 0)
            {
                _stubModules.Add(module.Name);
            }
        }

        foreach (var module in program.Modules)
        {
            if (_baseModules.Contains(module.Name))
            {
                continue;
            }

            _userModuleNames.Add(module.Name);

            foreach (var td in module.TypeDefs)
            {
                _typeDefsByShortName[Naming.TypeShortName(td.Name)] = td;
            }

            foreach (var func in module.Functions)
            {
                if (func.IsBase)
                {
                    continue;
                }

                if (Naming.SplitMemberName(func.Name) is { } member)
                {
                    _classMembersByOwner.TryAdd(member.Owner, new List<FunctionDefinition>());
                    _classMembersByOwner[member.Owner].Add(func);
                    _callableNames.Add(Naming.Sanitize(member.Member));

                    // An instance method (not a constructor, not static) is an
                    // implicit-`this` injection target: a bare call to it from
                    // inside an instance method injects the receiver.
                    if (MetaString(func.Metadata, "kind") != "constructor" && !MetaBool(func.Metadata, "is_static"))
                    {
                        _instanceMethodNames.Add(Naming.Sanitize(member.Member));
                    }
                }
                else
                {
                    _callableNames.Add(Naming.Sanitize(func.Name));
                    if (MetaString(func.Metadata, "kind") == "top_level_variable")
                    {
                        _topLevelVars.Add(Naming.Sanitize(func.Name));
                    }
                }
            }
        }

        IndexConstructors();
    }

    /// <summary>Compile <paramref name="program"/> into a complete C# source file.</summary>
    public static string Compile(Program program) => new CSharpCompiler(program).CompileProgram();

    private string CompileProgram()
    {
        var sb = new StringBuilder();
        sb.Append("// <auto-generated> Ball -> C# compiler (issue #381).\n");
        sb.Append($"// Source: {_program.Name} v{_program.Version}\n");
        sb.Append("#nullable enable\n");
        sb.Append("using System;\n");
        sb.Append("using System.Collections.Generic;\n");
        sb.Append("using Ball.Shared;\n");
        sb.Append("using static Ball.Shared.BallValue;\n\n");

        sb.Append("internal static class BallProgram\n{\n");

        // A tiny IIFE helper — the C# stand-in for Rust's block-expression /
        // C++'s immediately-invoked lambda. Only reached when a block or a
        // control-flow construct lands in true value position (see the class
        // doc comment); the common statement path never uses it.
        sb.Append("    private static BallValue Run(Func<BallValue> body) => body();\n\n");

        // The entry module's types and functions live directly on BallProgram.
        var entry = _program.Modules.FirstOrDefault(m => m.Name == _entryModule)
            ?? throw new InvalidOperationException($"Entry module \"{_entryModule}\" not found");
        sb.Append(CompileModuleBody(entry));

        // The C# entry point: run the Ball entry function's body. Emitted as a
        // thin wrapper that calls the compiled entry function (which handles a
        // top-level `return` naturally), so `void main()`'s `return;` and a
        // value-returning entry both work.
        var entryFunc = entry.Functions.FirstOrDefault(f => f.Name == _program.EntryFunction);
        if (entryFunc is not null)
        {
            sb.Append("\n    public static void Main(string[] args)\n    {\n");
            sb.Append($"        {Naming.Sanitize(entryFunc.Name)}(BallValue.Null);\n");
            sb.Append("    }\n");
        }

        sb.Append("}\n");

        // Every other user module → its own nested static class.
        foreach (var module in _program.Modules)
        {
            if (module.Name == _entryModule
                || _baseModules.Contains(module.Name)
                || _stubModules.Contains(module.Name))
            {
                continue;
            }

            var body = CompileModuleBody(module);
            sb.Append($"\ninternal static class {Naming.Sanitize(module.Name)}\n{{\n");
            sb.Append(body);
            sb.Append("}\n");
        }

        // The synthesized oneof-discriminator constants (Expression_Expr, …) the
        // engine's AST dispatch reads — top-level so every module sees them.
        sb.Append(CompileOneofDiscriminators());

        return sb.ToString();
    }

    /// <summary>Compile one module's types + standalone (non-base, non-class-member) functions.</summary>
    private string CompileModuleBody(Module module)
    {
        _currentModule = module.Name;
        var sb = new StringBuilder();

        sb.Append(CompileModuleTypes(module));

        foreach (var func in module.Functions)
        {
            if (func.IsBase || Naming.SplitMemberName(func.Name) is not null)
            {
                continue;
            }

            sb.Append(CompileFunction(func));
            sb.Append('\n');
        }

        return sb.ToString();
    }

    /// <summary>Compile a standalone function: <c>static BallValue name(BallValue input) { … }</c> (invariant #1).</summary>
    private string CompileFunction(FunctionDefinition func)
    {
        var name = Naming.Sanitize(func.Name);
        var inName = PushInput();
        var body = EmitFunctionBody(func);
        PopInput();
        return $"    public static BallValue {name}(BallValue {inName})\n    {body}\n";
    }

    /// <summary>
    /// Emit a function/method/lambda body as a braced statement block ending in
    /// a <c>return</c>. The caller must have opened the input scope
    /// (<see cref="PushInput"/>) so <see cref="CurrentInput"/> is this body's
    /// parameter.
    /// </summary>
    private string EmitFunctionBody(FunctionDefinition func)
    {
        PushScope();
        var sb = new StringBuilder("{\n");
        sb.Append(ParamPrologue(func));

        if (func.Body is null)
        {
            sb.Append("return BallValue.Null;\n");
        }
        else if (func.Body.ExprCase == Expression.ExprOneofCase.Block)
        {
            sb.Append(EmitBlockInner(func.Body.Block, isFunctionBody: true));
        }
        else
        {
            sb.Append($"return {CompileExpression(func.Body)};\n");
        }

        sb.Append('}');
        PopScope();
        return sb.ToString();
    }

    /// <summary>
    /// The <c>let</c>-bindings a function/lambda body needs to resolve its
    /// declared parameter names. A single parameter is bound directly to
    /// <c>input</c> (the common <c>fibonacci</c>-style shape); multiple
    /// parameters are destructured out of the input message by name.
    /// </summary>
    private string ParamPrologue(FunctionDefinition func)
    {
        var names = ParamNames(func);
        if (names.Count == 0)
        {
            return string.Empty;
        }

        var sb = new StringBuilder();
        if (names.Count == 1)
        {
            sb.Append($"var {BindLocal(names[0])} = {CurrentInput};\n");
        }
        else
        {
            // Bind each parameter name-or-positionally (the same convention the
            // instance/static-method and constructor prologues use): a call site
            // that knows the callee's names packs `{name: …}`, but a first-class
            // invoke of a function *value* (`op(x, y)` where `op` is a local, e.g.
            // `_stdBinaryComp`'s `op(left, right)`) has no names to pack and emits
            // positional `{arg0, arg1}`. FieldGet-by-name-only silently dropped the
            // positional case (null operands); ArgGet tries the name, then `argN`.
            var positional = 0;
            foreach (var name in names)
            {
                var argKey = Naming.StringLiteral($"arg{positional}");
                positional++;
                sb.Append($"var {BindLocal(name)} = BallRuntime.ArgGet({CurrentInput}, {Naming.StringLiteral(name)}, {argKey});\n");
            }
        }

        return sb.ToString();
    }

    // ════════════════════════════════════════════════════════════
    // Statement context
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// Emit a block's statements (without the enclosing braces). When
    /// <paramref name="isFunctionBody"/>, the block's <c>result</c> becomes the
    /// function's <c>return</c>; otherwise (a nested statement-position block)
    /// the result is evaluated for its side effects and discarded.
    /// </summary>
    private string EmitBlockInner(Block block, bool isFunctionBody)
    {
        PushScope();
        var sb = new StringBuilder();

        foreach (var statement in block.Statements)
        {
            switch (statement.StmtCase)
            {
                case Statement.StmtOneofCase.Let:
                    var let = statement.Let;
                    // Compile the initializer BEFORE binding the name so a
                    // `let x = <expr using outer x>` resolves to the outer binding.
                    var value = let.Value is null ? "BallValue.Null" : CompileExpression(let.Value);
                    sb.Append($"var {BindLocal(let.Name)} = {value};\n");
                    break;
                case Statement.StmtOneofCase.Expression:
                    sb.Append(EmitStatement(statement.Expression));
                    sb.Append('\n');
                    break;
            }
        }

        if (isFunctionBody)
        {
            sb.Append(block.Result is null
                ? "return BallValue.Null;\n"
                : $"return {CompileExpression(block.Result)};\n");
        }
        else if (block.Result is not null)
        {
            sb.Append(EmitStatement(block.Result));
            sb.Append('\n');
        }

        PopScope();
        return sb.ToString();
    }

    /// <summary>
    /// Emit an expression appearing in statement position (its value
    /// discarded). Control-flow base calls lower to native C# statements
    /// (<see cref="EmitBaseStatement"/>); every other expression is a plain
    /// expression statement.
    /// </summary>
    private string EmitStatement(Expression expr)
    {
        switch (expr.ExprCase)
        {
            case Expression.ExprOneofCase.Block:
                return "{\n" + EmitBlockInner(expr.Block, isFunctionBody: false) + "}";
            case Expression.ExprOneofCase.Call:
                var call = expr.Call;
                if (_baseModules.Contains(call.Module))
                {
                    var native = EmitBaseStatement(call);
                    if (native is not null)
                    {
                        return native;
                    }
                }

                // A value-yielding call in statement position, discarded. `_ = `
                // makes it a valid statement for every shape — a plain call
                // (`print(x)`) would be legal alone, but an identity-leaf base
                // call (`await`/`paren`/`spread`) reduces to a bare value (a
                // reference/literal) that is not a legal C# statement (CS0201).
                return "_ = " + CompileExpression(expr) + ";";
            case Expression.ExprOneofCase.None:
                return ";";
            default:
                // A bare reference/literal/etc. in statement position: discard.
                return "_ = " + CompileExpression(expr) + ";";
        }
    }

    // ════════════════════════════════════════════════════════════
    // Expression context — the 7 node types
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// Emit an expression in statement position, but with a <c>block</c>
    /// <em>unwrapped</em> to its bare inner statements (no braces) — for use
    /// where the caller already supplies the enclosing <c>{ }</c> (an
    /// <c>if</c>/loop/<c>catch</c> branch), so a block branch does not produce a
    /// redundant second brace pair.
    /// </summary>
    private string EmitStatementUnwrapped(Expression expr) =>
        expr.ExprCase == Expression.ExprOneofCase.Block
            ? EmitBlockInner(expr.Block, isFunctionBody: false)
            : EmitStatement(expr);

    /// <summary>Compile any <see cref="Expression"/> to a C# expression evaluating to a <see cref="BallValue"/>.</summary>
    private string CompileExpression(Expression expr) => expr.ExprCase switch
    {
        Expression.ExprOneofCase.Call => CompileCall(expr.Call),
        Expression.ExprOneofCase.Literal => CompileLiteral(expr.Literal),
        Expression.ExprOneofCase.Reference => CompileReference(expr.Reference),
        Expression.ExprOneofCase.FieldAccess => CompileFieldAccess(expr.FieldAccess),
        Expression.ExprOneofCase.MessageCreation => CompileMessageCreation(expr.MessageCreation),
        Expression.ExprOneofCase.Block => CompileBlockExpression(expr.Block),
        Expression.ExprOneofCase.Lambda => CompileLambda(expr.Lambda),
        _ => "BallValue.Null",
    };

    /// <summary><c>literal</c> — emit a <see cref="BallValue"/> constructor.</summary>
    private string CompileLiteral(Literal lit) => lit.ValueCase switch
    {
        Literal.ValueOneofCase.IntValue => $"Int({Naming.IntLiteral(lit.IntValue)})",
        Literal.ValueOneofCase.DoubleValue => $"Double({Naming.DoubleLiteral(lit.DoubleValue)})",
        Literal.ValueOneofCase.StringValue => $"Str({Naming.StringLiteral(lit.StringValue)})",
        Literal.ValueOneofCase.BoolValue => $"Bool({(lit.BoolValue ? "true" : "false")})",
        Literal.ValueOneofCase.BytesValue => CompileBytesLiteral(lit.BytesValue.ToByteArray()),
        Literal.ValueOneofCase.ListValue => CompileListLiteral(lit.ListValue),
        _ => "BallValue.Null",
    };

    private static string CompileBytesLiteral(byte[] bytes)
    {
        var items = string.Join(", ", bytes.Select(b => b.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        return $"Bytes(new byte[] {{ {items} }})";
    }

    /// <summary>A list literal builds a fresh reference-semantic backing (a distinct list per evaluation).</summary>
    private string CompileListLiteral(ListLiteral list)
    {
        if (list.Elements.Count == 0)
        {
            return "(BallValue)new BallList()";
        }

        var items = string.Join(", ", list.Elements.Select(CompileExpression));
        return $"(BallValue)new BallList(new BallValue[] {{ {items} }})";
    }

    /// <summary>
    /// <c>reference</c> — an identifier read. <c>"input"</c> is the current
    /// function's single parameter (invariant #1). An unshadowed reference to a
    /// known top-level function used as a value is wrapped as a
    /// <see cref="BallFunction"/> so a method group flows as a first-class
    /// value.
    /// </summary>
    private string CompileReference(Reference reference)
    {
        if (reference.Name == "input")
        {
            // A function whose *declared* parameter is literally named `input`
            // (e.g. the engine's `_stdPrint(input)`) binds it to its own local via
            // the param prologue — for an instance method that is
            // `ArgGet(__in, "input", "arg0")`, the extracted argument, NOT the raw
            // `{self, arg0}` wrapper `CurrentInput` points at. Resolve through the
            // bound local when present; only an implicit, unnamed single parameter
            // (no `input` local) falls back to the raw input parameter.
            return LocalName("input") ?? CurrentInput;
        }

        // The encoders' shared sentinel for an uninitialized late/nullable
        // local (`int? maybe;`): a read of the still-unassigned variable is null.
        if (reference.Name == "__no_init__")
        {
            return "BallValue.Null";
        }

        // A bound local resolves first (it shadows a namesake type/callable/
        // discriminator), through its possibly-renamed emitted identifier.
        if (LocalName(reference.Name) is { } local)
        {
            return local;
        }

        // A reassigned ("volatile") instance field is read LIVE through the
        // receiver — it is deliberately not aliased into a method-entry local (a
        // stale snapshot), so a rebind by one method/closure is observed by
        // another mid-run (issue #383 — `rethrow` reads `_activeException` set by
        // the catch handler). Non-volatile fields keep their fast alias local.
        if (_inInstanceMethod && _selfRecvName is { } selfRead && _volatileFields.Contains(reference.Name))
        {
            return $"BallRuntime.FieldGet({selfRead}, {Naming.StringLiteral(reference.Name)})";
        }

        // A oneof-discriminator constant (Expression_Expr.call, …) — proto
        // codegen's synthesized enums, referenced by the engine's dispatch but
        // carrying no EnumDescriptorProto; resolve to the emitted namespace.
        if (OneofDiscriminators.ContainsKey(reference.Name))
        {
            return $"BallOneofs.{Naming.Sanitize(reference.Name)}";
        }

        // A bare reference to a Dart core type name (num/int/DateTime/…), used as
        // a static-method receiver (int.tryParse) or a type argument — emit a
        // TypeLiteral marker so it is a valid dispatchable value. Guarded against
        // a user type of the same short name.
        if (BuiltinTypeNames.Contains(reference.Name)
            && !_typeDefsByShortName.ContainsKey(reference.Name))
        {
            return $"BallRuntime.TypeLiteral({Naming.StringLiteral(reference.Name)})";
        }

        var name = Naming.Sanitize(reference.Name);

        // A bare reference to a top-level variable/getter is a getter invocation
        // (read its value), not a function-value tear-off — `value.length *
        // _ballStringCodeUnitBytes` reads the constant, not the fn.
        if (_topLevelVars.Contains(name))
        {
            return $"{name}(BallValue.Null)";
        }

        // A bare reference to an instance method from inside an instance method
        // body is a BOUND method tear-off (`{'print': _stdPrint}` in the engine's
        // _buildStdDispatch) — Dart binds `this`. The dispatcher reads its
        // receiver from the input's `self`, so the tear-off must weave the
        // enclosing receiver into whatever argument the value is later called with
        // (issue #383) — otherwise the handler runs with no receiver and its
        // `this.stdout(...)` goes nowhere.
        if (_inInstanceMethod && _instanceMethodNames.Contains(name))
        {
            var self = _selfRecvName ?? "self";
            return $"(BallValue)new BallFunction({Naming.StringLiteral(reference.Name)}, (BallValue __arg) => {name}(BallRuntime.Arg0WithSelf(__arg, {self})))";
        }

        if (_callableNames.Contains(name))
        {
            return $"new BallFunction({Naming.StringLiteral(reference.Name)}, {name})";
        }

        // A name that is none of the above resolves to nothing the compiler can
        // emit — an inherited field / superclass member on a class whose parent
        // is a base type (e.g. `entries` on `BallObject extends BallMap`), a
        // stub-module enum constant (`io_FileMode`), or a second catch binding
        // (`stackTrace`). These are documented Round-3 gaps (#383); emit a
        // fail-loud marker rather than an undefined identifier, so the self-host
        // engine COMPILES (the base corpus never reaches these paths) and the
        // gap surfaces loudly, never as a silently-wrong value.
        return $"BallRuntime.UnresolvedReference({Naming.StringLiteral(reference.Name)})";
    }

    /// <summary>
    /// Dart core type names that can appear as a bare <c>reference</c> — the
    /// receiver of a static call (<c>int.tryParse</c>, <c>List.filled</c>) or a
    /// type argument. Emitted as a <see cref="BallRuntime.TypeLiteral"/> marker.
    /// A user type of the same short name (in <c>_typeDefsByShortName</c>) is
    /// excluded at the use site.
    /// </summary>
    private static readonly HashSet<string> BuiltinTypeNames = new(StringComparer.Ordinal)
    {
        "int", "double", "num", "String", "bool", "List", "Map", "Set", "Function",
        "Object", "DateTime", "Duration", "RegExp", "Iterable", "StringBuffer", "BigInt",
        "Uri", "Type", "Symbol", "Pattern", "Match", "Comparable", "Stopwatch",
    };

    /// <summary>
    /// Dart core map constructors that carry no typeDef but must materialize as a
    /// native runtime map (insertion-ordered, indexable) — see
    /// <see cref="CompileMessageCreation"/>. The engine uses these for its own
    /// instance-map / lookup-table backings (<c>_ballUserMap()</c> →
    /// <c>LinkedHashMap()</c>).
    /// </summary>
    private static readonly HashSet<string> NativeMapConstructors = new(StringComparer.Ordinal)
    {
        "LinkedHashMap", "HashMap", "SplayTreeMap",
    };

    /// <summary><c>field_access</c> — <c>object.field</c> against a dynamic (message/map) receiver.</summary>
    private string CompileFieldAccess(FieldAccess fieldAccess)
    {
        var obj = fieldAccess.Object is null ? "BallValue.Null" : CompileExpression(fieldAccess.Object);
        return $"BallRuntime.FieldGet({obj}, {Naming.StringLiteral(fieldAccess.Field)})";
    }

    /// <summary>
    /// <c>message_creation</c> — build a dynamic <see cref="BallMap"/> (an
    /// anonymous/argument message, empty <c>type_name</c>) or a
    /// <see cref="BallMessage"/> (a named instance). Positional <c>argN</c>
    /// fields of a constructor call are remapped to the constructor's real
    /// parameter names.
    /// </summary>
    /// <summary>
    /// If <paramref name="mc"/> is a Dart core-collection copy/fill constructor
    /// (<c>Map.from</c>/<c>Map.of</c>, <c>List.from</c>/<c>List.of</c>,
    /// <c>List.filled</c>, plus the <c>LinkedHashMap</c>/<c>HashMap</c> named
    /// aliases), emit the native-runtime materialization
    /// (<see cref="BallRuntime.MapCopy"/>/<see cref="BallRuntime.ListCopy"/>/
    /// <see cref="BallRuntime.ListFilled"/>); otherwise <c>null</c> (fall through
    /// to the general dynamic-message path).
    /// </summary>
    private string? CompileCollectionFactory(MessageCreation mc)
    {
        var op = Naming.TypeShortName(mc.TypeName) switch
        {
            "Map.from" or "Map.of"
                or "LinkedHashMap.from" or "LinkedHashMap.of"
                or "HashMap.from" or "HashMap.of"
                or "SplayTreeMap.from" or "SplayTreeMap.of" => "MapCopy",
            "List.from" or "List.of" => "ListCopy",
            "List.filled" => "ListFilled",
            _ => null,
        };
        if (op is null)
        {
            return null;
        }

        var args = mc.Fields
            .Where(f => Naming.IsPositionalArg(f.Name))
            .Select(f => f.Value is null ? "BallValue.Null" : CompileExpression(f.Value))
            .ToList();

        return op switch
        {
            "ListFilled" when args.Count >= 2 => $"BallRuntime.ListFilled({args[0]}, {args[1]})",
            "MapCopy" or "ListCopy" when args.Count >= 1 => $"BallRuntime.{op}({args[0]})",
            _ => null,
        };
    }

    private string CompileMessageCreation(MessageCreation mc)
    {
        // A Dart core-collection constructor (`LinkedHashMap()`, `HashMap()`, …)
        // used for the engine's internal map backings has no typeDef; compile it
        // to the native runtime map so it indexes/iterates/mutates like a real
        // map instead of an opaque BallMessage. Only the no-data-argument form is
        // native-lowered (the engine populates via `[]=`/`addAll`); a populated
        // core-collection ctor falls through to the general path.
        if (NativeMapConstructors.Contains(Naming.TypeShortName(mc.TypeName))
            && !mc.Fields.Any(f => Naming.IsPositionalArg(f.Name)))
        {
            return "(BallValue)new BallMap()";
        }

        // A Dart core-collection copy/fill constructor carrying a source or count
        // argument (`Map.from(m)`, `List.of(xs)`, `List.filled(n, x)`, …) also has
        // no typeDef; materialize a real native map/list so the result
        // indexes/iterates/mutates instead of being an opaque BallMessage the
        // engine then fails to `..remove(k)` / iterate. (The no-arg forms are
        // handled above.)
        if (CompileCollectionFactory(mc) is { } factory)
        {
            return factory;
        }

        // Remap each positional argN field to the constructor's real parameter
        // (== field) name, in declaration order.
        var ctorParams = ConstructorParamNames(mc.TypeName);
        var explicitFields = new HashSet<string>(StringComparer.Ordinal);
        var entries = new List<string>();
        for (var i = 0; i < mc.Fields.Count; i++)
        {
            var field = mc.Fields[i];
            var fieldName = field.Name;
            if (ctorParams is not null && Naming.IsPositionalArg(fieldName) && i < ctorParams.Count)
            {
                fieldName = ctorParams[i];
            }

            explicitFields.Add(fieldName);
            var value = field.Value is null ? "BallValue.Null" : CompileExpression(field.Value);
            entries.Add($"[{Naming.StringLiteral(fieldName)}] = {value}");
        }

        // A type with a body-carrying constructor MUST be built by invoking that
        // constructor — otherwise its body (lookup-table building, entry refresh)
        // never runs and the instance is half-built (issue #383). The constructor
        // itself seeds field defaults, runs the body, and writes fields back.
        if (BodyConstructorImpl(mc.TypeName) is { } implName)
        {
            var inputMap = entries.Count == 0 ? "new BallMap()" : $"new BallMap {{ {string.Join(", ", entries)} }}";
            return $"{implName}((BallValue){inputMap})";
        }

        // A bodyless (or absent) constructor builds an inline field map; add the
        // field-level default for every instance field the call does not itself
        // set (`_Scope(parent)` still gets its `_bindings = {}`, `entries = {}`).
        if (mc.TypeName.Length != 0
            && _typeDefsByShortName.TryGetValue(Naming.TypeShortName(mc.TypeName), out var td))
        {
            entries.AddRange(FieldDefaultEntries(td, explicitFields, new HashSet<string>(StringComparer.Ordinal)));
        }

        var mapExpr = entries.Count == 0
            ? "new BallMap()"
            : $"new BallMap {{ {string.Join(", ", entries)} }}";

        return mc.TypeName.Length == 0
            ? $"(BallValue){mapExpr}"
            : $"(BallValue)new BallMessage({Naming.StringLiteral(mc.TypeName)}, {mapExpr})";
    }

    /// <summary><c>block</c> in value position — a <c>Func&lt;BallValue&gt;</c> IIFE (see the class doc comment).</summary>
    private string CompileBlockExpression(Block block)
    {
        var inner = EmitBlockInner(block, isFunctionBody: true);
        return $"Run(() =>\n{{\n{inner}}})";
    }

    /// <summary>
    /// <c>lambda</c> — an anonymous function compiled as a C# lambda wrapped in
    /// a <see cref="BallFunction"/> so it is a first-class value. C# closures
    /// capture enclosing locals by reference, giving Ball's shared-capture
    /// semantics for free (no pre-clone dance is needed, unlike the Rust
    /// <c>move</c>-closure sibling).
    /// </summary>
    private string CompileLambda(FunctionDefinition lambda)
    {
        var inName = PushInput();
        var body = EmitFunctionBody(lambda);
        PopInput();
        var label = lambda.Name;
        return $"(BallValue)new BallFunction({Naming.StringLiteral(label)}, (BallValue {inName}) =>\n{body})";
    }

    /// <summary>
    /// <c>call</c> — a base-module call (dispatches to
    /// <see cref="CompileBaseCall"/>) or a user call. A user call to a local
    /// binding holding a function value routes through
    /// <see cref="BallRuntime.CallFunction"/>; every other user call is a
    /// direct method call, cross-module-qualified when needed.
    /// </summary>
    private string CompileCall(FunctionCall call)
    {
        if (_baseModules.Contains(call.Module))
        {
            return CompileBaseCall(call);
        }

        // A call into an import-only stub module (dart.math/dart.io/…) is an
        // unimplemented external base function — fail loud rather than emit a
        // reference to a phantom class member.
        if (_stubModules.Contains(call.Module))
        {
            return Unsupported(call);
        }

        var input = call.Input is null ? "BallValue.Null" : CompileExpression(call.Input);
        var name = Naming.Sanitize(call.Function);
        var prefix = ResolveUserCallPrefix(call.Module);

        if (prefix.Length == 0 && LocalName(call.Function) is { } localCallee)
        {
            return $"BallRuntime.CallFunction({localCallee}, {input})";
        }

        // A same-module call whose callee is neither a known user function nor a
        // local function value is a built-in method call on a core type
        // (`x.group(1)`, `int.tryParse(s)`, `list.addAll(y)`) that the encoder
        // lowered to `call{module:"", function:<method>, input:{self, arg0, …}}`.
        // There is no static receiver type, so dispatch it dynamically at runtime.
        if (prefix.Length == 0 && !_callableNames.Contains(name))
        {
            return $"BallRuntime.CallMethod({Naming.StringLiteral(call.Function)}, {input})";
        }

        // Implicit-`this` injection (issue #383): a bare `this.method(args)` call
        // to an instance-method dispatcher from inside an instance method body has
        // its receiver injected (the encoder packs only the arguments). A
        // multi-argument `{arg0, arg1}` message or a zero-argument call merges
        // `self` in; a single positional argument is wrapped as `{self, arg0}`. An
        // explicit `obj.method(args)` (input already carries `self`) is untouched.
        if (prefix.Length == 0
            && _inInstanceMethod
            && _instanceMethodNames.Contains(name)
            && !CallInputHasExplicitSelf(call))
        {
            var self = _selfRecvName ?? LocalName("self") ?? "self";
            return CallInputIsArgMessage(call) || call.Input is null
                ? $"{name}(BallRuntime.WithSelf({input}, {self}))"
                : $"{name}(BallRuntime.Arg0WithSelf({input}, {self}))";
        }

        return $"{prefix}{name}({input})";
    }

    /// <summary>Whether <paramref name="call"/>'s input is a <c>MessageCreation</c> already carrying an explicit <c>self</c> field (an <c>obj.method(...)</c> call).</summary>
    private static bool CallInputHasExplicitSelf(FunctionCall call) =>
        call.Input is { ExprCase: Expression.ExprOneofCase.MessageCreation } input
        && input.MessageCreation.Fields.Any(f => f.Name == "self");

    /// <summary>Whether <paramref name="call"/>'s input is the encoder's multi-argument message (an anonymous, empty-<c>type_name</c> <c>MessageCreation</c>).</summary>
    private static bool CallInputIsArgMessage(FunctionCall call) =>
        call.Input is { ExprCase: Expression.ExprOneofCase.MessageCreation } input
        && input.MessageCreation.TypeName.Length == 0;

    /// <summary>The <c>&lt;Class&gt;.</c> qualifier for a cross-module user call (empty for a same-module call).</summary>
    private string ResolveUserCallPrefix(string module)
    {
        if (module.Length == 0 || module == _currentModule)
        {
            return string.Empty;
        }

        return module == _entryModule ? "BallProgram." : $"{Naming.Sanitize(module)}.";
    }

    // ════════════════════════════════════════════════════════════
    // Scope tracking + metadata helpers
    // ════════════════════════════════════════════════════════════

    private void PushScope() => _localScopes.Add(new Dictionary<string, string>(StringComparer.Ordinal));

    private void PopScope() => _localScopes.RemoveAt(_localScopes.Count - 1);

    /// <summary>The innermost synthesized input parameter name (see <see cref="_inputNames"/>).</summary>
    private string CurrentInput => _inputNames.Count > 0 ? _inputNames[^1] : "input";

    /// <summary>Begin a new function/method/lambda input scope, returning its unique C# parameter name.</summary>
    private string PushInput()
    {
        var name = "__in" + _inputCounter++;
        _inputNames.Add(name);
        return name;
    }

    private void PopInput() => _inputNames.RemoveAt(_inputNames.Count - 1);

    /// <summary>
    /// Bind a Ball local in the current scope and return the C# identifier to
    /// emit for it — <b>always a unique</b> <c>{name}__L{n}</c> alias. Dart allows
    /// a binding to shadow a namesake in an enclosing scope; C# does not (CS0136),
    /// and — because C# block scoping ignores declaration order — a local at a
    /// method's top level even conflicts with a namesake in a nested block that
    /// textually precedes it. Making every binding globally unique sidesteps the
    /// whole family; references resolve through <see cref="LocalName"/>, so the
    /// alias is invisible to the Ball program's semantics.
    /// </summary>
    private string BindLocal(string name)
    {
        var sanitized = Naming.Sanitize(name);
        var emitted = $"{sanitized}__L{_shadowCounter++}";
        if (_localScopes.Count > 0)
        {
            _localScopes[^1][sanitized] = emitted;
        }

        return emitted;
    }

    /// <summary>The C# identifier a Ball local resolves to (innermost scope first), or <c>null</c> if unbound.</summary>
    private string? LocalName(string name)
    {
        var sanitized = Naming.Sanitize(name);
        for (var i = _localScopes.Count - 1; i >= 0; i--)
        {
            if (_localScopes[i].TryGetValue(sanitized, out var emitted))
            {
                return emitted;
            }
        }

        return null;
    }

    private bool IsLocal(string name) => LocalName(name) is not null;

    /// <summary>The declared parameter names of <paramref name="func"/> from its <c>metadata.params</c> bag.</summary>
    private static List<string> ParamNames(FunctionDefinition func)
    {
        var names = new List<string>();
        if (func.Metadata is null || !func.Metadata.Fields.TryGetValue("params", out var paramsValue))
        {
            return names;
        }

        if (paramsValue.KindCase != Value.KindOneofCase.ListValue)
        {
            return names;
        }

        foreach (var element in paramsValue.ListValue.Values)
        {
            if (element.KindCase == Value.KindOneofCase.StructValue
                && element.StructValue.Fields.TryGetValue("name", out var nameValue)
                && nameValue.KindCase == Value.KindOneofCase.StringValue)
            {
                names.Add(nameValue.StringValue);
            }
        }

        return names;
    }

    private static string MetaString(Struct? meta, string key)
    {
        if (meta is not null
            && meta.Fields.TryGetValue(key, out var value)
            && value.KindCase == Value.KindOneofCase.StringValue)
        {
            return value.StringValue;
        }

        return string.Empty;
    }

    private static bool MetaBool(Struct? meta, string key) =>
        meta is not null
        && meta.Fields.TryGetValue(key, out var value)
        && value.KindCase == Value.KindOneofCase.BoolValue
        && value.BoolValue;
}
