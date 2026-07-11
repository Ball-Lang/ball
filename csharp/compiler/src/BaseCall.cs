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
                return CompileSwitchStatement(call);
            // `switch_expr` is expression-valued (it yields a case's result), so
            // it is never a plain statement — it falls through to the expression
            // path (a discarded `_ = <Run(...)>`).
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
            case "std_convert":
                return CompileConvertCall(call);
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
            case "switch_expr":
                return CompileSwitchExpression(call);
            case "for":
            case "for_in":
            case "for_each":
            case "while":
            case "do_while":
            case "switch":
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
            "string_code_unit_at" => Compile2("StringCodeUnitAt", f, "value", "index", "value", "index"),
            "string_runes" => Un("StringRunes", f),
            // Collection / record / invoke construction
            "typed_list" => f.ContainsKey("elements") ? FieldOrNull(f, "elements") : "(BallValue)new BallList()",
            "set_create" => $"BallRuntime.SetCreate({FieldAliasOrNull(f, new[] { "elements", "list", "set" })})",
            "map_create" => CompileMapCreate(call),
            "record" => call.Input is null ? "(BallValue)new BallMap()" : CompileExpression(call.Input),
            "invoke" => $"BallRuntime.Invoke({(call.Input is null ? "BallValue.Null" : CompileExpression(call.Input))})",
            // Identity leaves
            "paren" or "await" => FieldOrNull(f, "value"),
            "spread" or "null_spread" => FieldOrNull(f, "value"),
            "null_aware_index" => $"BallRuntime.IndexGet({FieldOrNull(f, "target")}, {FieldOrNull(f, "index")})",
            // Type operations
            "is" => $"BallRuntime.IsType({FieldOrNull(f, "value")}, {Naming.StringLiteral(StringField(f, "type") ?? string.Empty)})",
            "is_not" => $"BallRuntime.IsNotType({FieldOrNull(f, "value")}, {Naming.StringLiteral(StringField(f, "type") ?? string.Empty)})",
            "as" => $"BallRuntime.AsType({FieldOrNull(f, "value")}, {Naming.StringLiteral(StringField(f, "type") ?? string.Empty)})",
            // Math
            "math_abs" => Un("MathAbs", f),
            "math_floor" => Un("MathFloor", f),
            "math_ceil" => Un("MathCeil", f),
            "math_round" => Un("MathRound", f),
            "math_trunc" => Un("MathTrunc", f),
            "math_sign" => Un("MathSign", f),
            "math_is_finite" => Un("MathIsFinite", f),
            "math_is_infinite" => Un("MathIsInfinite", f),
            "math_gcd" => Bin("MathGcd", f),
            "math_clamp" => Tri("MathClamp", f, "value", "min", "max"),
            "ceil_to_double" => Un("CeilToDouble", f),
            "floor_to_double" => Un("FloorToDouble", f),
            "round_to_double" => Un("RoundToDouble", f),
            "truncate_to_double" => Un("TruncateToDouble", f),
            "to_string_as_fixed" => Compile2("ToStringAsFixed", f, "value", "digits", "value", "digits"),
            "to_string_as_precision" => Compile2("ToStringAsPrecision", f, "value", "precision", "value", "precision"),
            "to_string_as_exponential" => $"BallRuntime.ToStringAsExponential({FieldOrNull(f, "value")}, {FieldOrNull(f, "digits")})",
            _ => Unsupported(call),
        };
    }

    /// <summary>
    /// <c>map_create</c> — build a map from the input's entry fields. The fast
    /// path (every field a plain <c>entry</c> = <c>{key, value}</c> message)
    /// emits a direct <c>BallRuntime.MapCreate([[k, v], …])</c>. A map
    /// <b>comprehension</b> instead carries an <c>element</c> field wrapping a
    /// <c>std.spread</c>/<c>collection_if</c>/<c>collection_for</c>; those must be
    /// <b>spliced</b>, not dropped — the missing map-literal splice (the analog of
    /// the Round-9 list-literal fix) silently emptied every internal comprehension
    /// map (e.g. <c>_toJsonSafe</c>'s <c>{ for (e in m.entries) … }</c>).
    /// Mirrors the reference engine's <c>_evalLazyMapCreate</c>.
    /// </summary>
    private string CompileMapCreate(FunctionCall call)
    {
        if (call.Input is not { ExprCase: Expression.ExprOneofCase.MessageCreation } input)
        {
            return "BallRuntime.MapCreate((BallValue)new BallList())";
        }

        var fields = input.MessageCreation.Fields;
        if (!fields.Any(f => f.Name == "element"))
        {
            // Fast path: plain {key, value} entries only.
            var pairs = new List<string>();
            foreach (var field in fields)
            {
                if (field.Name == "entry" && field.Value is { ExprCase: Expression.ExprOneofCase.MessageCreation } entry)
                {
                    var ef = MessageCreationFields(entry.MessageCreation);
                    pairs.Add($"(BallValue)new BallList(new BallValue[] {{ {FieldOrNull(ef, "key")}, {FieldOrNull(ef, "value")} }})");
                }
            }

            var list = pairs.Count == 0 ? "new BallList()" : $"new BallList(new BallValue[] {{ {string.Join(", ", pairs)} }})";
            return $"BallRuntime.MapCreate((BallValue){list})";
        }

        // Comprehension path: build imperatively so element splices apply.
        var mapVar = $"__map{_tempCounter++}";
        var sb = new System.Text.StringBuilder($"Run(() =>\n{{\nvar {mapVar} = new BallMap();\n");
        foreach (var field in fields)
        {
            switch (field.Name)
            {
                case "entry" or "entries":
                    sb.Append($"BallRuntime.MapAddEntry({mapVar}, {CompileExpression(field.Value)});\n");
                    break;
                case "element":
                    sb.Append(CompileMapCollectionElement(mapVar, field.Value));
                    break;
                    // type_args and any unknown field: ignore (as the reference engine does).
            }
        }

        sb.Append($"return (BallValue){mapVar};\n}})");
        return sb.ToString();
    }

    /// <summary>
    /// Emit code splicing one map-literal <c>element</c> into <paramref name="target"/>
    /// (a <see cref="Ball.Shared.BallMap"/> local): a <c>spread</c>/<c>null_spread</c>
    /// merges a map, a <c>collection_if</c> conditionally emits its then/else
    /// element, a <c>collection_for</c> loops, and a leaf <c>{key, value}</c> entry
    /// is added. Nested element forms recurse. The map analog of
    /// <see cref="CompileCollectionElement"/>.
    /// </summary>
    private string CompileMapCollectionElement(string target, Expression el)
    {
        var kind = CollectionElementKind(el);
        if (kind is null)
        {
            return $"BallRuntime.MapAddEntry({target}, {CompileExpression(el)});\n";
        }

        var f = Fields.Extract(el.Call);
        var uid = _tempCounter++;
        switch (kind)
        {
            case "spread":
                return $"BallRuntime.MapSpread({target}, {FieldOrNull(f, "value")});\n";
            case "null_spread":
                return $"{{ var __ms{uid} = {FieldOrNull(f, "value")}; if (__ms{uid} is not Ball.Shared.BallNull) {{ BallRuntime.MapSpread({target}, __ms{uid}); }} }}\n";
            case "collection_if":
                {
                    var cond = f.TryGetValue("condition", out var c)
                        ? $"BallRuntime.Truthy({CompileExpression(c)})"
                        : "false";
                    var then = f.TryGetValue("then", out var t) ? CompileMapCollectionElement(target, t) : string.Empty;
                    if (f.TryGetValue("else", out var e))
                    {
                        var els = CompileMapCollectionElement(target, e);
                        return $"if ({cond})\n{{\n{then}}}\nelse\n{{\n{els}}}\n";
                    }

                    return $"if ({cond})\n{{\n{then}}}\n";
                }

            case "collection_for":
                return CompileMapCollectionFor(target, f);
            default:
                throw new InvalidOperationException($"unexpected collection element kind: {kind}");
        }
    }

    /// <summary>The map analog of <see cref="CompileCollectionFor"/> — each produced value is spliced as a map element.</summary>
    private string CompileMapCollectionFor(string target, OrderedDictionary<string, Expression> f)
    {
        if (f.TryGetValue("iterable", out var iterable))
        {
            var variable = StringField(f, "variable") ?? "item";
            PushScope();
            var loopVar = BindLocal(variable);
            var body = f.TryGetValue("body", out var forBody)
                ? CompileMapCollectionElement(target, forBody)
                : string.Empty;
            PopScope();
            return $"foreach (var {loopVar} in BallRuntime.Iterate({CompileExpression(iterable)}))\n{{\n{body}}}\n";
        }

        PushScope();
        var cfid = _tempCounter++;
        var init = f.TryGetValue("init", out var initExpr) ? $"var __mcfInit{cfid} = {CompileExpression(initExpr)};\n" : string.Empty;
        var cond = f.TryGetValue("condition", out var condExpr)
            ? $"BallRuntime.Truthy({CompileExpression(condExpr)})"
            : "true";
        var bodyC = f.TryGetValue("body", out var cBody) ? CompileMapCollectionElement(target, cBody) : string.Empty;
        var update = f.TryGetValue("update", out var updExpr) ? $"{CompileExpression(updExpr)};\n" : string.Empty;
        PopScope();
        return $"{{\n{init}while ({cond})\n{{\n{bodyC}{update}}}\n}}\n";
    }

    /// <summary><c>std_convert</c> — UTF-8 / base64 codecs.</summary>
    private string CompileConvertCall(FunctionCall call)
    {
        var f = Fields.Extract(call);
        return call.Function switch
        {
            "utf8_encode" => Un("Utf8Encode", f),
            "utf8_decode" => Un("Utf8Decode", f),
            "base64_encode" => Un("Base64Encode", f),
            "base64_decode" => Un("Base64Decode", f),
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
                sb.Append($"var {BindLocal(let.Name)} = {value};\n");
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
        var loopVar = BindLocal(variable);
        var bodyCode = EmitBranch(f, "body");
        PopScope();
        return $"foreach (var {loopVar} in BallRuntime.Iterate({iterableCode}))\n{{\n{bodyCode}\n}}";
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
        // A unique subject temp — nested switches share the same `do {…} while(false)`
        // block nesting, so a fixed name would collide (CS0136).
        var subjVar = $"__subj{_tempCounter++}";
        var sb = new StringBuilder($"do\n{{\nvar {subjVar} = {subject};\n");
        var first = true;
        MessageCreation? defaultCase = null;
        // Dart switch cases fall through when a case carries NO body: an
        // encoded `case 'a': case 'b': <stmt>` gives 'a'/'b' empty bodies and
        // attaches <stmt> only to the last label. Emitting each as an
        // independent if/else-if drops that shared body — a bare `case 'a':`
        // would match and do nothing (this silently broke every `++`/`--`,
        // whose engine dispatch is one such multi-label case). Accumulate the
        // empty-body labels and OR them into the next body-carrying case.
        var pending = new List<string>();
        foreach (var caseMc in cases)
        {
            var cf = MessageCreationFields(caseMc);
            if (BoolField(cf, "is_default"))
            {
                defaultCase = caseMc;
                continue;
            }

            var condition = CompileCaseCondition(subjVar, cf);
            var body = cf.TryGetValue("body", out var b) ? EmitStatementUnwrapped(b) : string.Empty;
            if (string.IsNullOrWhiteSpace(body))
            {
                // Fall-through label — Dart encodes a bare `case 'a':` (that shares
                // the next case's statements) with an empty body. Defer its
                // condition to the next body-carrying case.
                pending.Add(condition);
                continue;
            }

            pending.Add(condition);
            var combined = string.Join(" || ", pending);
            pending.Clear();
            sb.Append($"{(first ? "if" : "else if")} ({combined})\n{{\n{body}\n}}\n");
            first = false;
        }
        // Any trailing fall-through labels with no following body fall through to
        // the `else` default (or are a no-op when there is none) — exactly the C#
        // control flow when their conditions are simply omitted here.

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
    /// <c>switch_expr(subject, cases)</c> in value position — a <c>Run</c> IIFE
    /// that <c>return</c>s the first matching case's body value (a Dart switch
    /// <em>expression</em>). Cases carry a <c>pattern</c> (the constant to match)
    /// and a <c>body</c> (the result expression); the default case (<c>is_default</c>)
    /// is the trailing fallback.
    /// </summary>
    private string CompileSwitchExpression(FunctionCall call)
    {
        var f = Fields.Extract(call);
        var subject = FieldOrNull(f, "subject");
        var cases = MessageList(f, "cases");
        var subjVar = $"__subj{_tempCounter++}";
        var sb = new StringBuilder($"Run(() =>\n{{\nvar {subjVar} = {subject};\n");
        MessageCreation? defaultCase = null;
        foreach (var caseMc in cases)
        {
            var cf = MessageCreationFields(caseMc);
            if (BoolField(cf, "is_default"))
            {
                defaultCase = caseMc;
                continue;
            }

            var condition = CompileCaseCondition(subjVar, cf);
            var body = cf.TryGetValue("body", out var b) ? CompileExpression(b) : "BallValue.Null";
            sb.Append($"if ({condition}) return {body};\n");
        }

        if (defaultCase is not null)
        {
            var cf = MessageCreationFields(defaultCase);
            sb.Append($"return {(cf.TryGetValue("body", out var db) ? CompileExpression(db) : "BallValue.Null")};\n");
        }
        else
        {
            sb.Append("return BallValue.Null;\n");
        }

        sb.Append("})");
        return sb.ToString();
    }

    /// <summary>
    /// A C# boolean match condition for a switch case over <paramref name="subjVar"/>.
    /// Prefers the semantic <c>pattern_expr</c> (a Dart-3 structured pattern —
    /// <c>WildcardPattern</c>/<c>LogicalOrPattern</c>/<c>ConstPattern</c>) over
    /// the cosmetic source-text <c>pattern</c> (which the encoder stores as a raw
    /// string like <c>"'std' || 'std_collections'"</c> that would never match).
    /// </summary>
    private string CompileCaseCondition(string subjVar, OrderedDictionary<string, Expression> cf)
    {
        if (cf.TryGetValue("pattern_expr", out var patternExpr))
        {
            return CompileSwitchPattern(subjVar, patternExpr);
        }

        return $"BallValue.ValueEquals({subjVar}, {FieldAliasOrNull(cf, new[] { "pattern", "value" })})";
    }

    /// <summary>Compile a Dart-3 structured pattern into a C# boolean match condition over <paramref name="subjVar"/>.</summary>
    private string CompileSwitchPattern(string subjVar, Expression patternExpr)
    {
        if (patternExpr.ExprCase == Expression.ExprOneofCase.MessageCreation)
        {
            var mc = patternExpr.MessageCreation;
            var fields = MessageCreationFields(mc);
            switch (Naming.TypeShortName(mc.TypeName))
            {
                case "WildcardPattern":
                    return "true";
                case "LogicalOrPattern":
                    return $"({CompileSwitchPattern(subjVar, fields["left"])} || {CompileSwitchPattern(subjVar, fields["right"])})";
                case "LogicalAndPattern":
                    return $"({CompileSwitchPattern(subjVar, fields["left"])} && {CompileSwitchPattern(subjVar, fields["right"])})";
                case "ConstPattern":
                    return $"BallValue.ValueEquals({subjVar}, {(fields.TryGetValue("value", out var cv) ? CompileExpression(cv) : "BallValue.Null")})";
            }
        }

        // An unstructured / unrecognized pattern: compare the subject to its value.
        return $"BallValue.ValueEquals({subjVar}, {CompileExpression(patternExpr)})";
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
            var stackVariable = StringField(cf, "stack_trace");
            PushScope();
            sb.Append("catch (BallThrow __ballEx)\n{\n");
            if (!string.IsNullOrEmpty(variable))
            {
                sb.Append($"var {BindLocal(variable)} = __ballEx.Payload;\n");
            }

            // A two-variable `catch (e, stackTrace)` binds the caught trace too —
            // the C# analog of Dart's StackTrace (the CLR-populated one on the
            // caught BallThrow), so a reference to it inside the body resolves
            // instead of falling through to an UnresolvedReference (issue #383).
            if (!string.IsNullOrEmpty(stackVariable))
            {
                sb.Append($"var {BindLocal(stackVariable)} = BallRuntime.CaughtStackTrace(__ballEx);\n");
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
        NullAwareIndex,
        Unsupported,
    }

    private readonly record struct LValue(LValueKind Kind, string A, string B);

    private LValue ResolveLValue(Expression target)
    {
        switch (target.ExprCase)
        {
            case Expression.ExprOneofCase.Reference:
                // Resolve through the (possibly renamed) local so an assignment
                // targets the same C# identifier the reference reads.
                if (LocalName(target.Reference.Name) is { } boundLocal)
                {
                    return new LValue(LValueKind.Var, boundLocal, string.Empty);
                }

                // A reassigned ("volatile") instance field with no shadowing local
                // is written LIVE through the receiver (FieldSet), so the rebind is
                // observed across method/closure boundaries mid-run (issue #383).
                if (_inInstanceMethod && _selfRecvName is { } selfWrite && _volatileFields.Contains(target.Reference.Name))
                {
                    return new LValue(LValueKind.Field, selfWrite, target.Reference.Name);
                }

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
                // `target?[index] = value` short-circuits: when `target` is null,
                // the whole assignment is skipped (and `value` never evaluated),
                // yielding null — distinct from the unconditional plain index-set.
                var idxKind = target.Call.Function == "null_aware_index"
                    ? LValueKind.NullAwareIndex
                    : LValueKind.Index;
                return new LValue(idxKind, targetCode, indexCode);
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
            case LValueKind.NullAwareIndex:
                // `target?[index] = value` — bind the receiver once, and when it
                // is null skip the assignment (never evaluating `value`), yielding
                // null; otherwise write through the non-null receiver.
                var naTmp = $"__na{_tempCounter++}";
                var naCurrent = $"BallRuntime.IndexGet({naTmp}, {lv.B})";
                return $"Run(() => {{ var {naTmp} = {lv.A}; return {naTmp} is BallNull ? BallValue.Null "
                    + $": BallRuntime.IndexSet({naTmp}, {lv.B}, {CombineOp(op, naCurrent, valueCode)}); }})";
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
            // Higher-order (a callback/comparator in the `value` field)
            "list_map" => $"BallRuntime.ListMap({FieldOrNull(f, "list")}, {FieldOrNull(f, "value")})",
            "list_filter" => $"BallRuntime.ListFilter({FieldOrNull(f, "list")}, {FieldOrNull(f, "value")})",
            "list_all" => $"BallRuntime.ListAll({FieldOrNull(f, "list")}, {FieldOrNull(f, "value")})",
            "list_any" => $"BallRuntime.ListAny({FieldOrNull(f, "list")}, {FieldOrNull(f, "value")})",
            "list_sort" => $"BallRuntime.ListSort({FieldOrNull(f, "list")}, {FieldOrNull(f, "value")})",
            "list_join" => $"BallRuntime.ListJoin({FieldOrNull(f, "list")}, {FieldOrNull(f, "separator")})",
            "list_to_list" => $"BallRuntime.ListToList({FieldOrNull(f, "list")})",
            "map_contains_value" => $"BallRuntime.MapContainsValue({FieldOrNull(f, "map")}, {FieldOrNull(f, "value")})",
            "map_put_if_absent" => $"BallRuntime.MapPutIfAbsent({FieldOrNull(f, "map")}, {FieldOrNull(f, "key")}, {FieldOrNull(f, "value")})",
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
