using System.Collections.Generic;
using System.Linq;
using Ball.V1;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>
/// Invocation and member-access dispatch: <c>Console.WriteLine</c>/<c>Math.*</c> → universal
/// <c>std</c> calls; string/LINQ-lite methods (<c>.ToUpper()</c>, <c>.Select(f)</c>, ...) →
/// <c>std</c>/<c>std_collections</c> calls; a same-file user function/instance-method call;
/// string interpolation (<c>$"...{expr}..."</c>) → a <c>std.concat</c>/<c>to_string</c> tree;
/// lambdas → <see cref="FunctionDefinition"/> with an empty name (a Ball <c>lambda</c>
/// expression). No <c>csharp_std</c> module anywhere in this file — every arm routes through
/// <c>std</c>/<c>std_collections</c>.
///
/// ## Name-based dispatch is inherently ambiguous without a semantic model
///
/// Like every syntax-only encoder (see <c>.claude/rules/dart.md</c>'s "syntactic-encoder
/// gotchas" and <c>rust/encoder/src/methods.rs</c>'s own module doc comment), a few C# method
/// names collide across receiver types this encoder cannot statically distinguish —
/// <c>.Contains(x)</c> and <c>.IndexOf(x)</c> always route to the STRING op
/// (<c>string_contains</c>/<c>string_index_of</c>); <c>.Remove(x)</c> always routes to the MAP
/// op (<c>map_delete</c>). A non-matching receiver throws at run time (same risk profile as
/// every other reference encoder's unconditional name routes) rather than silently
/// miscompiling.
/// </summary>
internal sealed partial class Encoder
{
    /// <summary>Every instance method's short name → its own (non-<c>self</c>) parameter
    /// names, collapsed across ALL declared classes (last write wins on a same-named-method
    /// collision across two unrelated classes — mirrors
    /// <c>rust/encoder/src/lib.rs::Encoder::method_params</c>'s identical short-name-only
    /// keying, justified there by the fact that the reference engine's own dispatch table
    /// (<c>_typeMethodDispatch</c> in <c>dart/engine/lib/engine.dart</c>) resolves purely by
    /// short method name plus the receiver's *runtime* type — never by any static type this
    /// syntax-only encoder could know at a call site).</summary>
    internal readonly Dictionary<string, List<string>> AnyMethodParams = new();

    /// <summary>A local variable's name → the lambda it was initialized with's own declared
    /// parameter names — so a later bare call through that variable
    /// (<c>var f = (a, b) =&gt; a + b; f(1, 2);</c>) packs its call site under the lambda's
    /// real parameter names rather than a positional <c>arg0</c>/<c>arg1</c> fallback. Populated
    /// in <see cref="EncodeLocalDeclaration"/>. Flat (not scope-stack-aware) — a documented,
    /// narrow simplification: a shadowing local of the same name in a nested scope overwrites
    /// the outer one's entry, which only matters for 2+-parameter lambdas reassigned under a
    /// shadowed name, a vanishingly rare shape.</summary>
    private readonly Dictionary<string, List<string>> _localLambdaParams = new();

    internal void RecordLocalLambda(string name, ExpressionSyntax? initializer)
    {
        var paramNames = initializer switch
        {
            ParenthesizedLambdaExpressionSyntax p => p.ParameterList.Parameters.Select(x => x.Identifier.Text).ToList(),
            SimpleLambdaExpressionSyntax s => new List<string> { s.Parameter.Identifier.Text },
            _ => (List<string>?)null,
        };
        if (paramNames is not null)
        {
            _localLambdaParams[name] = paramNames;
        }
    }

    // ════════════════════════════════════════════════════════════
    // Invocation dispatch
    // ════════════════════════════════════════════════════════════

    internal Expression EncodeInvocation(InvocationExpressionSyntax invocation)
    {
        var argExprs = invocation.ArgumentList.Arguments.Select(a => a.Expression).ToList();
        return invocation.Expression switch
        {
            IdentifierNameSyntax id => EncodeBareCall(id.Identifier.Text, argExprs),
            MemberAccessExpressionSyntax member => EncodeMemberInvocation(member, argExprs),
            _ => throw new EncoderException(
                $"ball-encoder: unsupported call target `{invocation.Expression.Kind()}`: {invocation.Expression}"),
        };
    }

    /// <summary>Pack <paramref name="argExprs"/> as a call's <c>input</c>: no args → null; one
    /// arg → the bare encoded expression (no wrapping — matches every reference encoder's
    /// single-argument convention); 2+ args → a <c>MessageCreation</c> keyed by
    /// <paramref name="paramNames"/> (falling back to positional <c>arg0</c>/<c>arg1</c> when
    /// the count doesn't match or no names are known).</summary>
    private Expression? PackArgs(IReadOnlyList<ExpressionSyntax> argExprs, IReadOnlyList<string>? paramNames)
    {
        if (argExprs.Count == 0)
        {
            return null;
        }

        if (argExprs.Count == 1)
        {
            return EncodeExpr(argExprs[0]);
        }

        var names = paramNames is not null && paramNames.Count == argExprs.Count
            ? paramNames
            : Enumerable.Range(0, argExprs.Count).Select(i => $"arg{i}").ToList();
        var fields = names.Zip(argExprs, (n, a) => (n, EncodeExpr(a))).ToArray();
        return Builders.ArgsMessage(fields);
    }

    /// <summary>A bare (unqualified) call — resolved in priority order: (1) a known local
    /// (param/let/foreach/catch variable, possibly holding a lambda — the reference engine's
    /// own scope-first dispatch in <c>_evalCall</c> handles "is this actually a closure value"
    /// at run time, so this encoder never needs to decide); (2) an unqualified call to a
    /// STATIC sibling method of the class whose body is currently being encoded (covers
    /// same-class recursion, e.g. a static <c>Fib</c> calling itself by bare name); (3) an
    /// implicit <c>this.Method(...)</c> call to an INSTANCE sibling method; (4) a plain
    /// same-module user call (covers top-level-statement helper calls and any other
    /// same-file name).</summary>
    private Expression EncodeBareCall(string name, List<ExpressionSyntax> argExprs)
    {
        if (IsKnownLocal(name))
        {
            var lambdaParams = _localLambdaParams.TryGetValue(name, out var lp) ? lp : null;
            return Builders.UserCall(name, PackArgs(argExprs, lambdaParams));
        }

        if (_currentOwnerShort is not null &&
            StaticMethodParams.TryGetValue((_currentOwnerShort, name), out var staticParams))
        {
            return Builders.UserCall(StaticFunctionName(_currentOwnerShort, name), PackArgs(argExprs, staticParams));
        }

        if (_currentInstanceOwner is not null &&
            MethodParams.TryGetValue((_currentInstanceOwner, name), out var instanceParams))
        {
            return EncodeMethodCallOnReceiver(Builders.ReferenceExpr("self"), name, argExprs, instanceParams);
        }

        return Builders.UserCall(name, PackArgs(argExprs, null));
    }

    private Expression EncodeMemberInvocation(MemberAccessExpressionSyntax member, List<ExpressionSyntax> argExprs)
    {
        var methodName = member.Name.Identifier.Text;

        if (member.Expression is IdentifierNameSyntax recv &&
            !IsKnownLocal(recv.Identifier.Text) &&
            !IsKnownField(recv.Identifier.Text))
        {
            switch (recv.Identifier.Text)
            {
                case "Console":
                    return EncodeConsoleCall(methodName, argExprs);
                case "Math":
                    return EncodeMathCall(methodName, argExprs);
            }

            if (ClassNames.ContainsKey(recv.Identifier.Text) &&
                StaticMethodParams.TryGetValue((recv.Identifier.Text, methodName), out var staticParams))
            {
                return Builders.UserCall(
                    StaticFunctionName(recv.Identifier.Text, methodName),
                    PackArgs(argExprs, staticParams));
            }
        }

        var receiver = EncodeExpr(member.Expression);
        return DispatchInstanceOrBuiltinMethod(receiver, methodName, argExprs);
    }

    private Expression EncodeConsoleCall(string methodName, List<ExpressionSyntax> argExprs)
    {
        if (methodName is not ("WriteLine" or "Write"))
        {
            throw new EncoderException(
                $"ball-encoder: unsupported `Console.{methodName}(...)` (only `WriteLine`/`Write` " +
                "are supported — issue #382's scope; `Write` approximates to a newline-terminated " +
                "`std.print`, a documented gap for mixed Write/WriteLine output on one line)");
        }

        var message = argExprs.Count == 0
            ? Builders.StringLiteral("")
            : Builders.UnaryStd("to_string", EncodeExpr(argExprs[0]));
        return Builders.StdCall("print", Builders.NamedMessage("PrintInput", ("message", message)));
    }

    private Expression EncodeMathCall(string methodName, List<ExpressionSyntax> argExprs) => (methodName, argExprs.Count) switch
    {
        ("Abs", 1) => Builders.UnaryStd("math_abs", EncodeExpr(argExprs[0])),
        ("Floor", 1) => Builders.UnaryStd("math_floor", EncodeExpr(argExprs[0])),
        ("Ceiling", 1) => Builders.UnaryStd("math_ceil", EncodeExpr(argExprs[0])),
        ("Round", 1) => Builders.UnaryStd("math_round", EncodeExpr(argExprs[0])),
        ("Truncate", 1) => Builders.UnaryStd("math_trunc", EncodeExpr(argExprs[0])),
        ("Sqrt", 1) => Builders.UnaryStd("math_sqrt", EncodeExpr(argExprs[0])),
        ("Pow", 2) => Builders.BinaryStd("math_pow", EncodeExpr(argExprs[0]), EncodeExpr(argExprs[1])),
        ("Log", 1) => Builders.UnaryStd("math_log", EncodeExpr(argExprs[0])),
        ("Log2", 1) => Builders.UnaryStd("math_log2", EncodeExpr(argExprs[0])),
        ("Log10", 1) => Builders.UnaryStd("math_log10", EncodeExpr(argExprs[0])),
        ("Exp", 1) => Builders.UnaryStd("math_exp", EncodeExpr(argExprs[0])),
        ("Sin", 1) => Builders.UnaryStd("math_sin", EncodeExpr(argExprs[0])),
        ("Cos", 1) => Builders.UnaryStd("math_cos", EncodeExpr(argExprs[0])),
        ("Tan", 1) => Builders.UnaryStd("math_tan", EncodeExpr(argExprs[0])),
        ("Max", 2) => Builders.BinaryStd("math_max", EncodeExpr(argExprs[0]), EncodeExpr(argExprs[1])),
        ("Min", 2) => Builders.BinaryStd("math_min", EncodeExpr(argExprs[0]), EncodeExpr(argExprs[1])),
        _ => throw new EncoderException($"ball-encoder: unsupported `Math.{methodName}(...)` (issue #382's scope)"),
    };

    /// <summary>Dispatch <c>receiver.methodName(argExprs)</c> once the receiver has already
    /// been encoded — shared by a normal top-level invocation and a null-conditional access
    /// tail (<c>x?.Method(...)</c>, see <see cref="EncodeConditionalAccess"/>).</summary>
    private Expression DispatchInstanceOrBuiltinMethod(Expression receiver, string methodName, IReadOnlyList<ExpressionSyntax> argExprs)
    {
        switch (methodName, argExprs.Count)
        {
            // ── Identity passthroughs (no Ball-level effect) ──
            case ("ToList" or "ToArray" or "AsEnumerable" or "AsList", 0):
                return receiver;

            // ── String / universal conversions ──
            case ("ToString", 0):
                return Builders.UnaryStd("to_string", receiver);
            case ("ToUpper" or "ToUpperInvariant", 0):
                return Builders.UnaryStd("string_to_upper", receiver);
            case ("ToLower" or "ToLowerInvariant", 0):
                return Builders.UnaryStd("string_to_lower", receiver);
            case ("Trim", 0):
                return Builders.UnaryStd("string_trim", receiver);
            case ("TrimStart", 0):
                return Builders.UnaryStd("string_trim_start", receiver);
            case ("TrimEnd", 0):
                return Builders.UnaryStd("string_trim_end", receiver);
            case ("Contains", 1):
                return Builders.BinaryStd("string_contains", receiver, EncodeExpr(argExprs[0]));
            case ("StartsWith", 1):
                return Builders.BinaryStd("string_starts_with", receiver, EncodeExpr(argExprs[0]));
            case ("EndsWith", 1):
                return Builders.BinaryStd("string_ends_with", receiver, EncodeExpr(argExprs[0]));
            case ("IndexOf", 1):
                return Builders.BinaryStd("string_index_of", receiver, EncodeExpr(argExprs[0]));
            case ("Split", 1):
                MarkCollectionsUsed();
                return Builders.BinaryStd("string_split", receiver, EncodeExpr(argExprs[0]));
            case ("Replace", 2):
                return Builders.StdCall(
                    "string_replace_all",
                    Builders.ArgsMessage(("value", receiver), ("from", EncodeExpr(argExprs[0])), ("to", EncodeExpr(argExprs[1]))));
            case ("Substring", 1):
                return Builders.StdCall(
                    "string_substring",
                    Builders.ArgsMessage(("value", receiver), ("start", EncodeExpr(argExprs[0])), ("end", Builders.UnaryStd("length", receiver))));
            case ("Substring", 2):
                return EncodeSubstringWithLength(receiver, argExprs[0], argExprs[1]);
            case ("PadLeft", 1):
                return Builders.StdCall(
                    "string_pad_left",
                    Builders.ArgsMessage(("value", receiver), ("width", EncodeExpr(argExprs[0])), ("padding", Builders.StringLiteral(" "))));
            case ("PadLeft", 2):
                return Builders.StdCall(
                    "string_pad_left",
                    Builders.ArgsMessage(("value", receiver), ("width", EncodeExpr(argExprs[0])), ("padding", EncodeExpr(argExprs[1]))));
            case ("PadRight", 1):
                return Builders.StdCall(
                    "string_pad_right",
                    Builders.ArgsMessage(("value", receiver), ("width", EncodeExpr(argExprs[0])), ("padding", Builders.StringLiteral(" "))));
            case ("PadRight", 2):
                return Builders.StdCall(
                    "string_pad_right",
                    Builders.ArgsMessage(("value", receiver), ("width", EncodeExpr(argExprs[0])), ("padding", EncodeExpr(argExprs[1]))));

            // ── List mutation (List<T>-only method names — no collision risk) ──
            case ("Add", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_push", Builders.ArgsMessage(("list", receiver), ("value", EncodeExpr(argExprs[0]))));
            case ("RemoveAt", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_remove_at", Builders.ArgsMessage(("list", receiver), ("index", EncodeExpr(argExprs[0]))));
            case ("Insert", 2):
                MarkCollectionsUsed();
                return Builders.CollectionsCall(
                    "list_insert",
                    Builders.ArgsMessage(("list", receiver), ("index", EncodeExpr(argExprs[0])), ("value", EncodeExpr(argExprs[1]))));
            case ("Reverse", 0):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_reverse", Builders.ArgsMessage(("list", receiver)));
            case ("Sort", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_sort", Builders.ArgsMessage(("list", receiver), ("callback", EncodeExpr(argExprs[0]))));

            // ── Map (Dictionary<K,V>) — `.Remove(key)` wins the name collision with
            //    List<T>.Remove(item), documented in the module doc comment. ──
            case ("ContainsKey", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("map_contains_key", Builders.ArgsMessage(("map", receiver), ("key", EncodeExpr(argExprs[0]))));
            case ("Remove", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("map_delete", Builders.ArgsMessage(("map", receiver), ("key", EncodeExpr(argExprs[0]))));

            // ── LINQ-lite → std_collections ──
            case ("Select", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_map", Builders.ArgsMessage(("list", receiver), ("callback", EncodeExpr(argExprs[0]))));
            case ("Where", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_filter", Builders.ArgsMessage(("list", receiver), ("callback", EncodeExpr(argExprs[0]))));
            case ("Any", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_any", Builders.ArgsMessage(("list", receiver), ("callback", EncodeExpr(argExprs[0]))));
            case ("All", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_all", Builders.ArgsMessage(("list", receiver), ("callback", EncodeExpr(argExprs[0]))));
            case ("First" or "FirstOrDefault", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_find", Builders.ArgsMessage(("list", receiver), ("callback", EncodeExpr(argExprs[0]))));
            case ("First" or "FirstOrDefault", 0):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_first", Builders.ArgsMessage(("list", receiver)));
            case ("Take", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_take", Builders.ArgsMessage(("list", receiver), ("value", EncodeExpr(argExprs[0]))));
            case ("Skip", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_drop", Builders.ArgsMessage(("list", receiver), ("value", EncodeExpr(argExprs[0]))));
            case ("Aggregate", 2):
                MarkCollectionsUsed();
                return Builders.CollectionsCall(
                    "list_reduce",
                    Builders.ArgsMessage(("list", receiver), ("initial", EncodeExpr(argExprs[0])), ("callback", EncodeExpr(argExprs[1]))));
        }

        if (AnyMethodParams.TryGetValue(methodName, out var userParams))
        {
            return EncodeMethodCallOnReceiver(receiver, methodName, argExprs, userParams);
        }

        throw new EncoderException(
            $"ball-encoder: unsupported method call `.{methodName}(...)` with {argExprs.Count} " +
            "argument(s) (see the module doc comment — a user-defined instance method must be " +
            "declared in a same-file class this encoder also encodes)");
    }

    private Expression EncodeSubstringWithLength(Expression receiver, ExpressionSyntax startExpr, ExpressionSyntax lengthExpr)
    {
        const string tmp = "__ball_substring_start";
        var start = EncodeExpr(startExpr);
        var length = EncodeExpr(lengthExpr);
        var end = Builders.BinaryStd("add", Builders.ReferenceExpr(tmp), length);
        var call = Builders.StdCall(
            "string_substring",
            Builders.ArgsMessage(("value", receiver), ("start", Builders.ReferenceExpr(tmp)), ("end", end)));
        return Builders.BlockExpr(new List<Statement> { Builders.LetStmt(tmp, start) }, call);
    }

    /// <summary>Packs <paramref name="receiver"/> under a <c>"self"</c> field, then
    /// <paramref name="argExprs"/> under <paramref name="paramNames"/> (falling back to
    /// positional when the count doesn't match) — the exact shape the reference engine's
    /// <c>self</c>-carrying dispatch expects (see the module doc comment on
    /// <c>CSharpEncoder</c>).</summary>
    private Expression EncodeMethodCallOnReceiver(
        Expression receiver,
        string methodName,
        IReadOnlyList<ExpressionSyntax> argExprs,
        IReadOnlyList<string> paramNames)
    {
        var names = paramNames.Count == argExprs.Count
            ? paramNames
            : Enumerable.Range(0, argExprs.Count).Select(i => $"arg{i}").ToList();
        var fields = new List<(string Name, Expression Value)> { ("self", receiver) };
        fields.AddRange(names.Zip(argExprs, (n, a) => (n, EncodeExpr(a))));
        return Builders.UserCall(methodName, Builders.ArgsMessage(fields.ToArray()));
    }

    // ════════════════════════════════════════════════════════════
    // Member access / element access / null-conditional access
    // ════════════════════════════════════════════════════════════

    private Expression EncodeMemberAccess(MemberAccessExpressionSyntax member)
    {
        var memberName = member.Name.Identifier.Text;

        if (member.Expression is IdentifierNameSyntax typeId &&
            ClassNames.ContainsKey(typeId.Identifier.Text) &&
            !IsKnownLocal(typeId.Identifier.Text) &&
            !IsKnownField(typeId.Identifier.Text) &&
            memberName is not ("Length" or "Count" or "Keys" or "Values"))
        {
            throw new EncoderException(
                $"ball-encoder: static field access `{typeId.Identifier.Text}.{memberName}` is " +
                "not supported (only static METHOD calls are — issue #382's scope)");
        }

        return EncodePropertyAccess(EncodeExpr(member.Expression), memberName);
    }

    /// <summary>Shared by a normal (non-null-conditional) member access and a
    /// <see cref="EncodeConditionalTail"/> tail (<c>x?.Length</c>) — maps the small set of
    /// name-based property routes (<c>Length</c>/<c>Count</c> → the generic, receiver-type-
    /// polymorphic <c>std.length</c>; <c>Keys</c>/<c>Values</c> → <c>std_collections</c>) before
    /// falling back to a plain <c>field_access</c> for an instance field.</summary>
    private Expression EncodePropertyAccess(Expression receiver, string memberName)
    {
        switch (memberName)
        {
            case "Length" or "Count":
                return Builders.UnaryStd("length", receiver);
            case "Keys":
                MarkCollectionsUsed();
                return Builders.CollectionsCall("map_keys", Builders.ArgsMessage(("map", receiver)));
            case "Values":
                MarkCollectionsUsed();
                return Builders.CollectionsCall("map_values", Builders.ArgsMessage(("map", receiver)));
            default:
                return Builders.FieldAccessExpr(receiver, memberName);
        }
    }

    private Expression EncodeElementAccess(ElementAccessExpressionSyntax elem)
    {
        if (elem.ArgumentList.Arguments.Count != 1)
        {
            throw new EncoderException(
                "ball-encoder: multi-dimensional/multi-argument indexers are not supported " +
                "(issue #382's scope)");
        }

        var target = EncodeExpr(elem.Expression);
        var index = EncodeExpr(elem.ArgumentList.Arguments[0].Expression);
        return Builders.StdCall("index", Builders.ArgsMessage(("target", target), ("index", index)));
    }

    /// <summary>Expand <c>target?.tail</c> to <c>std.if(equals(target, null), null, tail)</c> —
    /// per the playbook's §3.3 null-conditional-access example, realized in this exact shape by
    /// the reference encoder (<c>dart/encoder/lib/encoder.dart::_buildNullAwareAccess</c>): a
    /// simple (identifier) target is guarded directly (no double evaluation risk); any other
    /// target is evaluated once into a <c>__ball_cond_access</c> temp first.</summary>
    private Expression EncodeConditionalAccess(ConditionalAccessExpressionSyntax condAccess)
    {
        if (condAccess.Expression is IdentifierNameSyntax simpleId)
        {
            var refExpr = EncodeExpr(simpleId);
            if (refExpr.ExprCase == Expression.ExprOneofCase.Reference)
            {
                var tail = EncodeConditionalTail(condAccess.WhenNotNull, refExpr);
                return NullGuard(refExpr, tail);
            }
        }

        const string tmp = "__ball_cond_access";
        var target = EncodeExpr(condAccess.Expression);
        var tailExpr = EncodeConditionalTail(condAccess.WhenNotNull, Builders.ReferenceExpr(tmp));
        var guarded = NullGuard(Builders.ReferenceExpr(tmp), tailExpr);
        return Builders.BlockExpr(new List<Statement> { Builders.LetStmt(tmp, target) }, guarded);
    }

    private static Expression NullGuard(Expression refExpr, Expression elseExpr) =>
        Builders.IfCall(Builders.BinaryStd("equals", refExpr, Builders.NullLiteral()), Builders.NullLiteral(), elseExpr);

    private Expression EncodeConditionalTail(ExpressionSyntax tail, Expression receiver) => tail switch
    {
        MemberBindingExpressionSyntax memberBinding => EncodePropertyAccess(receiver, memberBinding.Name.Identifier.Text),
        ElementBindingExpressionSyntax elementBinding when elementBinding.ArgumentList.Arguments.Count == 1 =>
            Builders.StdCall(
                "index",
                Builders.ArgsMessage(("target", receiver), ("index", EncodeExpr(elementBinding.ArgumentList.Arguments[0].Expression)))),
        InvocationExpressionSyntax invocation when invocation.Expression is MemberBindingExpressionSyntax mb =>
            DispatchInstanceOrBuiltinMethod(receiver, mb.Name.Identifier.Text, invocation.ArgumentList.Arguments.Select(a => a.Expression).ToList()),
        _ => throw new EncoderException(
            $"ball-encoder: unsupported null-conditional access tail `{tail.Kind()}` (chained " +
            $"`?.` beyond one level is a documented gap — issue #382's scope): `{tail}`"),
    };

    // ════════════════════════════════════════════════════════════
    // String interpolation
    // ════════════════════════════════════════════════════════════

    private Expression EncodeInterpolatedString(InterpolatedStringExpressionSyntax interp)
    {
        var parts = new List<Expression>();
        foreach (var content in interp.Contents)
        {
            switch (content)
            {
                case InterpolatedStringTextSyntax text:
                    var value = text.TextToken.ValueText;
                    if (value.Length > 0)
                    {
                        parts.Add(Builders.StringLiteral(value));
                    }

                    break;
                case InterpolationSyntax interpolation:
                    if (interpolation.AlignmentClause is not null || interpolation.FormatClause is not null)
                    {
                        throw new EncoderException(
                            "ball-encoder: interpolation alignment/format specifiers " +
                            "(e.g. `{x,5:F2}`) are not supported — only bare `{expr}` " +
                            "(issue #382's scope)");
                    }

                    parts.Add(Builders.UnaryStd("to_string", EncodeExpr(interpolation.Expression)));
                    break;
                default:
                    throw new EncoderException($"ball-encoder: unsupported interpolated-string content `{content.Kind()}`");
            }
        }

        if (parts.Count == 0)
        {
            return Builders.StringLiteral("");
        }

        var result = parts[0];
        for (var i = 1; i < parts.Count; i++)
        {
            result = Builders.BinaryStd("concat", result, parts[i]);
        }

        return result;
    }

    // ════════════════════════════════════════════════════════════
    // Lambdas
    // ════════════════════════════════════════════════════════════

    private Expression EncodeParenthesizedLambda(ParenthesizedLambdaExpressionSyntax lambda)
    {
        var paramNames = lambda.ParameterList.Parameters.Select(p => p.Identifier.Text).ToList();
        PushScope(paramNames);
        var body = EncodeLambdaBody(lambda.Body);
        PopScope();
        var metadata = paramNames.Count > 0 ? Builders.ParamsMetadata(paramNames) : null;
        return new Expression { Lambda = new FunctionDefinition { Name = "", Body = body, IsBase = false, Metadata = metadata } };
    }

    private Expression EncodeSimpleLambda(SimpleLambdaExpressionSyntax lambda)
    {
        var paramName = lambda.Parameter.Identifier.Text;
        PushScope(new[] { paramName });
        var body = EncodeLambdaBody(lambda.Body);
        PopScope();
        return new Expression
        {
            Lambda = new FunctionDefinition { Name = "", Body = body, IsBase = false, Metadata = Builders.ParamsMetadata(new[] { paramName }) },
        };
    }

    private Expression EncodeLambdaBody(Microsoft.CodeAnalysis.CSharp.CSharpSyntaxNode body) => body switch
    {
        BlockSyntax block => EncodeStatementsAsBlock(block.Statements),
        ExpressionSyntax expr => EncodeExpr(expr),
        _ => throw new EncoderException($"ball-encoder: unsupported lambda body shape `{body.Kind()}`"),
    };
}
