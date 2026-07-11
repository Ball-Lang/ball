namespace Ball.Shared;

/// <summary>
/// A descriptor-backed message instance — the runtime materialization of a
/// <c>MessageCreation</c> whose <c>type_name</c> is a real user type (as opposed
/// to an untyped <c>MessageCreation</c> carrying a base function's named
/// arguments, which lowers to a bare <see cref="BallMap"/> via
/// <see cref="Fields.Extract"/>).
///
/// <para>A message is a class instance and therefore has <b>reference
/// semantics</b>: it holds its fields in a shared <see cref="BallMap"/>, so
/// <c>var b = a;</c> aliases the same field map and <c>b.Set("f", x)</c> is
/// observable through <c>a</c> — the property the self-hosted engine's mutable
/// <c>this</c> relies on (issue #298).</para>
/// </summary>
public sealed class BallMessage : BallValue
{
    /// <summary>Create a message instance owning <paramref name="fields"/> (shared backing).</summary>
    public BallMessage(string typeName, BallMap fields)
    {
        TypeName = typeName;
        Fields = fields;
    }

    /// <summary>The originating <c>TypeDefinition.name</c>.</summary>
    public string TypeName { get; }

    /// <summary>Field name → value, in a reference-semantic (shared) map.</summary>
    public BallMap Fields { get; }

    /// <summary>Number of fields.</summary>
    public int Count => Fields.Count;

    /// <summary>Whether the message has no fields.</summary>
    public bool IsEmpty => Fields.IsEmpty;

    /// <summary>Read field <paramref name="key"/>, or C# <c>null</c> if absent.</summary>
    public BallValue? Get(string key) => Fields.Get(key);

    /// <summary>Set field <paramref name="key"/> (reference semantics).</summary>
    public void Set(string key, BallValue value) => Fields.Set(key, value);

    /// <summary>Whether field <paramref name="key"/> is present.</summary>
    public bool ContainsKey(string key) => Fields.ContainsKey(key);

    /// <summary>Remove field <paramref name="key"/> (order-preserving), returning it or C# <c>null</c>.</summary>
    public BallValue? Remove(string key) => Fields.Remove(key);

    /// <inheritdoc />
    // Constant hash: mutable, never used as a hash key. See BallList.GetHashCode.
    public override int GetHashCode() => 0x11E550;

    /// <inheritdoc />
    // An engine scalar value-model wrapper (BallDouble/BallInt/…) renders as its
    // payload, not the map form `{value: …}` — see ScalarWrapperPayload.
    public override string ToString() =>
        ScalarWrapperPayload(this) is { } payload
            ? payload.ToString()!
            : FormatEntries(Fields.Entries());
}
