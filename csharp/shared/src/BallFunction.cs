namespace Ball.Shared;

/// <summary>
/// A first-class callable value — a compiled Ball <c>lambda</c>, or a top-level
/// function referenced as a value — wrapping a native C# delegate. Per Ball
/// invariant #1 (one input, one output) the delegate takes a single
/// <see cref="BallValue"/> and returns one. Two function values are equal iff
/// they share the same underlying delegate (closure identity — mirrors Rust's
/// <c>Arc::ptr_eq</c> and Dart's closure <c>==</c>).
/// </summary>
public sealed class BallFunction : BallValue
{
    /// <summary>Wrap a native delegate as a callable Ball function value.</summary>
    /// <param name="name">Cosmetic label (empty for an anonymous lambda).</param>
    /// <param name="callable">The compiled body (<c>input =&gt; …</c>).</param>
    public BallFunction(string name, Func<BallValue, BallValue> callable)
    {
        Name = name;
        Callable = callable;
    }

    /// <summary>Cosmetic label for display — never affects call behavior or equality.</summary>
    public string Name { get; }

    /// <summary>The native callable (identity is the equality key).</summary>
    public Func<BallValue, BallValue> Callable { get; }

    /// <summary>Invoke the wrapped delegate with <paramref name="input"/>.</summary>
    public BallValue Call(BallValue input) => Callable(input);

    /// <inheritdoc />
    public override int GetHashCode() => System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(Callable);

    /// <inheritdoc />
    public override string ToString() => Name.Length == 0 ? "<lambda>" : $"<function {Name}>";
}
