using System;
using System.Collections.Generic;
using System.Linq;
using Ball.V1;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>Where one constructor-assigned field's value comes from: a constructor parameter
/// (by index into <see cref="CtorShape.ParamNames"/>) or a constant literal written directly
/// in the constructor body (<c>_y = 0;</c>).</summary>
/// <param name="Field">The class's own DECLARED field name — never the parameter's name.</param>
/// <param name="ParamIndex">Index into the constructor's parameter list, or <c>-1</c> for a literal.</param>
/// <param name="Literal">The literal expression, when <paramref name="ParamIndex"/> is <c>-1</c>.</param>
internal readonly record struct CtorAssignment(string Field, int ParamIndex, ExpressionSyntax? Literal);

/// <summary>
/// One declared constructor, reduced to exactly what construction needs: its parameter names
/// (which fix its arity, and therefore which call sites select it) and the ordered list of
/// fields it assigns.
///
/// <para>This is a bounded, SYNTACTIC name/literal resolution — not general constructor-body
/// interpretation. Only two statement shapes are recognised (<c>field = param;</c> /
/// <c>this.field = param;</c>, and <c>field = literal;</c>); anything else is a loud
/// <see cref="EncoderException"/>. That is what makes the encoder's "construction is field
/// mapping only" invariant actually TRUE, rather than true-by-assumption: before this, a
/// constructor's PARAMETER names were used as the message's field keys, which silently
/// produced the wrong message whenever they differed from the class's real field names.</para>
/// </summary>
internal sealed record CtorShape(List<string> ParamNames, List<CtorAssignment> Assignments);

/// <summary>
/// One declared constructor as collected in the FIRST pass, before <c>: this(...)</c> chains are
/// resolved: its parameter names, the fields its own body assigns, and — for a chaining
/// constructor — the initializer's argument list.
///
/// <para>Chains cannot be resolved as they are read: C# lets a constructor delegate to a sibling
/// declared either BEFORE or AFTER it, so a single textual pass would resolve only backward
/// chains and silently mis-shape forward ones. See
/// <see cref="Encoder.ResolveConstructorChains"/>.</para>
/// </summary>
internal sealed record CtorDraft(
    List<string> ParamNames,
    List<CtorAssignment> OwnAssignments,
    ArgumentListSyntax? ThisChainArgs);

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

    /// <summary>Owner short name → one <see cref="CtorShape"/> per declared non-static
    /// constructor, in declaration order (empty list when the class declares none —
    /// construction then requires an object initializer). See <see cref="CtorShape"/> and
    /// <c>Types.cs</c>'s "Construction is field-mapping only" section.</summary>
    internal readonly Dictionary<string, List<CtorShape>> CtorShapes = new();

    /// <summary>Every declared <c>enum</c>'s short name → its declared member names, in
    /// declaration order (issue #492, slice C). Kept SEPARATE from <see cref="ClassNames"/> so a
    /// <c>Color.Green</c>-shaped member access is distinguishable from both a class's static
    /// field access and an unresolved cross-file receiver, and carrying the members (not just
    /// the name) so a typo — <c>Color.Grene</c> — fails loud rather than encoding a field access
    /// nothing will ever resolve. The module-qualified name is not stored: it is
    /// <see cref="QualifiedTypeName"/> of the key, and a member reference encodes against the
    /// SHORT name (<c>field_access(reference("Color"), "Green")</c>).</summary>
    internal readonly Dictionary<string, List<string>> EnumMembers = new();

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

        foreach (var decl in typeDecls.OfType<EnumDeclarationSyntax>())
        {
            EnumMembers[decl.Identifier.Text] = decl.Members.Select(m => m.Identifier.Text).ToList();
        }

        var drafts = new Dictionary<string, List<CtorDraft>>(StringComparer.Ordinal);

        foreach (var decl in typeDecls.OfType<TypeDeclarationSyntax>())
        {
            var shortName = decl.Identifier.Text;
            var fieldNames = new List<string>();
            var ctorShapes = new List<CtorDraft>();

            // C# 12 primary constructor (`class Point(int x, int y);` / the long-standing
            // positional-record shorthand `record Point(int X, int Y);`) — its parameters
            // double as both the constructor's param list AND the type's implicit fields, so
            // parameter i maps straight onto field i.
            if (decl.ParameterList is not null)
            {
                var primaryParams = decl.ParameterList.Parameters.Select(p => p.Identifier.Text).ToList();
                fieldNames.AddRange(primaryParams);
                ctorShapes.Add(new CtorDraft(
                    primaryParams,
                    primaryParams.Select((name, i) => new CtorAssignment(name, i, null)).ToList(),
                    ThisChainArgs: null));
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
                        ctorShapes.Add(CollectCtorDraft(shortName, ctor));
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

            // Two constructors of the same arity cannot be told apart by a syntax-only
            // encoder (it has no semantic model to type-match arguments against parameters),
            // so that is a documented, loud scope limit rather than a coin flip. Reported at
            // COLLECTION time — the ambiguity is a property of the declaration, not of any
            // particular call site, so reporting it here names it once instead of once per
            // `new`.
            var duplicateArity = ctorShapes
                .GroupBy(shape => shape.ParamNames.Count)
                .FirstOrDefault(group => group.Count() > 1);
            if (duplicateArity is not null)
            {
                throw new EncoderException(
                    $"ball-encoder: class `{shortName}` declares {duplicateArity.Count()} " +
                    $"constructors taking {duplicateArity.Key} argument(s) — ambiguous " +
                    "constructor arity: a syntax-only encoder cannot disambiguate same-arity " +
                    "overloads (see Types.cs's module doc comment)");
            }

            drafts[shortName] = ctorShapes;
        }

        // SECOND pass: resolve `: this(...)` chains now that every sibling's shape is known.
        // C# permits a forward chain (the delegating constructor declared BEFORE its target),
        // so this cannot be folded into the loop above without silently mis-shaping one of the
        // two directions (issue #492, slice D).
        foreach (var (shortName, ctorDrafts) in drafts)
        {
            CtorShapes[shortName] = ResolveConstructorChains(shortName, ctorDrafts);
        }
    }

    /// <summary>
    /// Turn one class's <see cref="CtorDraft"/>s into finished <see cref="CtorShape"/>s,
    /// flattening every <c>: this(...)</c> chain (issue #492, slice D).
    ///
    /// <para>A chaining constructor's shape is the TARGET's assignments re-sourced through the
    /// initializer's own arguments, followed by the chaining constructor's own body
    /// assignments. Each of the target's assignments is either a literal (kept as written) or a
    /// reference to the target's parameter <c>i</c> — which the initializer supplies as its
    /// <c>i</c>'th argument, itself constrained to exactly the two shapes a plain constructor
    /// body already accepts: a bare reference to one of the CALLING constructor's parameters,
    /// or a literal.</para>
    ///
    /// <para>Resolution is recursive (a chain may target another chaining constructor) with an
    /// in-progress guard, so a cycle fails loud instead of overflowing the stack.</para>
    /// </summary>
    private static List<CtorShape> ResolveConstructorChains(string shortName, List<CtorDraft> drafts)
    {
        var resolved = new CtorShape?[drafts.Count];
        var inProgress = new bool[drafts.Count];

        for (var i = 0; i < drafts.Count; i++)
        {
            Resolve(i);
        }

        return resolved.Select(shape => shape!).ToList();

        CtorShape Resolve(int index)
        {
            if (resolved[index] is { } already)
            {
                return already;
            }

            var draft = drafts[index];
            if (draft.ThisChainArgs is null)
            {
                return resolved[index] = new CtorShape(draft.ParamNames, draft.OwnAssignments);
            }

            if (inProgress[index])
            {
                throw new EncoderException(
                    $"ball-encoder: constructor of `{shortName}` takes part in a cyclic " +
                    $"`this{draft.ThisChainArgs}` constructor chain");
            }

            inProgress[index] = true;
            var args = draft.ThisChainArgs.Arguments;
            var targetIndex = drafts.FindIndex(
                candidate => !ReferenceEquals(candidate, draft) && candidate.ParamNames.Count == args.Count);
            if (targetIndex < 0)
            {
                throw new EncoderException(
                    $"ball-encoder: constructor of `{shortName}` chains to " +
                    $"`this{draft.ThisChainArgs}`, but no sibling constructor takes " +
                    $"{args.Count} argument(s)");
            }

            var target = Resolve(targetIndex);
            var assignments = new List<CtorAssignment>();
            foreach (var (field, paramIndex, literal) in target.Assignments)
            {
                if (paramIndex < 0)
                {
                    // The target writes a constant for this field — the chain cannot change it.
                    assignments.Add(new CtorAssignment(field, -1, literal));
                    continue;
                }

                var argument = args[paramIndex].Expression;
                switch (argument)
                {
                    case IdentifierNameSyntax id when draft.ParamNames.IndexOf(id.Identifier.Text) >= 0:
                        assignments.Add(new CtorAssignment(field, draft.ParamNames.IndexOf(id.Identifier.Text), null));
                        break;
                    case LiteralExpressionSyntax constant:
                        assignments.Add(new CtorAssignment(field, -1, constant));
                        break;
                    default:
                        throw new EncoderException(
                            $"ball-encoder: constructor of `{shortName}` passes `{argument}` to " +
                            $"`this{draft.ThisChainArgs}` — only a reference to one of this " +
                            "constructor's own parameters, or a literal, is supported " +
                            "(construction encodes as a plain message_creation, so a chain is " +
                            "resolved syntactically, never interpreted)");
                }
            }

            // The chaining constructor's own body runs AFTER the delegated one, so its
            // assignments come last and win on any field both write.
            assignments.AddRange(draft.OwnAssignments);
            inProgress[index] = false;
            return resolved[index] = new CtorShape(draft.ParamNames, assignments);
        }
    }

    /// <summary>
    /// Reduce one constructor to its <see cref="CtorShape"/> by walking its body's TOP-LEVEL
    /// statements and recognising exactly two shapes:
    /// <list type="bullet">
    /// <item><c>field = paramName;</c> / <c>this.field = paramName;</c> — a bare-identifier
    /// right-hand side naming one of this constructor's own parameters.</item>
    /// <item><c>field = &lt;int|double|bool|string|null literal&gt;;</c> — a constant default.</item>
    /// </list>
    /// Anything else (a computed expression, a method call, <c>x ?? throw ...</c>) throws,
    /// naming the class and the offending statement. Kept deliberately NARROW and documented
    /// rather than clever, consistent with the rest of this encoder's fail-loud posture — and
    /// strictly better than the previous behaviour, which ignored the body entirely and
    /// therefore dropped such assignments in silence.
    ///
    /// <para>A <c>: this(...)</c> initializer is CARRIED, not resolved here — see
    /// <see cref="CtorDraft"/> and <see cref="ResolveConstructorChains"/>. A
    /// <c>: base(...)</c> initializer still throws: resolving it needs the SUPERCLASS's own
    /// constructor shapes and field list, a materially bigger scope decision, and routing it
    /// through the same-class path would silently build a message from the wrong class's
    /// fields.</para>
    /// </summary>
    private static CtorDraft CollectCtorDraft(string shortName, ConstructorDeclarationSyntax ctor)
    {
        var paramNames = ctor.ParameterList.Parameters.Select(p => p.Identifier.Text).ToList();

        ArgumentListSyntax? thisChainArgs = null;
        if (ctor.Initializer is { } initializer)
        {
            if (!initializer.ThisOrBaseKeyword.IsKind(SyntaxKind.ThisKeyword))
            {
                throw new EncoderException(
                    $"ball-encoder: constructor of `{shortName}` chains to a BASE constructor " +
                    $"(`{initializer}`) — only same-class `: this(...)` chaining is supported " +
                    "(a base chain needs the superclass's own constructor shapes and fields)");
            }

            thisChainArgs = initializer.ArgumentList;
        }

        var assignments = new List<CtorAssignment>();
        var statements = ctor.Body?.Statements
            ?? (ctor.ExpressionBody is null
                ? default
                : new SyntaxList<StatementSyntax>(SyntaxFactory.ExpressionStatement(ctor.ExpressionBody.Expression)));

        foreach (var statement in statements)
        {
            if (statement is not ExpressionStatementSyntax
                {
                    Expression: AssignmentExpressionSyntax
                    {
                        RawKind: (int)SyntaxKind.SimpleAssignmentExpression,
                    } assignment,
                })
            {
                throw NonTrivialCtorBody(shortName, statement);
            }

            var field = assignment.Left switch
            {
                IdentifierNameSyntax id => id.Identifier.Text,
                MemberAccessExpressionSyntax { Expression: ThisExpressionSyntax } thisField =>
                    thisField.Name.Identifier.Text,
                _ => null,
            };
            if (field is null)
            {
                throw NonTrivialCtorBody(shortName, statement);
            }

            switch (assignment.Right)
            {
                case IdentifierNameSyntax rhs when paramNames.IndexOf(rhs.Identifier.Text) >= 0:
                    assignments.Add(new CtorAssignment(field, paramNames.IndexOf(rhs.Identifier.Text), null));
                    break;
                case LiteralExpressionSyntax literal:
                    assignments.Add(new CtorAssignment(field, -1, literal));
                    break;
                default:
                    throw NonTrivialCtorBody(shortName, statement);
            }
        }

        return new CtorDraft(paramNames, assignments, thisChainArgs);
    }

    private static EncoderException NonTrivialCtorBody(string shortName, StatementSyntax statement) =>
        new($"ball-encoder: constructor of `{shortName}` has a non-trivial field assignment " +
            $"`{statement.ToString().Trim()}` — only `field = param;` and `field = literal;` are " +
            "supported (construction encodes as a plain message_creation, so a constructor body " +
            "is resolved syntactically, never interpreted)");

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
