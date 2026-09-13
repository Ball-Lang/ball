using System;
using System.Collections.Generic;
using System.Linq;
using Ball.V1;
using Microsoft.CodeAnalysis;
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
/// ## Name-based dispatch is ambiguous — and that caveat is now SCOPED
///
/// A few C# method names collide across receiver types that syntax alone cannot distinguish:
/// <c>.Contains(x)</c> and <c>.IndexOf(x)</c> route to the STRING op
/// (<c>string_contains</c>/<c>string_index_of</c>); <c>.Remove(x)</c> routes to the MAP op
/// (<c>map_delete</c>). A non-matching receiver throws at run time (the same risk profile as
/// every other reference encoder's unconditional name routes) rather than silently
/// miscompiling.
///
/// <para><b>That is true of <see cref="CSharpEncoder.Encode"/> and
/// <see cref="CSharpEncoder.EncodeLibrary"/> only</b> (issue #492, W12-C slice 1). They are
/// resolution-free by contract — see <c>.claude/rules/dart.md</c>'s "syntactic-encoder gotchas"
/// and <c>rust/encoder/src/methods.rs</c>'s own module doc comment — and the coin flip is the
/// behaviour they have always documented.</para>
///
/// <para><b>Under <see cref="CSharpEncoder.EncodeProject"/> the answers are symbol-grade, so a
/// guess would be a silent fail-soft.</b> Two things change there, and only there: a call that
/// binds to a method THIS PROJECT declares takes the user-call path before this table is
/// consulted at all (<see cref="SourceSymbolCall"/> — which also retires the over-reach where a
/// user's own <c>.Contains</c> on their own type routed to <c>string_contains</c>), and a
/// receiver-discriminated name whose receiver does not bind, or binds to something the route
/// does not model, is a loud <see cref="EncoderException"/> naming the file, the position and
/// the reason (<see cref="GuardReceiverDiscriminatedCall"/>). Teaching the table to ROUTE by
/// receiver type rather than merely refuse is the next slice, and it wants a symbol-keyed route
/// table — (containing type, method name, parameter types) — not more predicates bolted onto
/// <c>(name, argc)</c> arms.</para>
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
        // `nameof(x)` is not a call at all — it is a compile-time constant the C# compiler has
        // already computed, and the model hands it over verbatim. Without one it encoded as an
        // unresolvable user call to a function named `nameof`, which is exactly why the
        // 2-argument `ArgumentNullException.ThrowIfNull(value, nameof(x))` overload had to stay
        // a loud refusal (see EncodeArgumentNullExceptionCall). `NullSemanticQuery` answers
        // null here, so the resolution-free path is untouched.
        if (invocation.Expression is IdentifierNameSyntax { Identifier.Text: "nameof" } &&
            invocation.ArgumentList.Arguments.Count == 1 &&
            _semantics.ConstantValue(invocation) is string constantName)
        {
            return Builders.StringLiteral(constantName);
        }

        var argExprs = invocation.ArgumentList.Arguments.Select(a => a.Expression).ToList();
        return invocation.Expression switch
        {
            IdentifierNameSyntax id => EncodeBareCall(invocation, id.Identifier.Text, argExprs),
            MemberAccessExpressionSyntax member => EncodeMemberInvocation(invocation, member, argExprs),
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
    private Expression EncodeBareCall(
        InvocationExpressionSyntax invocation, string name, List<ExpressionSyntax> argExprs)
    {
        if (IsKnownLocal(name))
        {
            var lambdaParams = _localLambdaParams.TryGetValue(name, out var lp) ? lp : null;
            return Builders.UserCall(name, PackArgs(argExprs, lambdaParams));
        }

        // A model resolves the cases the priority list below can only guess at: a `using
        // static` import, and a static or instance member inherited from a base class declared
        // in another file. A local still wins (checked above), exactly as C#'s own shadowing
        // rule says it must.
        if (SourceSymbolCall(invocation, receiver: null, argExprs) is { } resolved)
        {
            return resolved;
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

    private Expression EncodeMemberInvocation(
        InvocationExpressionSyntax invocation,
        MemberAccessExpressionSyntax member,
        List<ExpressionSyntax> argExprs)
    {
        var methodName = member.Name.Identifier.Text;

        // SYMBOL FIRST. When the call binds to a method this project itself declares, the
        // symbol answers everything the name/arity table can only approximate: which file the
        // callee is in, whether it is static, its real parameter names, and — for an extension
        // method — the unreduced static signature the receiver is really the first argument of.
        // This also retires a live over-reach: a user's own `.Contains(x)` on their own type
        // used to route unconditionally to `std.string_contains`; a source symbol now wins.
        if (SourceSymbolCall(invocation, member.Expression, argExprs) is { } resolved)
        {
            return resolved;
        }

        // A PREDEFINED type receiver (`int.Parse(...)`) is its own path: `int` is
        // a keyword-type node, never an `IdentifierNameSyntax`, so it can never
        // collide with a local or field and needs no shadowing check — and an
        // unmapped member on one must name the receiver in its error rather than
        // falling through to the generic "unsupported expression kind
        // `PredefinedType`" the bare receiver would produce.
        if (member.Expression is PredefinedTypeSyntax predefined)
        {
            return EncodePredefinedTypeStaticCall(predefined.Keyword.Text, methodName, argExprs);
        }

        if (StaticReceiverName(member.Expression) is { } receiverName)
        {
            switch (receiverName)
            {
                case "Console":
                    return EncodeConsoleCall(methodName, argExprs);
                case "Math":
                    return EncodeMathCall(methodName, argExprs);

                // The BCL static GUARD receivers (issue #492, bucket i). Unlike
                // `Console`/`Math` these two are guarded on the same-file class
                // table: `Debug` is a plausible name for a user's own helper
                // class, and a class this encoder is itself encoding must always
                // win over a built-in route to a type it is not.
                case "ArgumentNullException" when !DeclaresSameFileStatic(receiverName, methodName):
                    return EncodeArgumentNullExceptionCall(methodName, argExprs);
                case "Debug" when !DeclaresSameFileStatic(receiverName, methodName):
                    return EncodeDebugCall(methodName, argExprs);
            }

            if (ClassNames.ContainsKey(receiverName) &&
                StaticMethodParams.TryGetValue((receiverName, methodName), out var staticParams))
            {
                return Builders.UserCall(
                    StaticFunctionName(receiverName, methodName),
                    PackArgs(argExprs, staticParams));
            }
        }

        GuardReceiverDiscriminatedCall(member, methodName, argExprs);

        var receiver = EncodeExpr(member.Expression);
        return DispatchInstanceOrBuiltinMethod(receiver, methodName, argExprs);
    }

    /// <summary>
    /// Route a call that bound to a method THIS PROJECT declares in source, or return null to
    /// leave it to the existing name-based dispatch (issue #492, W12-C slice 1).
    ///
    /// <para>"Declared in source" is <c>ISymbol.DeclaringSyntaxReferences</c>, whose contract is
    /// exactly the test wanted: it "should return one or more syntax nodes only if the symbol
    /// was declared in source code and also was not implicitly declared". A metadata (BCL)
    /// symbol has none, so it falls through untouched to the built-in table.</para>
    ///
    /// <para><paramref name="receiver"/> is the member-access receiver, or null for a bare
    /// (unqualified) call.</para>
    /// </summary>
    private Expression? SourceSymbolCall(
        InvocationExpressionSyntax invocation,
        ExpressionSyntax? receiver,
        List<ExpressionSyntax> argExprs)
    {
        if (_semantics.MethodFor(invocation) is not { } symbol ||
            symbol.ContainingType is not { DeclaringSyntaxReferences.Length: > 0 })
        {
            return null;
        }

        // A LOCAL FUNCTION is source-declared and its containing type is this project's, but
        // `EncodeTypeDeclaration` never emits one — so routing it here would produce a call to a
        // Ball function that does not exist, which is the silent kind of wrong. Local functions
        // are a documented gap (csharp/AGENTS.md); the symbol is what finally lets project mode
        // SAY so instead of emitting an unresolvable name. Anything other than an ordinary or a
        // reduced-extension method gets the same treatment rather than a guess.
        if (symbol.MethodKind is not (MethodKind.Ordinary or MethodKind.ReducedExtension))
        {
            var at = invocation.GetLocation().GetLineSpan();
            throw new EncoderException(
                $"ball-encoder: {at.Path}({at.StartLinePosition.Line + 1}," +
                $"{at.StartLinePosition.Character + 1}): `{symbol.Name}(...)` binds to a " +
                $"`{symbol.MethodKind}`, which this encoder does not emit a declaration for — " +
                "encoding the call would reference a Ball function that does not exist");
        }

        // An extension method called in its REDUCED form (`receiver.Foo(a)`). `ReducedFrom`
        // "returns the definition of extension method from which this was reduced", i.e. the
        // plain static `Foo(this T self, A a)` — so the call encodes as the very same
        // `UserCall(Owner_Foo, …)` shape a spelled-out static call already uses, with the
        // receiver bound to the `this` parameter's real name.
        if (symbol.ReducedFrom is { } unreduced)
        {
            if (receiver is null || unreduced.ContainingType is not { DeclaringSyntaxReferences.Length: > 0 })
            {
                return null;
            }

            var packed = new List<ExpressionSyntax> { receiver };
            packed.AddRange(argExprs);
            return Builders.UserCall(
                SymbolFunctionName(unreduced),
                PackArgs(packed, ParameterNames(unreduced)));
        }

        if (symbol.IsStatic)
        {
            return Builders.UserCall(SymbolFunctionName(symbol), PackArgs(argExprs, ParameterNames(symbol)));
        }

        // An instance method. A bare call inside the declaring type is an implicit `this.`,
        // which is the engine's `self` convention — the same shape the member-access form uses.
        return EncodeMethodCallOnReceiver(
            receiver is null ? Builders.ReferenceExpr("self") : EncodeExpr(receiver),
            symbol.Name,
            argExprs,
            ParameterNames(symbol));
    }

    /// <summary>The top-level Ball function name a STATIC method symbol compiles to — the
    /// symbol-keyed twin of <see cref="StaticFunctionName"/>, including its one exception: a
    /// method literally named <c>Main</c> is always the bare entry-point name.</summary>
    private static string SymbolFunctionName(IMethodSymbol symbol) =>
        symbol.Name == "Main" ? "Main" : StaticFunctionName(symbol.ContainingType.Name, symbol.Name);

    private static List<string> ParameterNames(IMethodSymbol symbol) =>
        symbol.Parameters.Select(p => p.Name).ToList();

    /// <summary>
    /// Which receiver type each receiver-DISCRIMINATED method name is modelled for. These are
    /// the names <see cref="Encoder"/>'s module doc comment has always flagged as ambiguous:
    /// the resolution-free path routes them unconditionally and documents the coin flip.
    /// </summary>
    private static readonly Dictionary<(string Name, int ArgCount), (SpecialType Receiver, string Route)>
        ReceiverDiscriminatedRoutes = new()
        {
            [("Contains", 1)] = (SpecialType.System_String, "std.string_contains"),
            [("IndexOf", 1)] = (SpecialType.System_String, "std.string_index_of"),
        };

    /// <summary>
    /// In PROJECT mode, refuse to route a receiver-discriminated name unless the receiver's
    /// type actually is the one that route models (issue #492, W12-C slice 1).
    ///
    /// <para>The resolution-free entry points may keep guessing: they never promised otherwise,
    /// and their guess is the documented behaviour every existing caller depends on. But
    /// <see cref="CSharpEncoder.EncodeProject"/> advertises symbol-grade answers, so falling
    /// back to the name heuristic THERE would be a silent fail-soft in the one mode that
    /// claims not to have any — a `List&lt;string&gt;.Contains(x)` quietly compiled as a string
    /// search. Both failures are therefore loud, and each names the file, the position, the
    /// call and the reason.</para>
    ///
    /// <para>Note the ordering: this runs only AFTER <see cref="SourceSymbolCall"/> has
    /// declined, so a user's own <c>.Contains</c> on their own type never reaches it. Teaching
    /// the table to route by receiver type (rather than merely refusing) is the next slice, and
    /// it wants a symbol-keyed route table — (containing type, name, parameter types) — not
    /// more predicates bolted onto <c>(name, argc)</c> arms.</para>
    /// </summary>
    private void GuardReceiverDiscriminatedCall(
        MemberAccessExpressionSyntax member, string methodName, List<ExpressionSyntax> argExprs)
    {
        if (!IsProjectMode ||
            !ReceiverDiscriminatedRoutes.TryGetValue((methodName, argExprs.Count), out var route))
        {
            return;
        }

        var position = member.GetLocation().GetLineSpan();
        var where = $"{position.Path}({position.StartLinePosition.Line + 1}," +
            $"{position.StartLinePosition.Character + 1})";

        var receiverType = _semantics.TypeOf(member.Expression);
        if (receiverType is null)
        {
            var reason = _semantics.BindingFailure(member.Expression) is { } failure
                ? $" (binding failure: {failure})"
                : string.Empty;
            throw new EncoderException(
                $"ball-encoder: {where}: the receiver of `.{methodName}(...)` could not be " +
                $"bound to a type{reason}. `{methodName}` is a receiver-discriminated name — " +
                $"it models `{route.Route}` and nothing else — so project mode refuses to " +
                "guess. Encode this file with `Encode`/`EncodeLibrary` if the resolution-free " +
                "answer is what you want, or add the missing reference/#define");
        }

        if (receiverType.SpecialType != route.Receiver)
        {
            throw new EncoderException(
                $"ball-encoder: {where}: `.{methodName}(...)` has a receiver of type " +
                $"`{receiverType.ToDisplayString()}`, but this encoder models that name only as " +
                $"`{route.Route}`. Routing it by receiver type is not implemented yet, and " +
                "guessing would silently compute something else");
        }
    }

    /// <summary>
    /// The short name a call's receiver denotes when that receiver is a TYPE rather than a
    /// value — <c>Console</c>, <c>Math</c>, <c>ArgumentNullException</c>, <c>Debug</c>, or a
    /// same-file class — or <c>null</c> when it is an ordinary value expression.
    ///
    /// <para>Accepts both the bare spelling (<c>Console.WriteLine(...)</c>, which needs a
    /// shadowing check: a local or field of the same name always wins) and the
    /// namespace-qualified one (<c>System.Console.WriteLine(...)</c>, which needs none — a
    /// C# local or field cannot be spelled <c>System.Console</c>). Only the <c>System</c>
    /// namespace is unwrapped: deeper namespaces (<c>System.Text.Encoding</c>) name types
    /// this encoder has no mapping for anyway, so they keep falling through to the loud
    /// "unsupported method call" path rather than being silently mis-resolved.</para>
    /// </summary>
    private string? StaticReceiverName(ExpressionSyntax expr) => expr switch
    {
        IdentifierNameSyntax id when !IsKnownLocal(id.Identifier.Text) && !IsKnownField(id.Identifier.Text) =>
            id.Identifier.Text,
        MemberAccessExpressionSyntax qualified
            when qualified.Expression is IdentifierNameSyntax { Identifier.Text: "System" } =>
            qualified.Name.Identifier.Text,
        _ => null,
    };

    /// <summary>
    /// A static call whose receiver is a predefined (keyword) type —
    /// <c>int.Parse("41")</c>, <c>double.Parse(s)</c> — routed to the <c>std</c>
    /// conversion that models it (issue #492, bucket e).
    ///
    /// <para>Only <c>Parse</c>, and only the four numeric keywords, because
    /// <c>string_to_int</c>/<c>string_to_double</c> are the only conversions
    /// <c>StdModuleBuilders</c> declares. <c>float.Parse</c> → <c>string_to_double</c>
    /// is a deliberate precision-WIDENING approximation: Ball has no 32-bit float
    /// type, so a C# <c>float</c> is a double throughout this pipeline (the same
    /// documented-approximation style as <see cref="EncodeConsoleCall"/>'s
    /// <c>Write</c>). <c>TryParse</c> is NOT routed here: dropping its
    /// out-parameter failure branch would compile, run, and be silently wrong on
    /// bad input — it stays a loud error (and is an <c>out var</c>
    /// <c>DeclarationExpression</c> shape this encoder does not model anyway).</para>
    ///
    /// <para><b><c>string.Join(separator, values)</c> (issue #492, bucket k).</b>
    /// <c>string</c> is a <c>PredefinedTypeSyntax</c> keyword exactly like
    /// <c>int</c>, so this is the one function a <c>string.Join</c> call can be
    /// routed from — and a keyword can never be shadowed by a user identifier, so
    /// (unlike the <c>Debug</c>/<c>ArgumentNullException</c> receivers above) this
    /// arm needs no same-file-class guard. It routes to the already-declared,
    /// already-compiled <c>std_collections.string_join</c>, whose
    /// <c>StringJoinInput</c> field order (<c>list</c>=1, <c>separator</c>=2) is
    /// INVERTED from C#'s argument order — hence the named, deliberately swapped
    /// construction below rather than a positional one.</para>
    ///
    /// <para>Only the 2-argument spelling is routed: that is the shape every
    /// occurrence in the Tier A corpus uses (12 of the 19 first-error
    /// <c>unsupported static call</c> files, all of them
    /// <c>string.Join(" ", parts)</c>), and the <c>params</c> overloads
    /// (<c>string.Join(sep, a, b)</c>) keep failing loud rather than being
    /// approximated. A <c>char</c> separator needs no special case — this encoder
    /// already encodes a character literal as the one-character string it denotes,
    /// which is exactly what <c>string_join</c> consumes. The one divergence
    /// inside the routed shape is a <c>null</c> ELEMENT: C# renders it as the
    /// empty string while <c>string_join</c> stringifies every element and so
    /// renders <c>null</c>. That is an element VALUE, invisible to a syntax-only
    /// encoder, so it is a documented approximation (the same class as
    /// <see cref="EncodeConsoleCall"/>'s <c>Write</c>), recorded in
    /// <c>csharp/AGENTS.md</c>.</para>
    /// </summary>
    private Expression EncodePredefinedTypeStaticCall(string keyword, string methodName, List<ExpressionSyntax> argExprs)
    {
        if (methodName == "Parse" && argExprs.Count == 1)
        {
            switch (keyword)
            {
                case "int" or "long":
                    return Builders.UnaryStd("string_to_int", EncodeExpr(argExprs[0]));
                case "double" or "float":
                    return Builders.UnaryStd("string_to_double", EncodeExpr(argExprs[0]));
            }
        }

        if (keyword == "string" && methodName == "Join" && argExprs.Count == 2)
        {
            // Swapped on purpose: C# is (separator, values), StringJoinInput is
            // (list, separator). Named fields, never positional — see the doc
            // comment and PredefinedTypeCallTests' run-the-output proof.
            var separator = EncodeExpr(argExprs[0]);
            var list = EncodeExpr(argExprs[1]);
            MarkCollectionsUsed();
            return Builders.CollectionsCall(
                "string_join",
                Builders.ArgsMessage(("list", list), ("separator", separator)));
        }

        throw new EncoderException(
            $"ball-encoder: unsupported static call `{keyword}.{methodName}(...)` with " +
            $"{argExprs.Count} argument(s) (only `Parse` on `int`/`long`/`double`/`float` and " +
            "the 2-argument `string.Join(separator, values)` are modelled — those are the " +
            "shapes StdModuleBuilders declares a counterpart for; `TryParse` is deliberately " +
            "not routed, since dropping its failure branch would be silently wrong)");
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

    /// <summary>
    /// Does the file being encoded declare its OWN static <c>receiverName.methodName</c>?
    /// A same-file class always beats a built-in route to a BCL type of the same name.
    /// </summary>
    private bool DeclaresSameFileStatic(string receiverName, string methodName) =>
        ClassNames.ContainsKey(receiverName) && StaticMethodParams.ContainsKey((receiverName, methodName));

    /// <summary>
    /// <c>ArgumentNullException.ThrowIfNull(x)</c> — the .NET 6+ null guard, and the
    /// highest-count named shape in the <c>unsupported method call</c> bucket of a Tier A
    /// run (issue #492, bucket i). Its semantics is "throw unless <c>x</c> is non-null",
    /// which universal <c>std.assert</c> models exactly:
    /// <c>assert(not_equals(x, null), "&lt;x&gt; must not be null")</c>. Nothing new is
    /// declared — <c>assert</c> (<c>AssertInput { condition, message }</c>) and
    /// <c>not_equals</c> have been declared by <c>StdModuleBuilders</c>, compiled by
    /// <c>BaseCall</c> and interpreted by every engine since day one; the C# encoder had
    /// simply never emitted them.
    ///
    /// <para>The fault raised at run time is a <c>BallRuntimeException</c>, not an
    /// <c>ArgumentNullException</c>: Ball's <c>assert</c> is the single portable "fail here"
    /// primitive and the exception TYPE is not modelled. The message names the guarded
    /// expression so the failure still says which argument it was.</para>
    ///
    /// <para>The 2-argument <c>ThrowIfNull(value, paramName)</c> overload is deliberately NOT
    /// routed. Its second argument is the exception's parameter name, spelled <c>nameof(x)</c>
    /// at every occurrence in the measured corpus — a shape this syntax-only encoder has no
    /// model for, which would encode as an unresolvable user call to a function named
    /// <c>nameof</c>. Trading a loud encode error for a program that encodes and then does not
    /// build is not an improvement, so it stays loud (see
    /// <c>BclStaticGuardCallTests</c>).</para>
    /// </summary>
    private Expression EncodeArgumentNullExceptionCall(string methodName, List<ExpressionSyntax> argExprs)
    {
        if (methodName == "ThrowIfNull" && argExprs.Count == 1)
        {
            var condition = Builders.BinaryStd("not_equals", EncodeExpr(argExprs[0]), Builders.NullLiteral());
            return Builders.StdCall(
                "assert",
                Builders.NamedMessage(
                    "AssertInput",
                    ("condition", condition),
                    ("message", Builders.StringLiteral($"{SourceLabel(argExprs[0])} must not be null"))));
        }

        throw new EncoderException(
            $"ball-encoder: unsupported `ArgumentNullException.{methodName}(...)` with " +
            $"{argExprs.Count} argument(s) (only the 1-argument `ThrowIfNull(value)` guard is " +
            "modelled, as `std.assert(std.not_equals(value, null), ...)`; the 2-argument " +
            "`ThrowIfNull(value, paramName)` overload is deliberately not routed — its " +
            "`paramName` is spelled `nameof(x)`, a shape this syntax-only encoder cannot " +
            "resolve, so routing it would encode a program that then does not build)");
    }

    /// <summary>
    /// <c>Debug.Assert(condition)</c> / <c>Debug.Assert(condition, message)</c> — a direct
    /// 1:1 passthrough to <c>std.assert</c>, with the two arities registered as separate arms
    /// exactly like <see cref="DispatchInstanceOrBuiltinMethod"/>'s
    /// <c>("First", 0)</c>/<c>("First", 1)</c> pair (issue #492, bucket i; the arity-window
    /// pattern of <c>dart/encoder</c>'s <c>collectionRoutes</c>). The 1-argument form emits no
    /// <c>message</c> field at all, so the compiler's own <c>"assertion failed"</c> default —
    /// the text every other target prints for a message-less assert — is what surfaces.
    ///
    /// <para>.NET compiles <c>Debug.Assert</c> away outside a <c>DEBUG</c> build; Ball has no
    /// conditional compilation, so the encoded assert always runs. That is a documented
    /// STRENGTHENING (an assertion that holds in a debug build holds in a release build),
    /// never a weakening — the same style of approximation as <see cref="EncodeConsoleCall"/>'s
    /// <c>Write</c>.</para>
    /// </summary>
    private Expression EncodeDebugCall(string methodName, List<ExpressionSyntax> argExprs)
    {
        if (methodName == "Assert" && argExprs.Count is 1 or 2)
        {
            var fields = new List<(string Name, Expression Value)>
            {
                ("condition", EncodeExpr(argExprs[0])),
            };
            if (argExprs.Count == 2)
            {
                fields.Add(("message", EncodeExpr(argExprs[1])));
            }

            return Builders.StdCall("assert", Builders.NamedMessage("AssertInput", fields));
        }

        throw new EncoderException(
            $"ball-encoder: unsupported `Debug.{methodName}(...)` with {argExprs.Count} " +
            "argument(s) (only `Assert(condition)` / `Assert(condition, message)` are modelled, " +
            "as `std.assert`; `Debug.WriteLine` and friends are diagnostics with no `std` " +
            "counterpart — `Console.WriteLine` is the routed print)");
    }

    /// <summary>The source text of <paramref name="expr"/>, collapsed to one line and capped,
    /// for embedding in a generated assertion message. Cosmetic only — it never affects what
    /// the guard evaluates.</summary>
    private static string SourceLabel(ExpressionSyntax expr)
    {
        var text = string.Join(' ', expr.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return text.Length <= 60 ? text : text[..60] + "…";
    }

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

            // The 0-argument LINQ extension-method spelling of the SAME thing
            // `EncodePropertyAccess` maps `.Count`/`.Length` to. C# means the
            // same by both on a List<T>, so they must encode identically —
            // `PredefinedTypeCallTests` asserts that equality (issue #492,
            // bucket e). Like the identity passthroughs above it needs no
            // `MarkCollectionsUsed()`: `length` is a plain `std` unary op.
            case ("Count", 0):
                return Builders.UnaryStd("length", receiver);

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
            // `First` — and ONLY `First`. `list_find` is Dart's `firstWhere` with no
            // `orElse` and `list_first` is `.first`: both THROW when there is nothing to
            // return, exactly as C#'s `.First(pred)`/`.First()` do. `FirstOrDefault`
            // shared these two arms until issue #588 and is deliberately absent now —
            // see the `*OrDefault` note below.
            case ("First", 1):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_find", Builders.ArgsMessage(("list", receiver), ("callback", EncodeExpr(argExprs[0]))));
            case ("First", 0):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_first", Builders.ArgsMessage(("list", receiver)));

            // The 0-argument arms of the SAME arity windows (issue #492, bucket j).
            // `.Last()` is `list_last` outright: C#'s `.Last()` throws on an empty
            // sequence and so does `list_last` (`BallRuntime.ListLast`, `.last` in the
            // Dart reference engine) — the same contract, not an approximation.
            //
            // NO `*OrDefault` name is routed — `FirstOrDefault`, `LastOrDefault`,
            // `SingleOrDefault` all fall through to the loud throw below. Their contract
            // is "return `default(T)` instead of throwing", and every tree available here
            // (`list_first`/`list_last`/`list_find`) throws instead. `FirstOrDefault` used
            // to share `First`'s two arms and was therefore silently wrong on exactly the
            // empty/no-match input the name exists to handle (issue #588, reproduced on the
            // Dart reference engine at BOTH arities); it is unrouted now. Routing it to a
            // hypothetical nullable primitive would not fix it either: `default(T)` is
            // `null` for a reference `T` but `0`/`0.0`/`false`/a zeroed struct for a value
            // `T`, and this encoder is syntax-only — `T` is not written down at a
            // `.FirstOrDefault()` call site (unlike #578's `default(int)`, where the
            // keyword IS the syntax), so the result would be right for some `T` and
            // silently wrong for others. Same reasoning as `TryParse`'s exclusion from
            // `EncodePredefinedTypeStaticCall`.
            case ("Last", 0):
                MarkCollectionsUsed();
                return Builders.CollectionsCall("list_last", Builders.ArgsMessage(("list", receiver)));

            // 0-argument `.Any()` is "the sequence is not empty" — the predicate-less
            // sibling of the `("Any", 1)` arm above, and NOT the same function.
            // Composed from two already-declared base functions rather than needing a
            // new one; `not` is plain `std`, `list_is_empty` is what needs
            // `MarkCollectionsUsed()`.
            case ("Any", 0):
                MarkCollectionsUsed();
                return Builders.UnaryStd(
                    "not",
                    Builders.CollectionsCall("list_is_empty", Builders.ArgsMessage(("list", receiver))));
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

        // `Color.Green` — a member access whose receiver names an enum THIS FILE declares
        // (issue #492, slice C). Encoded as `field_access(reference("Color"), "Green")`, the
        // same tree `rust/encoder/src/types.rs` emits for `Color::Green` and the Dart reference
        // encoder for `Color.green`; `csharp/compiler/src/CSharpCompiler.cs::CompileReference`
        // resolves the bare `Color` to the enum-namespace static `TypeEmit.CompileEnum` emits.
        // Handled BEFORE EncodePropertyAccess so a member named `Count`/`Length`/`Keys`/
        // `Values` is not silently rewritten into a `std.length`/`std_collections` call.
        if (member.Expression is IdentifierNameSyntax enumId &&
            EnumMembers.TryGetValue(enumId.Identifier.Text, out var enumMembers) &&
            !IsKnownLocal(enumId.Identifier.Text) &&
            !IsKnownField(enumId.Identifier.Text))
        {
            var enumShort = enumId.Identifier.Text;
            if (!enumMembers.Contains(memberName))
            {
                throw new EncoderException(
                    $"ball-encoder: `{enumShort}.{memberName}` is not a declared member of enum " +
                    $"`{enumShort}` (declared: {string.Join(", ", enumMembers)})");
            }

            return Builders.FieldAccessExpr(Builders.ReferenceExpr(enumShort), memberName);
        }

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
