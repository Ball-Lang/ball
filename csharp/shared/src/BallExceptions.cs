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
        Payload = NormalizePayload(payload);
        TypeName = null;
    }

    /// <summary>
    /// Mirror the reference engine's <c>std.throw</c> (engine_std.dart): the
    /// encoder stores a built-in exception's constructor argument positionally
    /// (<c>FormatException('bad')</c> → <c>{arg0: 'bad'}</c>) while Dart source
    /// reads it back as <c>e.message</c>, so a thrown instance carrying
    /// <c>arg0</c> and no <c>message</c> gains a <c>message</c> alias. Without
    /// it, <c>on FormatException catch (e)</c> bound a value whose
    /// <c>.message</c> read null (issue #615).
    /// </summary>
    private static BallValue NormalizePayload(BallValue payload)
    {
        BallMap? fields = payload switch
        {
            BallMessage message => message.Fields,
            BallMap map => map,
            _ => null,
        };
        if (fields is null || fields.ContainsKey("message"))
        {
            return payload;
        }

        if (fields.Get("arg0") is { } arg0)
        {
            fields.Set("message", arg0);
        }

        return payload;
    }

    /// <summary>
    /// Throw a typed Ball exception (e.g. <c>FormatException</c> from
    /// <c>int.parse</c>, <c>RangeError</c> from an out-of-range index) with a
    /// message. The self-hosted engine's <c>try</c> (compiled <c>_evalLazyTry</c>)
    /// binds the catch variable to this <see cref="Payload"/> and type-matches an
    /// <c>on &lt;Type&gt; catch</c> by the payload's <c>.runtimeType</c> — the same
    /// path the reference engine uses for a native Dart runtime error. So the
    /// payload is a <see cref="BallMessage"/> whose type name IS the exception
    /// type, making <c>payload.runtimeType == typeName</c> hold (a bare
    /// <see cref="BallValue.Str"/> would report <c>runtimeType == "String"</c> and
    /// never match). The clean message is still on <see cref="Exception.Message"/>
    /// for an uncaught throw's loud report.
    /// </summary>
    public BallThrow(string typeName, string message)
        : base(message)
    {
        TypeName = typeName;
        Payload = new BallMessage(typeName, new BallMap { ["message"] = BallValue.Str(message) });
    }

    /// <summary>The thrown Ball value.</summary>
    public BallValue Payload { get; }

    /// <summary>The Ball exception type name for <c>on Type catch</c> matching, if typed.</summary>
    public string? TypeName { get; }
}
