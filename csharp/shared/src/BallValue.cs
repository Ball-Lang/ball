using System.Globalization;

namespace Ball.Shared;

/// <summary>
/// The root runtime value type. Every Ball expression evaluates to one of the
/// concrete subclasses. This is the C# analog of the Rust
/// <c>enum BallValue</c> (see <c>rust/shared/src/value.rs</c>) and the Dart
/// reference engine's typed value hierarchy — a sealed class hierarchy so the
/// compiler/engine can pattern-match exhaustively
/// (<c>value switch { BallInt i =&gt; …, BallList l =&gt; … }</c>).
///
/// <para>Primitives (<see cref="BallNull"/>/<see cref="BallBool"/>/
/// <see cref="BallInt"/>/<see cref="BallDouble"/>/<see cref="BallString"/>/
/// <see cref="BallBytes"/>) are immutable and value-semantic. The
/// collection/callable/message types (<see cref="BallList"/>/
/// <see cref="BallMap"/>/<see cref="BallMessage"/>/<see cref="BallFunction"/>)
/// are reference types, so <c>var b = a;</c> aliases the same backing — a
/// mutation through <c>b</c> is observable through <c>a</c>, exactly like Dart's
/// reference types (the invariant the self-hosted engine depends on).</para>
/// </summary>
public abstract class BallValue
{
    /// <summary>Ball's <c>null</c> (a process-wide singleton).</summary>
    public static readonly BallValue Null = BallNull.Instance;

    /// <summary>A boolean value (<c>true</c>/<c>false</c> are cached singletons).</summary>
    public static BallValue Bool(bool value) => value ? BallBool.True : BallBool.False;

    /// <summary>A 64-bit signed integer (Ball's <c>int</c>).</summary>
    public static BallValue Int(long value) => new BallInt(value);

    /// <summary>A 64-bit float (Ball's <c>double</c>).</summary>
    public static BallValue Double(double value) => new BallDouble(value);

    /// <summary>A UTF-16 string (Dart's <c>String</c> measure — see string ops).</summary>
    public static BallValue Str(string value) => new BallString(value);

    /// <summary>Raw bytes (Ball's <c>bytes</c> literal).</summary>
    public static BallValue Bytes(byte[] value) => new BallBytes(value);

    /// <inheritdoc />
    public override bool Equals(object? obj) => obj is BallValue other && ValueEquals(this, other);

    /// <inheritdoc />
    public abstract override int GetHashCode();

    /// <summary>
    /// Structural equality with Dart <c>num</c> cross-type promotion: an
    /// <see cref="BallInt"/> and a <see cref="BallDouble"/> compare equal when
    /// their numeric values match (Dart's <c>0 == 0.0</c>). Maps compare
    /// order-independently; functions compare by delegate identity. Ported from
    /// <c>rust/shared/src/value.rs</c>'s hand-written <c>PartialEq</c>.
    /// </summary>
    public static bool ValueEquals(BallValue a, BallValue b) => (a, b) switch
    {
        (BallInt ia, BallDouble db) => ia.Value == db.Value,
        (BallDouble da, BallInt ib) => da.Value == ib.Value,
        (BallNull, BallNull) => true,
        (BallBool ba, BallBool bb) => ba.Value == bb.Value,
        (BallInt ia, BallInt ib) => ia.Value == ib.Value,
        (BallDouble da, BallDouble db) => da.Value.Equals(db.Value),
        (BallString sa, BallString sb) => sa.Value == sb.Value,
        (BallBytes xa, BallBytes xb) => xa.Value.AsSpan().SequenceEqual(xb.Value),
        (BallList la, BallList lb) => ListStructuralEquals(la, lb),
        (BallMap ma, BallMap mb) => MapStructuralEquals(ma, mb),
        (BallMessage ma, BallMessage mb) => ma.TypeName == mb.TypeName && MapStructuralEquals(ma.Fields, mb.Fields),
        (BallFunction fa, BallFunction fb) => ReferenceEquals(fa.Callable, fb.Callable),
        _ => false,
    };

    private static bool ListStructuralEquals(BallList a, BallList b)
    {
        if (a.Count != b.Count)
        {
            return false;
        }

        for (var i = 0; i < a.Count; i++)
        {
            if (!ValueEquals(a.Get(i), b.Get(i)))
            {
                return false;
            }
        }

        return true;
    }

    private static bool MapStructuralEquals(BallMap a, BallMap b)
    {
        if (a.Count != b.Count)
        {
            return false;
        }

        foreach (var key in a.Keys)
        {
            var bv = b.Get(key);
            if (bv is null || !ValueEquals(a.Get(key)!, bv))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// Format a Ball <c>double</c> the way every reference engine's stdout does:
    /// NaN/Infinity spellings, distinct signed zero (issue #101), and whole
    /// numbers always keeping a trailing <c>.0</c>. Ordinary fractional values
    /// use .NET's shortest round-trippable representation, which agrees with
    /// Dart/JS double-to-string for every ordinary magnitude. Ports
    /// <c>format_double</c> from <c>rust/shared/src/value.rs</c>.
    /// </summary>
    internal static string FormatDouble(double value)
    {
        if (double.IsNaN(value))
        {
            return "NaN";
        }

        if (double.IsPositiveInfinity(value))
        {
            return "Infinity";
        }

        if (double.IsNegativeInfinity(value))
        {
            return "-Infinity";
        }

        if (value == 0.0)
        {
            return double.IsNegative(value) ? "-0.0" : "0.0";
        }

        if (value % 1.0 == 0.0 && Math.Abs(value) < 1e16)
        {
            return ((long)value).ToString(CultureInfo.InvariantCulture) + ".0";
        }

        return value.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>Shared <c>{key: value, …}</c> rendering for maps and messages.</summary>
    internal static string FormatEntries(IEnumerable<KeyValuePair<string, BallValue>> entries)
    {
        var parts = entries.Select(e => $"{e.Key}: {e.Value}");
        return "{" + string.Join(", ", parts) + "}";
    }

    /// <summary>
    /// The payload of an engine scalar value-model wrapper, or <c>null</c> if
    /// <paramref name="value"/> is not one. The self-hosted engine
    /// (<c>ball_value.dart</c>) boxes some scalars in its own
    /// <c>BallInt</c>/<c>BallDouble</c>/<c>BallString</c>/<c>BallBool</c> classes
    /// (e.g. a double literal is <c>BallDouble(lit.doubleValue)</c>, so whole
    /// doubles keep their trailing <c>.0</c>). Those classes carry no typeDef in
    /// the self-host program — they lower to a <c>BallMessage</c> whose single
    /// <c>value</c> field holds the native payload — so their own
    /// <c>toString()</c> override is absent from the dispatch table and a bare
    /// render would leak the map form <c>{value: 3.14}</c>. Rendering therefore
    /// delegates to the payload, which is a native <see cref="BallDouble"/> (etc.)
    /// that already formats reference-engine-exactly. Type-name matched (mirrors
    /// <c>IsOfType</c>'s <c>BallMap</c>/<c>BallObject</c> special-casing).
    /// </summary>
    internal static BallValue? ScalarWrapperPayload(BallValue value)
    {
        if (value is not BallMessage m)
        {
            return null;
        }

        var name = m.TypeName;
        var shortName = name.Contains(':') ? name[(name.LastIndexOf(':') + 1)..] : name;
        return shortName is "BallInt" or "BallDouble" or "BallString" or "BallBool"
            ? m.Get("value") ?? BallNull.Instance
            : null;
    }
}

/// <summary>Ball's <c>null</c>.</summary>
public sealed class BallNull : BallValue
{
    /// <summary>The single shared <c>null</c> instance.</summary>
    public static readonly BallNull Instance = new();

    private BallNull()
    {
    }

    /// <inheritdoc />
    public override int GetHashCode() => 0;

    /// <inheritdoc />
    public override string ToString() => "null";
}

/// <summary>A boolean value.</summary>
public sealed class BallBool : BallValue
{
    /// <summary>The shared <c>true</c> instance.</summary>
    public static readonly BallBool True = new(true);

    /// <summary>The shared <c>false</c> instance.</summary>
    public static readonly BallBool False = new(false);

    private BallBool(bool value) => Value = value;

    /// <summary>The wrapped boolean.</summary>
    public bool Value { get; }

    /// <inheritdoc />
    public override int GetHashCode() => Value.GetHashCode();

    /// <inheritdoc />
    public override string ToString() => Value ? "true" : "false";
}

/// <summary>A 64-bit signed integer (Ball's <c>int</c>).</summary>
public sealed class BallInt : BallValue
{
    /// <summary>Create an integer value.</summary>
    public BallInt(long value) => Value = value;

    /// <summary>The wrapped integer.</summary>
    public long Value { get; }

    /// <inheritdoc />
    // Hash through the double representation so a whole-valued BallDouble and an
    // equal BallInt (which ValueEquals treats as equal) hash identically.
    public override int GetHashCode() => ((double)Value).GetHashCode();

    /// <inheritdoc />
    public override string ToString() => Value.ToString(CultureInfo.InvariantCulture);
}

/// <summary>A 64-bit float (Ball's <c>double</c>).</summary>
public sealed class BallDouble : BallValue
{
    /// <summary>Create a double value.</summary>
    public BallDouble(double value) => Value = value;

    /// <summary>The wrapped double.</summary>
    public double Value { get; }

    /// <inheritdoc />
    public override int GetHashCode() => Value.GetHashCode();

    /// <inheritdoc />
    public override string ToString() => FormatDouble(Value);
}

/// <summary>A UTF-16 string.</summary>
public sealed class BallString : BallValue
{
    /// <summary>Create a string value.</summary>
    public BallString(string value) => Value = value;

    /// <summary>The wrapped string.</summary>
    public string Value { get; }

    /// <inheritdoc />
    public override int GetHashCode() => Value.GetHashCode();

    /// <inheritdoc />
    public override string ToString() => Value;
}

/// <summary>
/// Raw bytes (Ball's <c>bytes</c> literal). Reference engines render a bytes
/// literal as a list of individual byte integers, so <see cref="ToString"/>
/// matches a list of ints.
/// </summary>
public sealed class BallBytes : BallValue
{
    /// <summary>Create a bytes value (the array is used directly, not copied).</summary>
    public BallBytes(byte[] value) => Value = value;

    /// <summary>The wrapped bytes.</summary>
    public byte[] Value { get; }

    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.AddBytes(Value);
        return hash.ToHashCode();
    }

    /// <inheritdoc />
    public override string ToString() => "[" + string.Join(", ", Value) + "]";
}
