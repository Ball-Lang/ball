namespace Ball.Shared;

/// <summary>
/// A hard runtime fault raised by the base-op helper layer for a malformed
/// program shape (a type mismatch, an out-of-range operand, division by zero,
/// an unimplemented base call). The runtime <b>fails loud</b> rather than
/// silently returning a placeholder — mirrors the Rust runtime's
/// <c>panic!</c>s. Distinct from <see cref="BallThrow"/>, which models a Ball
/// <c>throw</c> that user code can <c>catch</c>.
/// </summary>
public sealed class BallRuntimeException : Exception
{
    /// <summary>Create a runtime fault with a descriptive message.</summary>
    public BallRuntimeException(string message)
        : base("ball runtime: " + message)
    {
    }
}

/// <summary>
/// A catchable Ball exception — the runtime representation of <c>throw value</c>
/// (and typed throws like <c>FormatException</c>). Carries the thrown
/// <see cref="BallValue"/> payload so a <c>catch</c> handler can inspect it, and
/// an optional Ball type name for <c>on &lt;Type&gt; catch</c> matching. Mirrors
/// Rust's <c>ball_throw</c>/<c>ball_throw_typed</c>.
/// </summary>
public sealed class BallThrow : Exception
{
    /// <summary>Throw an arbitrary Ball value.</summary>
    public BallThrow(BallValue payload)
        : base(payload.ToString())
    {
        Payload = payload;
        TypeName = null;
    }

    /// <summary>Throw a typed Ball exception (e.g. <c>FormatException</c>) with a message.</summary>
    public BallThrow(string typeName, string message)
        : base(message)
    {
        TypeName = typeName;
        Payload = BallValue.Str(message);
    }

    /// <summary>The thrown Ball value.</summary>
    public BallValue Payload { get; }

    /// <summary>The Ball exception type name for <c>on Type catch</c> matching, if typed.</summary>
    public string? TypeName { get; }
}
