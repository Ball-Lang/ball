namespace Ball.Shared;

/// <summary>
/// The runtime half of Dart-3 structured-pattern matching (issue #55's pattern
/// family). The compiler lowers a <c>switch</c> case's <c>pattern_expr</c> into
/// a boolean condition over these predicates plus a list of
/// <c>(binder, accessor)</c> pairs built from the projections
/// (<see cref="PatternIndex"/>/<see cref="PatternKeyGet"/>/…), so one recursive
/// pass yields one flat condition and one flat binding list.
///
/// <para><b>Every predicate here is total.</b> A shape mismatch (a map pattern
/// against a list, an ordering pattern against a string) is a <em>non-match</em>,
/// never a throw — the arm simply falls through to the next case. The one
/// deliberate exception is <see cref="PatternCastAssert"/>: Dart's <c>p as T</c>
/// <em>asserts</em> rather than refutes, so a mismatch throws a catchable
/// <c>TypeError</c> instead of trying the next case.</para>
/// </summary>
public static partial class BallRuntime
{
    /// <summary>
    /// The type test shared by <c>var x</c> / <c>_</c> / <c>Type(…)</c> /
    /// <c>as T</c> patterns — the same predicate <c>value is T</c> uses, so a
    /// typed binder (<c>case int x:</c>) and a typed wildcard (<c>case int _:</c>)
    /// can never diverge. A nullable <c>T?</c> also matches <c>null</c>.
    /// </summary>
    public static bool PatternIsType(BallValue value, string typeName) => IsOfType(value, typeName);

    /// <summary>A list subject — the gate every list pattern's element accessors sit behind.</summary>
    public static bool PatternIsList(BallValue value) => value is BallList;

    /// <summary>
    /// A map subject. A Ball <c>Set</c> materializes as a duplicate-free
    /// <see cref="BallList"/>, so it can never satisfy a map pattern (issue #178
    /// — a set must fall through to the next case, not match <c>case {…}:</c>).
    /// </summary>
    public static bool PatternIsMap(BallValue value) => value is BallMap;

    /// <summary>A list subject's length (0 for a non-list — a list gate always precedes this conjunct).</summary>
    public static int PatternLength(BallValue value) => value is BallList list ? list.Count : 0;

    /// <summary>Element <paramref name="index"/> of a list subject (<c>null</c> out of range — the length conjuncts guard it).</summary>
    public static BallValue PatternIndex(BallValue value, int index) =>
        value is BallList list && index >= 0 && index < list.Count
            ? list.Get(index)
            : BallValue.Null;

    /// <summary>
    /// The slice a rest element (<c>...var tail</c>) binds: the subject's
    /// elements after the <paramref name="skipFront"/> leading sub-patterns and
    /// before the <paramref name="skipBack"/> trailing ones.
    /// </summary>
    public static BallValue PatternSlice(BallValue value, int skipFront, int skipBack)
    {
        var result = new BallList();
        if (value is not BallList list)
        {
            return result;
        }

        for (var i = Math.Max(skipFront, 0); i < list.Count - skipBack; i++)
        {
            result.Add(list.Get(i));
        }

        return result;
    }

    /// <summary>Whether a map subject carries <paramref name="key"/> — a map pattern's key must be PRESENT (extra keys in the subject are fine).</summary>
    public static bool PatternHasKey(BallValue value, BallValue key) =>
        value is BallMap map && map.ContainsKey(MapKey(key));

    /// <summary>The value a map subject holds at <paramref name="key"/> (the accessor a map/record entry's sub-pattern matches against).</summary>
    public static BallValue PatternKeyGet(BallValue value, BallValue key) =>
        value is BallMap map ? map.Get(MapKey(key)) ?? BallValue.Null : BallValue.Null;

    /// <summary>
    /// A record pattern matches an <b>exact</b> shape: the subject's field count
    /// — excluding <c>__</c>-prefixed metadata keys — must equal the pattern's
    /// positional + named arity, so a 2-field pattern does not match a 3-field
    /// record.
    /// </summary>
    public static bool PatternRecordArity(BallValue value, int arity) =>
        value is BallMap map
        && map.Keys.Count(k => !k.StartsWith("__", StringComparison.Ordinal)) == arity;

    /// <summary>
    /// A relational pattern's ordering comparison (<c>&gt;</c>/<c>&lt;</c>/
    /// <c>&gt;=</c>/<c>&lt;=</c>). Both sides must be numeric: a non-numeric
    /// subject is a NON-match (the next case is tried), never a type error.
    /// </summary>
    public static bool PatternRelational(BallValue value, string op, BallValue operand)
    {
        if (value is not (BallInt or BallDouble) || operand is not (BallInt or BallDouble))
        {
            return false;
        }

        var left = AsDouble(value);
        var right = AsDouble(operand);
        return op switch
        {
            ">" => left > right,
            "<" => left < right,
            ">=" => left >= right,
            "<=" => left <= right,
            _ => throw new BallRuntimeException($"unsupported relational pattern operator '{op}'"),
        };
    }

    /// <summary>
    /// <c>p as T</c> — an assertion, not a refutation: a type mismatch throws a
    /// catchable Ball <c>TypeError</c> rather than falling through to the next
    /// case (the reference engine's <c>type cast failed</c>).
    /// </summary>
    public static bool PatternCastAssert(bool matched, string typeName) =>
        matched ? true : throw new BallThrow("TypeError", $"type cast failed: not a {typeName}");

    /// <summary>
    /// A <c>when</c> guard's result. Only a literal <c>true</c> is a match —
    /// anything else (including <c>null</c>) means the arm did NOT match and
    /// control falls through to the next case (the engine's <c>!= true</c>).
    /// </summary>
    public static bool PatternGuard(BallValue value) => value is BallBool b && b.Value;
}
