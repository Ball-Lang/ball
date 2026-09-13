using System.Collections.Generic;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>
/// The encoder's one window onto a Roslyn <see cref="SemanticModel"/> — issue #492, W12-C
/// slice 1.
///
/// <para><b>Why an interface and not a nullable <c>SemanticModel</c> field.</b> The Dart
/// sibling's seam is a single nullable read (<c>expression.staticType</c>, null on an
/// unresolved AST), because the Dart analyser hangs resolution off the AST node itself. Roslyn
/// keeps it in a separate object, so the syntax-only path has no model to read at all. A named
/// interface with a "knows nothing" implementation gives the encoder exactly one shape to code
/// against, with no <c>if (_model is null)</c> scattered through the dispatch.</para>
///
/// <para><b>Policy: <see cref="SymbolInfo.Symbol"/> only, never
/// <see cref="SymbolInfo.CandidateSymbols"/>.</b> <c>Symbol</c> is the one Roslyn's own
/// overload resolution chose. Every other <see cref="CandidateReason"/> means the call site is
/// not a single determinate target — overload resolution failed, or the name is a member group,
/// or the call is late-bound — so it must be REPORTED (see <see cref="BindingFailure"/>), never
/// guessed at. Roslyn states the contract for the null case itself: <c>Symbol</c> is "the
/// symbol that was referred to by the syntax node, if any. Returns null if the given expression
/// did not bind successfully to a single symbol."</para>
/// </summary>
internal interface ISemanticQuery
{
    /// <summary>True only for a real, compilation-backed query. The resolution-free entry
    /// points (<c>Encode</c>/<c>EncodeLibrary</c>) answer false, and every symbol-gated
    /// behaviour is keyed off this so those paths stay byte-identical to before the seam
    /// existed.</summary>
    bool IsResolving { get; }

    /// <summary>The single method an invocation bound to, or null.</summary>
    IMethodSymbol? MethodFor(InvocationExpressionSyntax invocation);

    /// <summary>The constructor a <c>new X(...)</c> / <c>new(...)</c> bound to, or null.
    /// Roslyn binds the type name in an object-creation expression to the constructor itself:
    /// "If binding the type name C in the expression `new C(...)` the actual constructor bound
    /// to will be returned".</summary>
    IMethodSymbol? ConstructorFor(BaseObjectCreationExpressionSyntax creation);

    /// <summary>An expression's static type, or null when it has none or could not be bound.
    /// An ERROR type answers null: "I could not bind this" and "I bound this to a type that
    /// does not exist" are the same fact to every caller here.</summary>
    ITypeSymbol? TypeOf(ExpressionSyntax expression);

    /// <summary>The symbol a type declaration declares — the identity that tells a
    /// <c>partial</c> split (one symbol, many syntax parts) from a genuine short-name collision
    /// (many symbols, one name).</summary>
    INamedTypeSymbol? DeclaredType(BaseTypeDeclarationSyntax declaration);

    /// <summary>An expression's compile-time constant value, or null when it has none. This is
    /// what folds <c>nameof(x)</c> to the string the C# compiler itself computed.</summary>
    object? ConstantValue(ExpressionSyntax expression);

    /// <summary>Why an expression did not bind to a single symbol — the
    /// <see cref="CandidateReason"/> spelling, or null when there is nothing to add. Appended
    /// to the encoder's own loud errors so a binding failure names its cause instead of looking
    /// like an encoder scope gap.</summary>
    string? BindingFailure(ExpressionSyntax expression);
}

/// <summary>The syntax-only answer to every semantic question: "I don't know."</summary>
internal sealed class NullSemanticQuery : ISemanticQuery
{
    internal static readonly NullSemanticQuery Instance = new();

    private NullSemanticQuery()
    {
    }

    public bool IsResolving => false;

    public IMethodSymbol? MethodFor(InvocationExpressionSyntax invocation) => null;

    public IMethodSymbol? ConstructorFor(BaseObjectCreationExpressionSyntax creation) => null;

    public ITypeSymbol? TypeOf(ExpressionSyntax expression) => null;

    public INamedTypeSymbol? DeclaredType(BaseTypeDeclarationSyntax declaration) => null;

    public object? ConstantValue(ExpressionSyntax expression) => null;

    public string? BindingFailure(ExpressionSyntax expression) => null;
}

/// <summary>
/// The compilation-backed query. One <see cref="SemanticModel"/> per syntax tree, cached —
/// Roslyn's own guidance is that "an instance of SemanticModel caches local symbols and
/// semantic information. Thus, it is much more efficient to use a single instance of
/// SemanticModel when asking multiple questions about a syntax tree."
/// </summary>
internal sealed class RoslynSemanticQuery(CSharpCompilation compilation) : ISemanticQuery
{
    private readonly Dictionary<SyntaxTree, SemanticModel> _models = new();

    public bool IsResolving => true;

    public IMethodSymbol? MethodFor(InvocationExpressionSyntax invocation) =>
        ModelFor(invocation)?.GetSymbolInfo(invocation).Symbol as IMethodSymbol;

    public IMethodSymbol? ConstructorFor(BaseObjectCreationExpressionSyntax creation) =>
        ModelFor(creation)?.GetSymbolInfo(creation).Symbol as IMethodSymbol;

    public ITypeSymbol? TypeOf(ExpressionSyntax expression)
    {
        var type = ModelFor(expression)?.GetTypeInfo(expression).Type;
        return type is null || type.TypeKind == TypeKind.Error ? null : type;
    }

    public INamedTypeSymbol? DeclaredType(BaseTypeDeclarationSyntax declaration) =>
        ModelFor(declaration)?.GetDeclaredSymbol(declaration);

    public object? ConstantValue(ExpressionSyntax expression)
    {
        var constant = ModelFor(expression)?.GetConstantValue(expression);
        return constant is { HasValue: true } ? constant.Value.Value : null;
    }

    public string? BindingFailure(ExpressionSyntax expression)
    {
        var model = ModelFor(expression);
        if (model is null)
        {
            return null;
        }

        var info = model.GetSymbolInfo(expression);
        return info.Symbol is null && info.CandidateReason != CandidateReason.None
            ? info.CandidateReason.ToString()
            : null;
    }

    /// <summary>The model for the tree <paramref name="node"/> lives in, or null when that tree
    /// is not part of this compilation (which only happens if a caller mixes trees — asking
    /// Roslyn for a model of a foreign tree throws, so this answers "I don't know" instead).</summary>
    private SemanticModel? ModelFor(SyntaxNode node)
    {
        var tree = node.SyntaxTree;
        if (_models.TryGetValue(tree, out var cached))
        {
            return cached;
        }

        if (!compilation.SyntaxTrees.Contains(tree))
        {
            return null;
        }

        var model = compilation.GetSemanticModel(tree);
        _models[tree] = model;
        return model;
    }
}
