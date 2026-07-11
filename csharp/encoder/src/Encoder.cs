using System;
using System.Collections.Generic;
using System.Linq;
using Ball.V1;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>
/// Mutable state + core expression dispatch for one C# source file being encoded. Split
/// across partial-class files by concern, mirroring <c>rust/encoder/src</c>'s module split:
/// this file (pre-pass + literals/references/operators/assignment/ternary), <c>Statements.cs</c>
/// (block/local encoding), <c>ControlFlow.cs</c> (if/for/foreach/while/switch/try/break/
/// continue/return/throw), <c>Types.cs</c> (class members, object creation), <c>Methods.cs</c>
/// (invocation/member-access dispatch, string interpolation, lambdas).
/// </summary>
internal sealed partial class Encoder
{
    /// <summary>Every declared class/struct/record's short name → its module-qualified Ball
    /// name (<c>"main:Foo"</c> — see <see cref="QualifiedTypeName"/>).</summary>
    internal readonly Dictionary<string, string> ClassNames = new();

    /// <summary>Owner short name → its own (non-static) field short names, in declaration
    /// order — consulted by <see cref="IsKnownField"/> to resolve an implicit
    /// <c>this.field</c> (a bare identifier used inside an instance method body that isn't a
    /// known local) and by object-creation/constructor-parameter mapping.</summary>
    internal readonly Dictionary<string, List<string>> ClassFields = new();

    /// <summary>Owner short name → its single constructor's parameter names, in declaration
    /// order (empty list when the class has no explicit constructor — construction then
    /// requires an object-initializer). Only ONE user constructor per class is supported (a
    /// documented scope decision, matching how this encoder treats construction as a plain
    /// field-mapping <c>message_creation</c> rather than interpreting a constructor body —
    /// see <c>Types.cs</c>'s module doc comment).</summary>
    internal readonly Dictionary<string, List<string>> CtorParams = new();

    /// <summary>(owner short, method short) → the method's own declared (non-<c>this</c>)
    /// parameter names, in order — consulted at an instance-method **call site** so a 2+-arg
    /// call packs its <c>MessageCreation</c> under the callee's real parameter names.</summary>
    internal readonly Dictionary<(string Owner, string Method), List<string>> MethodParams = new();

    /// <summary>(owner short, method short) → the static method's own declared parameter
    /// names, in order — same purpose as <see cref="MethodParams"/> but for a
    /// <c>Type.StaticMethod(args)</c> call site (see <see cref="StaticFunctionName"/>
    /// for the qualified free-function name a static method compiles to).</summary>
    internal readonly Dictionary<(string Owner, string Method), List<string>> StaticMethodParams = new();

    /// <summary>Lexical local-name scope stack (function/lambda parameters, <c>let</c>-bound
    /// locals, <c>foreach</c>/<c>catch</c> variables) — consulted ONLY to disambiguate a bare
    /// identifier as "local variable" vs. "current instance's field" inside a method body (a
    /// syntax-only encoder has no symbol table to ask). A name is "known local" if it is
    /// declared in ANY currently-open frame — mirrors C#'s own shadowing rule (a local always
    /// wins over a same-named field).</summary>
    private readonly List<HashSet<string>> _localScopes = new();

    /// <summary>The short name of the class whose instance-method body is currently being
    /// encoded, or null while encoding a static/free function or top-level statement.
    /// Consulted by <see cref="IsKnownField"/> and by unqualified same-file call resolution
    /// (an unqualified call to a sibling instance method implies <c>this.Method(...)</c>).</summary>
    private string? _currentInstanceOwner;

    /// <summary>The short name of the class whose method body (static OR instance) is
    /// currently being encoded, or null while encoding a top-level statement. A superset of
    /// <see cref="_currentInstanceOwner"/> — consulted by <see cref="EncodeBareCall"/> to
    /// resolve an unqualified recursive/sibling call to a STATIC method of the same class
    /// (e.g. a static <c>Fib</c> calling itself by bare name).</summary>
    private string? _currentOwnerShort;

    /// <summary>Set once this file's encoding reaches any <c>std_collections</c> call — read
    /// by <see cref="CSharpEncoder"/> to decide whether <c>main</c>'s <c>module_imports</c>
    /// should list <c>std_collections</c> (mirrors <c>rust/encoder/src/lib.rs::module_uses_collections</c>,
    /// but tracked incrementally here rather than re-walked, since this encoder already visits
    /// every call site once).</summary>
    internal bool UsesCollections { get; private set; }

    private void MarkCollectionsUsed() => UsesCollections = true;

    // ════════════════════════════════════════════════════════════
    // Local-scope helpers
    // ════════════════════════════════════════════════════════════

    private void PushScope(IEnumerable<string>? initial = null)
    {
        _localScopes.Add(initial is null ? new HashSet<string>() : new HashSet<string>(initial));
    }

    private void PopScope() => _localScopes.RemoveAt(_localScopes.Count - 1);

    private void DeclareLocal(string name)
    {
        if (_localScopes.Count == 0)
        {
            PushScope();
        }

        _localScopes[^1].Add(name);
    }

    private bool IsKnownLocal(string name) => _localScopes.Any(frame => frame.Contains(name));

    private bool IsKnownField(string name) =>
        _currentInstanceOwner is not null &&
        ClassFields.TryGetValue(_currentInstanceOwner, out var fields) &&
        fields.Contains(name);

    // ════════════════════════════════════════════════════════════
    // Pre-pass: collect every type's shape before encoding bodies (so a call site that
    // textually precedes its callee — or targets a same-class sibling — still resolves).
    // ════════════════════════════════════════════════════════════

    internal void CollectDeclarations(List<BaseTypeDeclarationSyntax> typeDecls)
    {
        foreach (var decl in typeDecls.OfType<TypeDeclarationSyntax>())
        {
            var shortName = decl.Identifier.Text;
            ClassNames[shortName] = QualifiedTypeName(shortName);
        }

        foreach (var decl in typeDecls.OfType<TypeDeclarationSyntax>())
        {
            var shortName = decl.Identifier.Text;
            var fieldNames = new List<string>();
            List<string>? ctorParams = null;

            // C# 12 primary constructor (`class Point(int x, int y);` / the long-standing
            // positional-record shorthand `record Point(int X, int Y);`) — its parameters
            // double as both the constructor's param list AND the type's implicit fields.
            if (decl.ParameterList is not null)
            {
                ctorParams = decl.ParameterList.Parameters.Select(p => p.Identifier.Text).ToList();
                fieldNames.AddRange(ctorParams);
            }

            foreach (var member in decl.Members)
            {
                switch (member)
                {
                    case FieldDeclarationSyntax field when !field.Modifiers.Any(SyntaxKind.StaticKeyword):
                        foreach (var variable in field.Declaration.Variables)
                        {
                            fieldNames.Add(variable.Identifier.Text);
                        }

                        break;
                    case PropertyDeclarationSyntax prop when !prop.Modifiers.Any(SyntaxKind.StaticKeyword) && IsAutoProperty(prop):
                        fieldNames.Add(prop.Identifier.Text);
                        break;
                    case ConstructorDeclarationSyntax ctor when !ctor.Modifiers.Any(SyntaxKind.StaticKeyword):
                        if (ctorParams is not null)
                        {
                            throw new EncoderException(
                                $"ball-encoder: class `{shortName}` declares more than one " +
                                "constructor — only a single, field-mapping constructor is " +
                                "supported (construction encodes as a plain message_creation; " +
                                "see Types.cs's module doc comment)");
                        }

                        ctorParams = ctor.ParameterList.Parameters
                            .Select(p => p.Identifier.Text)
                            .ToList();
                        break;
                    case MethodDeclarationSyntax method:
                        var methodName = method.Identifier.Text;
                        var paramNames = method.ParameterList.Parameters
                            .Select(p => p.Identifier.Text)
                            .ToList();
                        if (method.Modifiers.Any(SyntaxKind.StaticKeyword))
                        {
                            StaticMethodParams[(shortName, methodName)] = paramNames;
                        }
                        else
                        {
                            MethodParams[(shortName, methodName)] = paramNames;
                            AnyMethodParams[methodName] = paramNames;
                        }

                        break;
                }
            }

            ClassFields[shortName] = fieldNames;
            CtorParams[shortName] = ctorParams ?? new List<string>();
        }
    }

    private static bool IsAutoProperty(PropertyDeclarationSyntax prop)
    {
        if (prop.ExpressionBody is not null)
        {
            return false;
        }

        var accessors = prop.AccessorList?.Accessors;
        if (accessors is null)
        {
            return false;
        }

        return accessors.Value.All(a => a.Body is null && a.ExpressionBody is null);
    }

    // ════════════════════════════════════════════════════════════
    // Top-level statements (C# 9+ minimal Program.cs) → the "Main" entry function
    // ════════════════════════════════════════════════════════════

    internal FunctionDefinition EncodeTopLevelMain(List<StatementSyntax> statements)
    {
        PushScope();
        var body = EncodeStatementsAsBlock(statements);
        PopScope();
        return new FunctionDefinition
        {
            Name = "Main",
            Body = body,
            IsBase = false,
            Metadata = new MetaBuilder().SetString("kind", "function").Build(),
        };
    }

    // ════════════════════════════════════════════════════════════
    // Expression dispatch — the seven-node Ball Expression tree
    // ════════════════════════════════════════════════════════════

    internal Expression EncodeExpr(ExpressionSyntax expr)
    {
        switch (expr)
        {
            case LiteralExpressionSyntax lit:
                return EncodeLiteral(lit);
            case InterpolatedStringExpressionSyntax interp:
                return EncodeInterpolatedString(interp);
            case IdentifierNameSyntax id:
                return EncodeIdentifierName(id.Identifier.Text);
            case ThisExpressionSyntax:
                return Builders.ReferenceExpr("self");
            case ParenthesizedExpressionSyntax paren:
                return EncodeExpr(paren.Expression);
            case CastExpressionSyntax cast:
                return EncodeExpr(cast.Expression);
            case CheckedExpressionSyntax chk:
                return EncodeExpr(chk.Expression);
            case BinaryExpressionSyntax bin:
                return EncodeBinary(bin);
            case PrefixUnaryExpressionSyntax pre:
                return EncodePrefixUnary(pre);
            case PostfixUnaryExpressionSyntax post:
                return EncodePostfixUnary(post);
            case AssignmentExpressionSyntax assign:
                return EncodeAssignment(assign);
            case ConditionalExpressionSyntax cond:
                return Builders.IfCall(EncodeExpr(cond.Condition), EncodeExpr(cond.WhenTrue), EncodeExpr(cond.WhenFalse));
            case MemberAccessExpressionSyntax member:
                return EncodeMemberAccess(member);
            case ConditionalAccessExpressionSyntax condAccess:
                return EncodeConditionalAccess(condAccess);
            case ElementAccessExpressionSyntax elemAccess:
                return EncodeElementAccess(elemAccess);
            case InvocationExpressionSyntax invocation:
                return EncodeInvocation(invocation);
            case ObjectCreationExpressionSyntax objCreate:
                return EncodeObjectCreation(objCreate);
            case ImplicitObjectCreationExpressionSyntax implicitCreate:
                return EncodeImplicitObjectCreation(implicitCreate);
            case ArrayCreationExpressionSyntax arrayCreate:
                return EncodeArrayCreation(arrayCreate);
            case ImplicitArrayCreationExpressionSyntax implicitArray:
                return Builders.ListLiteralExpr(implicitArray.Initializer.Expressions.Select(EncodeExpr));
            case InitializerExpressionSyntax initExpr when initExpr.Kind() == SyntaxKind.ArrayInitializerExpression
                || initExpr.Kind() == SyntaxKind.CollectionInitializerExpression:
                return Builders.ListLiteralExpr(initExpr.Expressions.Select(EncodeExpr));
            case ParenthesizedLambdaExpressionSyntax lambda:
                return EncodeParenthesizedLambda(lambda);
            case SimpleLambdaExpressionSyntax simpleLambda:
                return EncodeSimpleLambda(simpleLambda);
            case ThrowExpressionSyntax throwExpr:
                return Builders.StdCall("throw", Builders.ArgsMessage(("value", EncodeExpr(throwExpr.Expression))));
            case DefaultExpressionSyntax:
                return Builders.NullLiteral();
            default:
                throw new EncoderException(
                    $"ball-encoder: unsupported C# expression kind `{expr.Kind()}` " +
                    $"(deferred — see the module doc comment for issue #382's scope): `{expr}`");
        }
    }

    // ── literals ─────────────────────────────────────────────

    private Expression EncodeLiteral(LiteralExpressionSyntax lit)
    {
        switch (lit.Kind())
        {
            case SyntaxKind.NumericLiteralExpression:
                var text = lit.Token.Text;
                if (text.Contains('.') || text.Contains('e') || text.Contains('E') ||
                    (text.EndsWith('f') || text.EndsWith('F') || text.EndsWith('d') || text.EndsWith('D') || text.EndsWith('m') || text.EndsWith('M')))
                {
                    return Builders.DoubleLiteral(Convert.ToDouble(lit.Token.Value));
                }

                return Builders.IntLiteral(Convert.ToInt64(lit.Token.Value));
            case SyntaxKind.StringLiteralExpression:
                return Builders.StringLiteral((string)lit.Token.Value!);
            case SyntaxKind.CharacterLiteralExpression:
                return Builders.StringLiteral(lit.Token.Value!.ToString()!);
            case SyntaxKind.TrueLiteralExpression:
                return Builders.BoolLiteral(true);
            case SyntaxKind.FalseLiteralExpression:
                return Builders.BoolLiteral(false);
            case SyntaxKind.NullLiteralExpression:
                return Builders.NullLiteral();
            default:
                throw new EncoderException($"ball-encoder: unsupported literal kind `{lit.Kind()}`: {lit}");
        }
    }

    // ── identifiers / references ─────────────────────────────

    private Expression EncodeIdentifierName(string name)
    {
        if (IsKnownLocal(name))
        {
            return Builders.ReferenceExpr(name);
        }

        if (IsKnownField(name))
        {
            return Builders.SelfFieldAccess(name);
        }

        // A bare reference to a known class name (e.g. as the receiver of a static-method
        // invocation, handled by EncodeInvocation before it ever reaches here) — anywhere
        // else, an unresolved identifier is either a typo or a construct outside this
        // syntax-only encoder's reach. Fail loud rather than silently emit a dangling
        // reference the engine would only catch at run time.
        if (ClassNames.ContainsKey(name))
        {
            throw new EncoderException(
                $"ball-encoder: bare reference to type name `{name}` is not a supported " +
                "expression (only `Type.Method(...)`/`new Type(...)` are)");
        }

        return Builders.ReferenceExpr(name);
    }

    // ── binary operators ──────────────────────────────────────

    private Expression EncodeBinary(BinaryExpressionSyntax bin)
    {
        var left = bin.Left;
        var right = bin.Right;
        return bin.Kind() switch
        {
            SyntaxKind.AddExpression => Builders.BinaryStd("add", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.SubtractExpression => Builders.BinaryStd("subtract", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.MultiplyExpression => Builders.BinaryStd("multiply", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.DivideExpression => Builders.BinaryStd(
                LooksLikeFloat(left) || LooksLikeFloat(right) ? "divide_double" : "divide",
                EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.ModuloExpression => Builders.BinaryStd("modulo", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.LogicalAndExpression => Builders.BinaryStd("and", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.LogicalOrExpression => Builders.BinaryStd("or", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.BitwiseAndExpression => Builders.BinaryStd("bitwise_and", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.BitwiseOrExpression => Builders.BinaryStd("bitwise_or", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.ExclusiveOrExpression => Builders.BinaryStd("bitwise_xor", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.LeftShiftExpression => Builders.BinaryStd("left_shift", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.RightShiftExpression => Builders.BinaryStd("right_shift", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.UnsignedRightShiftExpression => Builders.BinaryStd("unsigned_right_shift", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.EqualsExpression => Builders.BinaryStd("equals", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.NotEqualsExpression => Builders.BinaryStd("not_equals", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.LessThanExpression => Builders.BinaryStd("less_than", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.GreaterThanExpression => Builders.BinaryStd("greater_than", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.LessThanOrEqualExpression => Builders.BinaryStd("lte", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.GreaterThanOrEqualExpression => Builders.BinaryStd("gte", EncodeExpr(left), EncodeExpr(right)),
            SyntaxKind.CoalesceExpression => Builders.BinaryStd("null_coalesce", EncodeExpr(left), EncodeExpr(right)),
            _ => throw new EncoderException($"ball-encoder: unsupported binary operator `{bin.Kind()}`: {bin}"),
        };
    }

    /// <summary>Conservative syntactic heuristic (no static types available — see the module
    /// doc comment): does this operand *look* like a float (a float/double literal, or a
    /// parenthesized/negated one)? Mirrors <c>rust/encoder/src/lib.rs::looks_like_float</c>,
    /// used only to disambiguate <c>/</c>'s truncating-int vs. always-double semantics.</summary>
    private static bool LooksLikeFloat(ExpressionSyntax expr) => expr switch
    {
        LiteralExpressionSyntax lit when lit.Kind() == SyntaxKind.NumericLiteralExpression =>
            lit.Token.Value is double or float,
        PrefixUnaryExpressionSyntax { RawKind: (int)SyntaxKind.UnaryMinusExpression } pre => LooksLikeFloat(pre.Operand),
        ParenthesizedExpressionSyntax paren => LooksLikeFloat(paren.Expression),
        _ => false,
    };

    // ── unary operators ────────────────────────────────────────

    private Expression EncodePrefixUnary(PrefixUnaryExpressionSyntax pre) => pre.Kind() switch
    {
        SyntaxKind.UnaryMinusExpression => Builders.UnaryStd("negate", EncodeExpr(pre.Operand)),
        SyntaxKind.UnaryPlusExpression => EncodeExpr(pre.Operand),
        SyntaxKind.LogicalNotExpression => Builders.UnaryStd("not", EncodeExpr(pre.Operand)),
        SyntaxKind.BitwiseNotExpression => Builders.UnaryStd("bitwise_not", EncodeExpr(pre.Operand)),
        SyntaxKind.PreIncrementExpression => Builders.UnaryStd("pre_increment", EncodeExpr(pre.Operand)),
        SyntaxKind.PreDecrementExpression => Builders.UnaryStd("pre_decrement", EncodeExpr(pre.Operand)),
        _ => throw new EncoderException($"ball-encoder: unsupported prefix unary operator `{pre.Kind()}`: {pre}"),
    };

    private Expression EncodePostfixUnary(PostfixUnaryExpressionSyntax post) => post.Kind() switch
    {
        SyntaxKind.PostIncrementExpression => Builders.UnaryStd("post_increment", EncodeExpr(post.Operand)),
        SyntaxKind.PostDecrementExpression => Builders.UnaryStd("post_decrement", EncodeExpr(post.Operand)),
        SyntaxKind.SuppressNullableWarningExpression => EncodeExpr(post.Operand),
        _ => throw new EncoderException($"ball-encoder: unsupported postfix unary operator `{post.Kind()}`: {post}"),
    };

    // ── assignment ─────────────────────────────────────────────

    private Expression EncodeAssignment(AssignmentExpressionSyntax assign)
    {
        var target = EncodeExpr(assign.Left);
        var value = EncodeExpr(assign.Right);
        if (assign.Kind() == SyntaxKind.SimpleAssignmentExpression)
        {
            return Builders.StdCall("assign", Builders.ArgsMessage(("target", target), ("value", value)));
        }

        var op = assign.OperatorToken.Text; // "+=", "-=", "??=", ...
        return Builders.StdCall(
            "assign",
            Builders.ArgsMessage(("target", target), ("op", Builders.StringLiteral(op)), ("value", value)));
    }
}
