using System.Text;
using Ball.Shared;
using Ball.V1;

namespace Ball.Compiler;

/// <summary>
/// Base-function (<c>call</c>) compilation — the dispatch table that turns
/// <c>std</c>/<c>std_collections</c>/<c>std_io</c> base calls into native C#
/// (issue #381). Base functions have no body (invariant #3); this file is
/// their C# implementation, mirroring <c>dart/compiler/lib/compiler.dart</c>'s
/// <c>_compileBaseCall</c> and <c>rust/compiler/src/base_call.rs</c>.
///
/// <para>Operators (arithmetic/comparison/logic/bitwise/string) delegate to
/// <see cref="BallRuntime"/>. This file's own job is the constructs a plain
/// function call cannot express: <b>lazy control flow</b> (invariant #4).
/// <c>if</c> becomes a native C# <c>if</c> statement (or a ternary in value
/// position); <c>and</c>/<c>or</c>/<c>??</c> use C#'s own short-circuiting
/// <c>&amp;&amp;</c>/<c>||</c>/conditional so the untaken operand is never
/// <em>reached</em>; <c>for</c>/<c>for_in</c>/<c>while</c>/<c>do_while</c>
/// become native loops with the body compiled directly inline. A runtime
/// function call cannot be lazy — C# evaluates every argument first — which is
/// exactly why these are hand-lowered here rather than routed through
/// <see cref="BallRuntime"/>.</para>
/// </summary>
public sealed partial class CSharpCompiler
{
    /// <summary>
    /// Emit a control-flow / flow-signal base call as a native C# statement, or
    /// <c>null</c> when <paramref name="call"/> is an ordinary value-yielding
    /// base function (handled by the expression path). Only <c>std</c>'s lazy
    /// control flow, flow signals, and assignment need statement lowering.
    /// </summary>
    private string? EmitBaseStatement(FunctionCall call)
    {
        if (call.Module != "std")
        {
            return null;
        }

        switch (call.Function)
        {
            case "if":
                return CompileIfStatement(call);
            case "for":
                return CompileForStatement(call);
            case "for_in":
            case "for_each":
                return CompileForInStatement(call);
            case "while":
                return CompileWhileStatement(call);
            case "do_while":
                return CompileDoWhileStatement(call);
            case "switch":
            case "switch_expr":
                return CompileSwitchStatement(call);
            case "try":
                return CompileTryStatement(call);
            case "return":
                return CompileReturnStatement(call);
            case "break":
                return "break;";
            case "continue":
                return "continue;";
            case "throw":
                return $"throw new BallThrow({FieldOrNull(Fields.Extract(call), "value")});";
            case "rethrow":
                return "throw;";
            case "assert":
                return CompileAssertStatement(call);
            case "assign":
                return CompileAssign(call) + ";";
            case "pre_increment":
            case "post_increment":
                return MutateStatementForm(call, "+=") + ";";
            case "pre_decrement":
            case "post_decrement":
                return MutateStatementForm(call, "-=") + ";";
            default:
                return null;
        }
    }

    /// <summary>Base-function dispatch in value (expression) position — every call yields a <see cref="BallValue"/>.</summary>
    private string CompileBaseCall(FunctionCall call)
    {
        switch (call.Module)
        {
            case "std_collections":
                return CompileCollectionsCall(call);
            case "std_io":
                return CompileIoCall(call);
            case "ball_proto":
                return CompileBallProtoCall(call);
        }

        // Lazy constructs and those needing the raw call (nested exprs) skip
        // the up-front field extraction.
        switch (call.Function)
        {
            case "and":
                return CompileAnd(call);
            case "or":
                return CompileOr(call);
            case "null_coalesce":
                return CompileNullCoalesce(call);
            case "if":
                return CompileIfExpression(call);
            case "for":
            case "for_in":
            case "for_each":
            case "while":
            case "do_while":
            case "switch":
            case "switch_expr":
            case "try":
            case "return":
            case "break":
            case "continue":
            case "assert":
                return WrapStatementAsExpression(call);
            case "assign":
                return $"({CompileAssign(call)})";
            case "pre_increment":
                return $"({MutateStatementForm(call, "+=")})";
            case "post_increment":
                return CompilePostMutate(call, "+=");
            case "pre_decrement":
                return $"({MutateStatementForm(call, "-=")})";
            case "post_decrement":
                return CompilePostMutate(call, "-=");
        }

        var f = Fields.Extract(call);
        return call.Function switch
        {
            "print" => $"BallRuntime.Print({FieldOrNull(f, "message")})",
            // Arithmetic
            "add" => Bin("Add", f),
            "subtract" => Bin("Subtract", f),
            "multiply" => Bin("Multiply", f),
            "divide" => Bin("Divide", f),
            "divide_double" => Bin("DivideDouble", f),
            "modulo" => Bin("Modulo", f),
            "negate" => Un("Negate", f),
            // Comparison
            "equals" => Bin("Equals", f),
            "not_equals" => Bin("NotEquals", f),
            "less_than" => Bin("LessThan", f),
            "greater_than" => Bin("GreaterThan", f),
            "lte" => Bin("Lte", f),
            "gte" => Bin("Gte", f),
            "compare_to" => BinAlias("CompareTo", f, new[] { "left", "value" }, new[] { "right", "other" }),
            // Logic / bitwise
            "not" => Un("Not", f),
            "bitwise_and" => Bin("BitwiseAnd", f),
            "bitwise_or" => Bin("BitwiseOr", f),
            "bitwise_xor" => Bin("BitwiseXor", f),
            "bitwise_not" => Un("BitwiseNot", f),
            "left_shift" => Bin("LeftShift", f),
            "right_shift" => Bin("RightShift", f),
            "unsigned_right_shift" => Bin("UnsignedRightShift", f),
            // String & conversion
            "concat" or "string_concat" => Bin("Add", f),
            "to_string" or "int_to_string" or "double_to_string" => Un("ToStringValue", f),
            "length" or "string_length" => Un("Length", f),
            "string_to_int" => Un("StringToInt", f),
            "string_to_double" => Un("StringToDouble", f),
            "to_double" => Un("ToDouble", f),
            "to_int" => Un("ToInt", f),
            // Null safety
            "null_check" => Un("NullCheck", f),
            // Type ops (indexing / string char)
            "index" or "string_char_at" => CompileIndex(f),
            // Strings (pure manipulation)
            "string_is_empty" => Un("StringIsEmpty", f),
            "string_contains" => Bin("StringContains", f),
            "string_starts_with" => Bin("StringStartsWith", f),
            "string_ends_with" => Bin("StringEndsWith", f),
            "string_index_of" => Bin("StringIndexOf", f),
            "string_last_index_of" => Bin("StringLastIndexOf", f),
            "string_substring" => Tri("StringSubstring", f, "value", "start", "end"),
            "string_char_code_at" => Compile2("StringCharCodeAt", f, "value", "index", "target", "index"),
            "string_from_char_code" => Un("StringFromCharCode", f),
            "string_to_upper" => Un("StringToUpper", f),
            "string_to_lower" => Un("StringToLower", f),
            "string_trim" => Un("StringTrim", f),
            "string_trim_start" => Un("StringTrimStart", f),
            "string_trim_end" => Un("StringTrimEnd", f),
            "string_replace" => Tri("StringReplace", f, "value", "from", "to"),
            "string_replace_all" => Tri("StringReplaceAll", f, "value", "from", "to"),
            "string_split" => BinAlias("StringSplit", f, new[] { "left", "value", "string" }, new[] { "right", "separator", "delimiter" }),
            "string_repeat" => Compile2("StringRepeat", f, "value", "count", "left", "right"),
            "string_pad_left" => Tri("StringPadLeft", f, "value", "width", "padding"),
            "string_pad_right" => Tri("StringPadRight", f, "value", "width", "padding"),
            _ => Unsupported(call),
        };
    }

    // ════════════════════════════════════════════════════════════
    // Field-extraction helpers
    // ════════════════════════════════════════════════════════════

    private string FieldOrNull(OrderedDictionary<string, Expression> fields, string key) =>
        fields.TryGetValue(key, out var expr) ? CompileExpression(expr) : "BallValue.Null";

    private string FieldAliasOrNull(OrderedDictionary<string, Expression> fields, string[] keys)
    {
        foreach (var key in keys)
        {
            if (fields.TryGetValue(key, out var expr))
            {
                return CompileExpression(expr);
            }
        }

        return "BallValue.Null";
    }

    private string Un(string helper, OrderedDictionary<string, Expression> fields) =>
        $"BallRuntime.{helper}({FieldAliasOrNull(fields, new[] { "value", "left" })})";

    private string Bin(string helper, OrderedDictionary<string, Expression> fields) =>
        $"BallRuntime.{helper}({FieldOrNull(fields, "left")}, {FieldOrNull(fields, "right")})";

    private string BinAlias(string helper, OrderedDictionary<string, Expression> fields, string[] left, string[] right) =>
        $"BallRuntime.{helper}({FieldAliasOrNull(fields, left)}, {FieldAliasOrNull(fields, right)})";

    private string Tri(string helper, OrderedDictionary<string, Expression> fields, string a, string b, string c) =>
        $"BallRuntime.{helper}({FieldOrNull(fields, a)}, {FieldOrNull(fields, b)}, {FieldOrNull(fields, c)})";

    private string Compile2(string helper, OrderedDictionary<string, Expression> fields, string a, string b, string aAlt, string bAlt) =>
        $"BallRuntime.{helper}({FieldAliasOrNull(fields, new[] { a, aAlt })}, {FieldAliasOrNull(fields, new[] { b, bAlt })})";

    private string Unsupported(FunctionCall call) =>
        $"BallRuntime.UnsupportedBaseCall({Naming.StringLiteral(call.Module)}, {Naming.StringLiteral(call.Function)})";

    private static string? StringField(OrderedDictionary<string, Expression> fields, string key)
    {
        if (fields.TryGetValue(key, out var expr)
            && expr.ExprCase == Expression.ExprOneofCase.Literal
            && expr.Literal.ValueCase == Literal.ValueOneofCase.StringValue)
        {
            return expr.Literal.StringValue;
        }

        return null;
    }

    private static bool BoolField(OrderedDictionary<string, Expression> fields, string key) =>
        fields.TryGetValue(key, out var expr)
        && expr.ExprCase == Expression.ExprOneofCase.Literal
        && expr.Literal.ValueCase == Literal.ValueOneofCase.BoolValue
        && expr.Literal.BoolValue;

    // ════════════════════════════════════════════════════════════
    // Lazy control flow
    // ════════════════════════════════════════════════════════════

    private string CompileIfStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var condition = FieldOrNull(f, "condition");
        var then = EmitBranch(f, "then");
        var sb = new StringBuilder($"if (BallRuntime.Truthy({condition}))\n{{\n{then}\n}}");
        if (f.ContainsKey("else"))
        {
            sb.Append($"\nelse\n{{\n{EmitBranch(f, "else")}\n}}");
        }

        return sb.ToString();
    }

    /// <summary>Emit an <c>if</c>/loop branch (a field value) in statement position (a block is unwrapped — the caller braces it).</summary>
    private string EmitBranch(OrderedDictionary<string, Expression> fields, string key) =>
        fields.TryGetValue(key, out var expr) ? EmitStatementUnwrapped(expr) : ";";

    /// <summary><c>if(condition, then, else?)</c> in value position — a C# ternary (both arms lazy).</summary>
    private string CompileIfExpression(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var condition = FieldOrNull(f, "condition");
        var then = FieldOrNull(f, "then");
        var elseBranch = FieldOrNull(f, "else");
        return $"(BallRuntime.Truthy({condition}) ? {then} : {elseBranch})";
    }

    /// <summary><c>and(left, right)</c> — native <c>&amp;&amp;</c>: <c>right</c> is never reached when <c>left</c> is false.</summary>
    private string CompileAnd(FunctionCall call)
    {
        var f = Fields.Extract(call);
        return $"Bool(BallRuntime.Truthy({FieldOrNull(f, "left")}) && BallRuntime.Truthy({FieldOrNull(f, "right")}))";
    }

    /// <summary><c>or(left, right)</c> — native <c>||</c>, lazy for the same reason as <c>and</c>.</summary>
    private string CompileOr(FunctionCall call)
    {
        var f = Fields.Extract(call);
        return $"Bool(BallRuntime.Truthy({FieldOrNull(f, "left")}) || BallRuntime.Truthy({FieldOrNull(f, "right")}))";
    }

    /// <summary><c>null_coalesce(left, right)</c> (<c>??</c>) — <c>right</c> evaluated only when <c>left</c> is null.</summary>
    private string CompileNullCoalesce(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var left = FieldOrNull(f, "left");
        var right = FieldOrNull(f, "right");
        return $"Run(() => {{ var __l = {left}; return __l is BallNull ? {right} : __l; }})";
    }

    /// <summary>
    /// <c>for(init, condition, update, body)</c> — a native C# <c>for</c>. The
    /// <c>init</c> declarations are hoisted just above the loop (so a multi-
    /// counter <c>init</c> works), and a native <c>continue</c> still runs the
    /// <c>update</c> clause — matching a C-style <c>for</c> exactly.
    /// </summary>
    private string CompileForStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        PushScope();
        var initCode = f.TryGetValue("init", out var init) ? EmitForInit(init) : string.Empty;
        var condCode = f.TryGetValue("condition", out var cond)
            ? $"BallRuntime.Truthy({CompileExpression(cond)})"
            : "true";
        var updateCode = f.TryGetValue("update", out var update) ? EmitForUpdate(update) : string.Empty;
        var bodyCode = EmitBranch(f, "body");
        PopScope();
        return $"{{\n{initCode}for (; {condCode}; {updateCode})\n{{\n{bodyCode}\n}}\n}}";
    }

    /// <summary>Compile a <c>for</c>'s <c>init</c> — a block of <c>let</c> declarations hoisted above the loop.</summary>
    private string EmitForInit(Expression init)
    {
        if (init.ExprCase == Expression.ExprOneofCase.Block
            && init.Block.Result is null
            && init.Block.Statements.Count > 0
            && init.Block.Statements.All(s => s.StmtCase == Statement.StmtOneofCase.Let))
        {
            var sb = new StringBuilder();
            foreach (var statement in init.Block.Statements)
            {
                var let = statement.Let;
                var value = let.Value is null ? "BallValue.Null" : CompileExpression(let.Value);
                sb.Append($"var {Naming.Sanitize(let.Name)} = {value};\n");
                BindLocal(let.Name);
            }

            return sb.ToString();
        }

        return EmitStatement(init) + "\n";
    }

    /// <summary>Compile a <c>for</c>'s <c>update</c> clause as an expression (no trailing semicolon).</summary>
    private string EmitForUpdate(Expression update)
    {
        if (update.ExprCase == Expression.ExprOneofCase.Call && update.Call.Module == "std")
        {
            switch (update.Call.Function)
            {
                case "assign":
                    return CompileAssign(update.Call);
                case "pre_increment":
                case "post_increment":
                    return MutateStatementForm(update.Call, "+=");
                case "pre_decrement":
                case "post_decrement":
                    return MutateStatementForm(update.Call, "-=");
            }
        }

        return CompileExpression(update);
    }

    private string CompileForInStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var variable = StringField(f, "variable") ?? "item";
        var iterableCode = FieldOrNull(f, "iterable");
        PushScope();
        BindLocal(variable);
        var bodyCode = EmitBranch(f, "body");
        PopScope();
        return $"foreach (var {Naming.Sanitize(variable)} in BallRuntime.Iterate({iterableCode}))\n{{\n{bodyCode}\n}}";
    }

    private string CompileWhileStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var condCode = f.TryGetValue("condition", out var cond)
            ? $"BallRuntime.Truthy({CompileExpression(cond)})"
            : "true";
        var bodyCode = EmitBranch(f, "body");
        return $"while ({condCode})\n{{\n{bodyCode}\n}}";
    }

    private string CompileDoWhileStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var bodyCode = EmitBranch(f, "body");
        var condCode = f.TryGetValue("condition", out var cond)
            ? $"BallRuntime.Truthy({CompileExpression(cond)})"
            : "true";
        return $"do\n{{\n{bodyCode}\n}}\nwhile ({condCode});";
    }

    /// <summary>
    /// <c>switch(subject, cases)</c> → an if-else chain over
    /// <see cref="BallValue.ValueEquals"/> (no fallthrough — matching Dart),
    /// wrapped in a <c>do { … } while (false)</c> so a case body's explicit
    /// <c>break</c> exits the switch. Labelled goto-case is a documented gap.
    /// </summary>
    private string CompileSwitchStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var subject = FieldOrNull(f, "subject");
        var cases = MessageList(f, "cases");
        var sb = new StringBuilder($"do\n{{\nvar __subj = {subject};\n");
        var first = true;
        MessageCreation? defaultCase = null;
        foreach (var caseMc in cases)
        {
            var cf = MessageCreationFields(caseMc);
            if (BoolField(cf, "is_default"))
            {
                defaultCase = caseMc;
                continue;
            }

            var value = FieldOrNull(cf, "value");
            var body = cf.TryGetValue("body", out var b) ? EmitStatementUnwrapped(b) : ";";
            sb.Append($"{(first ? "if" : "else if")} (BallValue.ValueEquals(__subj, {value}))\n{{\n{body}\n}}\n");
            first = false;
        }

        if (defaultCase is not null)
        {
            var cf = MessageCreationFields(defaultCase);
            var body = cf.TryGetValue("body", out var b) ? EmitStatementUnwrapped(b) : ";";
            sb.Append($"else\n{{\n{body}\n}}\n");
        }

        sb.Append("}\nwhile (false);");
        return sb.ToString();
    }

    /// <summary>
    /// <c>try(body, catches, finally?)</c> → a native C# <c>try/catch/finally</c>.
    /// Dispatches only the first <c>catch</c> clause (no exception-type matching
    /// yet — a documented gap shared with the Rust sibling). A Ball
    /// <c>throw value</c> is a <see cref="BallThrow"/>; the clause variable binds
    /// its payload.
    /// </summary>
    private string CompileTryStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var bodyCode = EmitBranch(f, "body");
        var sb = new StringBuilder($"try\n{{\n{bodyCode}\n}}\n");

        var catches = MessageList(f, "catches");
        if (catches.Count > 0)
        {
            var cf = MessageCreationFields(catches[0]);
            var variable = StringField(cf, "variable");
            PushScope();
            sb.Append("catch (BallThrow __ballEx)\n{\n");
            if (!string.IsNullOrEmpty(variable))
            {
                BindLocal(variable);
                sb.Append($"var {Naming.Sanitize(variable)} = __ballEx.Payload;\n");
            }

            sb.Append(cf.TryGetValue("body", out var cb) ? EmitStatementUnwrapped(cb) : ";");
            sb.Append("\n}\n");
            PopScope();
        }

        if (f.TryGetValue("finally", out var fin))
        {
            sb.Append($"finally\n{{\n{EmitStatementUnwrapped(fin)}\n}}\n");
        }

        return sb.ToString();
    }

    private string CompileReturnStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        return $"return {FieldOrNull(f, "value")};";
    }

    private string CompileAssertStatement(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var condition = FieldOrNull(f, "condition");
        var message = f.ContainsKey("message")
            ? $"BallRuntime.ToStringValue({FieldOrNull(f, "message")}).ToString()"
            : "\"assertion failed\"";
        return $"if (!BallRuntime.Truthy({condition})) throw new BallRuntimeException({message});";
    }

    /// <summary>Wrap a statement-lowered construct as a value-position expression via the <c>Run</c> IIFE.</summary>
    private string WrapStatementAsExpression(FunctionCall call)
    {
        var native = EmitBaseStatement(call) ?? ";";
        return $"Run(() =>\n{{\n{native}\nreturn BallValue.Null;\n}})";
    }

    // ════════════════════════════════════════════════════════════
    // Assignment / mutation
    // ════════════════════════════════════════════════════════════

    private enum LValueKind
    {
        Var,
        Field,
        Index,
        Unsupported,
    }

    private readonly record struct LValue(LValueKind Kind, string A, string B);

    private LValue ResolveLValue(Expression target)
    {
        switch (target.ExprCase)
        {
            case Expression.ExprOneofCase.Reference:
                return new LValue(LValueKind.Var, Naming.Sanitize(target.Reference.Name), string.Empty);
            case Expression.ExprOneofCase.FieldAccess:
                var fa = target.FieldAccess;
                var obj = fa.Object is null ? "BallValue.Null" : CompileExpression(fa.Object);
                return new LValue(LValueKind.Field, obj, fa.Field);
            case Expression.ExprOneofCase.Call
                when target.Call.Module == "std"
                     && (target.Call.Function == "index" || target.Call.Function == "null_aware_index"):
                var idxFields = Fields.Extract(target.Call);
                var targetCode = FieldOrNull(idxFields, "target");
                var indexCode = FieldOrNull(idxFields, "index");
                return new LValue(LValueKind.Index, targetCode, indexCode);
            default:
                return new LValue(LValueKind.Unsupported, string.Empty, string.Empty);
        }
    }

    /// <summary>
    /// <c>assign(target, value, op?)</c> — an assignment <em>expression</em>
    /// yielding the new value. C# assignment is an expression, so this is
    /// usable both as a statement (<c>i = …;</c>) and in a <c>for</c>-update
    /// clause. Field/index targets read-modify-write through
    /// <see cref="BallRuntime.FieldGet"/>/<c>Set</c> / <c>IndexGet</c>/<c>Set</c>.
    /// </summary>
    private string CompileAssign(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var op = StringField(f, "op") ?? "=";
        var valueCode = FieldOrNull(f, "value");
        var target = f.TryGetValue("target", out var t) ? t : new Expression();
        var lv = ResolveLValue(target);
        return EmitMutation(lv, op, valueCode);
    }

    /// <summary>The statement/for-update form of an increment/decrement — the old value is discarded.</summary>
    private string MutateStatementForm(FunctionCall call, string op)
    {
        var f = Fields.Extract(call);
        var target = f.TryGetValue("value", out var t) ? t : new Expression();
        var lv = ResolveLValue(target);
        return EmitMutation(lv, op, "Int(1L)");
    }

    /// <summary>Post-increment/decrement in value position — yields the pre-mutation (old) value.</summary>
    private string CompilePostMutate(FunctionCall call, string op)
    {
        var f = Fields.Extract(call);
        var target = f.TryGetValue("value", out var t) ? t : new Expression();
        var lv = ResolveLValue(target);
        if (lv.Kind == LValueKind.Var)
        {
            return $"Run(() => {{ var __old = {lv.A}; {lv.A} = {CombineOp(op, lv.A, "Int(1L)")}; return __old; }})";
        }

        // Field/index post-mutation is rare; fall back to the new-value form.
        return $"({EmitMutation(lv, op, "Int(1L)")})";
    }

    /// <summary>
    /// Emit the <b>core</b> assignment to a resolved lvalue (no outer
    /// parentheses), yielding the new value. Usable directly as a statement
    /// (<c>x = …;</c>) or a <c>for</c>-update clause; value-position callers
    /// wrap it in parentheses (a bare parenthesized assignment is not a legal
    /// C# statement — CS0201 — so the two contexts must differ here).
    /// </summary>
    private string EmitMutation(LValue lv, string op, string valueCode)
    {
        switch (lv.Kind)
        {
            case LValueKind.Var:
                return $"{lv.A} = {CombineOp(op, lv.A, valueCode)}";
            case LValueKind.Field:
                var currentField = $"BallRuntime.FieldGet({lv.A}, {Naming.StringLiteral(lv.B)})";
                return $"BallRuntime.FieldSet({lv.A}, {Naming.StringLiteral(lv.B)}, {CombineOp(op, currentField, valueCode)})";
            case LValueKind.Index:
                var currentIndex = $"BallRuntime.IndexGet({lv.A}, {lv.B})";
                return $"BallRuntime.IndexSet({lv.A}, {lv.B}, {CombineOp(op, currentIndex, valueCode)})";
            default:
                return "BallRuntime.UnsupportedBaseCall(\"std\", \"assign\")";
        }
    }

    /// <summary>Combine a read (<paramref name="left"/>) with <paramref name="right"/> per the compound-assignment op.</summary>
    private static string CombineOp(string op, string left, string right) => op switch
    {
        "=" or "" => right,
        "+=" => $"BallRuntime.Add({left}, {right})",
        "-=" => $"BallRuntime.Subtract({left}, {right})",
        "*=" => $"BallRuntime.Multiply({left}, {right})",
        "/=" => $"BallRuntime.DivideDouble({left}, {right})",
        "~/=" => $"BallRuntime.Divide({left}, {right})",
        "%=" => $"BallRuntime.Modulo({left}, {right})",
        "&=" => $"BallRuntime.BitwiseAnd({left}, {right})",
        "|=" => $"BallRuntime.BitwiseOr({left}, {right})",
        "^=" => $"BallRuntime.BitwiseXor({left}, {right})",
        "<<=" => $"BallRuntime.LeftShift({left}, {right})",
        ">>=" => $"BallRuntime.RightShift({left}, {right})",
        ">>>=" => $"BallRuntime.UnsignedRightShift({left}, {right})",
        "??=" => $"BallRuntime.NullCoalesce({left}, {right})",
        _ => right,
    };

    /// <summary><c>index(target, index)</c> / <c>string_char_at</c> → <see cref="BallRuntime.IndexGet"/>.</summary>
    private string CompileIndex(OrderedDictionary<string, Expression> fields) =>
        $"BallRuntime.IndexGet({FieldOrNull(fields, "target")}, {FieldOrNull(fields, "index")})";

    // ════════════════════════════════════════════════════════════
    // std_collections + std_io
    // ════════════════════════════════════════════════════════════

    private string CompileCollectionsCall(FunctionCall call)
    {
        var f = Fields.Extract(call);
        return call.Function switch
        {
            // List — read
            "list_get" => $"BallRuntime.ListGet({FieldOrNull(f, "list")}, {FieldOrNull(f, "index")})",
            "list_length" => $"BallRuntime.ListLength({FieldOrNull(f, "list")})",
            "list_is_empty" => $"BallRuntime.ListIsEmpty({FieldOrNull(f, "list")})",
            "list_first" => $"BallRuntime.ListFirst({FieldOrNull(f, "list")})",
            "list_last" => $"BallRuntime.ListLast({FieldOrNull(f, "list")})",
            "list_contains" => $"BallRuntime.ListContains({FieldOrNull(f, "list")}, {FieldOrNull(f, "value")})",
            "list_index_of" => $"BallRuntime.ListIndexOf({FieldOrNull(f, "list")}, {FieldOrNull(f, "value")})",
            "list_reverse" => $"BallRuntime.ListReverse({FieldOrNull(f, "list")})",
            "list_concat" => $"BallRuntime.ListConcat({FieldOrNull(f, "list")}, {FieldAliasOrNull(f, new[] { "value", "index" })})",
            "list_slice" => $"BallRuntime.ListSlice({FieldOrNull(f, "list")}, {FieldOrNull(f, "start")}, {FieldOrNull(f, "end")})",
            "list_take" => $"BallRuntime.ListTake({FieldOrNull(f, "list")}, {FieldAliasOrNull(f, new[] { "index", "value" })})",
            "list_drop" => $"BallRuntime.ListDrop({FieldOrNull(f, "list")}, {FieldAliasOrNull(f, new[] { "index", "value" })})",
            // List — mutate
            "list_push" => $"BallRuntime.ListPush({FieldOrNull(f, "list")}, {FieldOrNull(f, "value")})",
            "list_pop" => $"BallRuntime.ListPop({FieldOrNull(f, "list")})",
            "list_insert" => $"BallRuntime.ListInsert({FieldOrNull(f, "list")}, {FieldOrNull(f, "index")}, {FieldOrNull(f, "value")})",
            "list_remove_at" => $"BallRuntime.ListRemoveAt({FieldOrNull(f, "list")}, {FieldOrNull(f, "index")})",
            "list_set" => $"BallRuntime.ListSet({FieldOrNull(f, "list")}, {FieldOrNull(f, "index")}, {FieldOrNull(f, "value")})",
            "list_clear" => $"BallRuntime.ListClear({FieldOrNull(f, "list")})",
            // Map
            "map_get" => $"BallRuntime.MapGet({FieldOrNull(f, "map")}, {FieldOrNull(f, "key")})",
            "map_set" => $"BallRuntime.MapSet({FieldOrNull(f, "map")}, {FieldOrNull(f, "key")}, {FieldOrNull(f, "value")})",
            "map_delete" => $"BallRuntime.MapDelete({FieldOrNull(f, "map")}, {FieldOrNull(f, "key")})",
            "map_contains_key" => $"BallRuntime.MapContainsKey({FieldOrNull(f, "map")}, {FieldOrNull(f, "key")})",
            "map_keys" => $"BallRuntime.MapKeys({FieldOrNull(f, "map")})",
            "map_values" => $"BallRuntime.MapValues({FieldOrNull(f, "map")})",
            "map_length" => $"BallRuntime.MapLength({FieldOrNull(f, "map")})",
            "map_is_empty" => $"BallRuntime.MapIsEmpty({FieldOrNull(f, "map")})",
            "map_merge" => $"BallRuntime.MapMerge({FieldOrNull(f, "map")}, {FieldAliasOrNull(f, new[] { "value", "key" })})",
            // String <-> collection
            "string_join" => $"BallRuntime.StringJoin({FieldOrNull(f, "list")}, {FieldOrNull(f, "separator")})",
            // Set
            "set_create" => $"BallRuntime.SetCreate({FieldAliasOrNull(f, new[] { "list", "elements", "set" })})",
            "set_add" => $"BallRuntime.SetAdd({FieldOrNull(f, "set")}, {FieldOrNull(f, "value")})",
            "set_remove" => $"BallRuntime.SetRemove({FieldOrNull(f, "set")}, {FieldOrNull(f, "value")})",
            "set_contains" => $"BallRuntime.SetContains({FieldOrNull(f, "set")}, {FieldOrNull(f, "value")})",
            "set_length" => $"BallRuntime.SetLength({FieldOrNull(f, "set")})",
            "set_is_empty" => $"BallRuntime.SetIsEmpty({FieldOrNull(f, "set")})",
            "set_to_list" => $"BallRuntime.SetToList({FieldOrNull(f, "set")})",
            "set_union" => $"BallRuntime.SetUnion({FieldOrNull(f, "left")}, {FieldOrNull(f, "right")})",
            "set_intersection" => $"BallRuntime.SetIntersection({FieldOrNull(f, "left")}, {FieldOrNull(f, "right")})",
            "set_difference" => $"BallRuntime.SetDifference({FieldOrNull(f, "left")}, {FieldOrNull(f, "right")})",
            _ => Unsupported(call),
        };
    }

    private string CompileIoCall(FunctionCall call)
    {
        var f = Fields.Extract(call);
        return call.Function switch
        {
            "print_error" => $"Run(() => {{ Console.Error.Write(({FieldOrNull(f, "message")}).ToString()); Console.Error.Write('\\n'); return BallValue.Null; }})",
            _ => Unsupported(call),
        };
    }

    // ════════════════════════════════════════════════════════════
    // ball_proto — protobuf-compat AST access patterns (issue #383)
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// Route a <c>ball_proto.&lt;fn&gt;</c> base call to its native
    /// <see cref="BallProto"/> implementation — the AST-inspection functions the
    /// self-hosted engine reads every target program through (oneof
    /// discriminators, presence checks, safe field/Struct access, proto3
    /// defaults). Mirrors <c>rust/compiler/src/base_call.rs</c>'s
    /// <c>compile_ball_proto_call</c>. The single <c>obj</c> argument arrives as
    /// a <c>MessageCreation</c> field named <c>obj</c> (invariant #1's named-arg
    /// convention), so it is read via <see cref="Fields.Extract"/> like every
    /// other base call.
    /// </summary>
    private string CompileBallProtoCall(FunctionCall call)
    {
        var f = Fields.Extract(call);
        string Obj() => FieldOrNull(f, "obj");

        switch (call.Function)
        {
            // Oneof discriminators.
            case "whichExpr":
                return $"BallProto.WhichExpr({Obj()})";
            case "whichValue":
                return $"BallProto.WhichValue({Obj()})";
            case "whichStmt":
                return $"BallProto.WhichStmt({Obj()})";
            case "whichKind":
                return $"BallProto.WhichKind({Obj()})";
            case "whichSource":
                return $"BallProto.WhichSource({Obj()})";

            // Safe field access.
            case "getField":
                return $"BallProto.GetField({Obj()}, {FieldOrNull(f, "name")})";
            case "getFieldOr":
                return $"BallProto.GetFieldOr({Obj()}, {FieldOrNull(f, "name")}, {FieldOrNull(f, "defaultValue")})";
            case "setField":
                return $"BallProto.SetField({Obj()}, {FieldOrNull(f, "name")}, {FieldOrNull(f, "value")})";

            // Struct field access.
            case "getStructField":
                return $"BallProto.GetStructField({FieldOrNull(f, "struct")}, {FieldOrNull(f, "key")})";
            case "getStringField":
                return $"BallProto.GetStringField({FieldOrNull(f, "struct")}, {FieldOrNull(f, "key")})";
            case "getBoolField":
                return $"BallProto.GetBoolField({FieldOrNull(f, "struct")}, {FieldOrNull(f, "key")})";
            case "getListField":
                return $"BallProto.GetListField({FieldOrNull(f, "struct")}, {FieldOrNull(f, "key")})";
            case "getNumberField":
                return $"BallProto.GetNumberField({FieldOrNull(f, "struct")}, {FieldOrNull(f, "key")})";
            case "getStructFieldKeys":
                return $"BallProto.GetStructFieldKeys({FieldOrNull(f, "struct")})";

            // Proto3 defaults.
            case "ensureDefaults":
                return $"BallProto.EnsureDefaults({Obj()}, {FieldOrNull(f, "messageType")})";
            case "defaultString":
                return "BallProto.DefaultString()";
            case "defaultList":
                return "BallProto.DefaultList()";
            case "defaultBool":
                return "BallProto.DefaultBool()";
            case "defaultInt":
                return "BallProto.DefaultInt()";

            // Case-name validators — the engine reads them back as the name.
            case "exprCase":
                return $"BallProto.ExprCase({FieldOrNull(f, "name")})";
            case "literalCase":
                return $"BallProto.LiteralCase({FieldOrNull(f, "name")})";
            case "stmtCase":
                return $"BallProto.StmtCase({FieldOrNull(f, "name")})";
        }

        // Presence checks: `has<Field>(obj)` → whether the named field is set.
        if (call.Function.StartsWith("has", StringComparison.Ordinal) && call.Function.Length > 3)
        {
            var field = LowerFirst(call.Function[3..]);
            return $"BallProto.HasField({Obj()}, {Naming.StringLiteral(field)})";
        }

        return Unsupported(call);
    }

    /// <summary>Lowercase the first character of <paramref name="s"/> (<c>"Body"</c> → <c>"body"</c>).</summary>
    private static string LowerFirst(string s) =>
        s.Length == 0 ? s : char.ToLowerInvariant(s[0]) + s[1..];

    // ════════════════════════════════════════════════════════════
    // Message-list helpers (switch cases / try catches)
    // ════════════════════════════════════════════════════════════

    /// <summary>The <see cref="MessageCreation"/> elements of a repeated field encoded as a list literal.</summary>
    private static List<MessageCreation> MessageList(OrderedDictionary<string, Expression> fields, string key)
    {
        var result = new List<MessageCreation>();
        if (!fields.TryGetValue(key, out var expr)
            || expr.ExprCase != Expression.ExprOneofCase.Literal
            || expr.Literal.ValueCase != Literal.ValueOneofCase.ListValue)
        {
            return result;
        }

        foreach (var element in expr.Literal.ListValue.Elements)
        {
            if (element.ExprCase == Expression.ExprOneofCase.MessageCreation)
            {
                result.Add(element.MessageCreation);
            }
        }

        return result;
    }

    private static OrderedDictionary<string, Expression> MessageCreationFields(MessageCreation mc)
    {
        var fields = new OrderedDictionary<string, Expression>();
        foreach (var pair in mc.Fields)
        {
            fields[pair.Name] = pair.Value ?? new Expression();
        }

        return fields;
    }
}
