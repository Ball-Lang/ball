using System.Text.RegularExpressions;

namespace Ball.Shared;

/// <summary>
/// Regular-expression built-in methods for the self-hosted engine (issue #383,
/// Round 5). The engine's own Dart source parses type/expression strings with
/// <c>RegExp</c> (e.g. <c>RegExp(r'^(\w+)&lt;(.+)&gt;$').firstMatch(name)</c>),
/// which the Ball → C# compiler lowers to:
/// <list type="bullet">
/// <item>a <see cref="BallMessage"/> of type <c>RegExp</c> whose constructor's
/// first positional arg (<c>arg0</c>) is the pattern source, and</item>
/// <item>empty-module method calls <c>firstMatch</c>/<c>hasMatch</c>/
/// <c>allMatches</c> on it, then <c>group</c> on the returned match.</item>
/// </list>
///
/// <para>Dart's default <c>RegExp</c> flags (case-sensitive, not multi-line, not
/// dot-all, not unicode) line up with .NET's default <see cref="Regex"/> options,
/// so no option translation is needed for the engine's ASCII source-parsing
/// patterns; both engines see identical match/group results.</para>
/// </summary>
public static partial class BallRuntime
{
    /// <summary>The reserved <see cref="BallMessage.TypeName"/> of a materialized regex match.</summary>
    private const string MatchMarker = "$Match";

    /// <summary>True if <paramref name="value"/> is a compiled-engine <c>RegExp</c> message.</summary>
    private static bool IsRegExp(BallValue value) =>
        value is BallMessage m && (m.TypeName == "RegExp" || m.TypeName.EndsWith(":RegExp", StringComparison.Ordinal));

    /// <summary>Build a .NET <see cref="Regex"/> from a compiled-engine <c>RegExp</c> receiver (pattern in <c>arg0</c>).</summary>
    private static Regex RegexOf(BallValue self)
    {
        if (!IsRegExp(self))
        {
            throw new BallRuntimeException($"expected a RegExp receiver, got {TypeName(self)}");
        }

        var source = ((BallMessage)self).Get("arg0")
            ?? throw new BallRuntimeException("RegExp receiver has no pattern (arg0)");
        return new Regex(AsStr(source));
    }

    /// <summary>
    /// Materialize a .NET <see cref="Match"/> as a Ball value the engine can read:
    /// a <see cref="BallMessage"/> of type <see cref="MatchMarker"/> carrying its
    /// numbered groups (an absent/failed group is <see cref="BallValue.Null"/>, as
    /// Dart's <c>Match.group</c> returns <c>null</c>).
    /// </summary>
    private static BallValue MatchValue(Match match)
    {
        var groups = new BallList();
        for (var i = 0; i < match.Groups.Count; i++)
        {
            var g = match.Groups[i];
            groups.Add(g.Success ? BallValue.Str(g.Value) : BallValue.Null);
        }

        var fields = new BallMap();
        fields.Set("groups", groups);
        fields.Set("start", BallValue.Int(match.Index));
        fields.Set("end", BallValue.Int(match.Index + match.Length));
        return new BallMessage(MatchMarker, fields);
    }

    /// <summary><c>RegExp(pattern).firstMatch(input)</c> — the first match, or <c>null</c>.</summary>
    private static BallValue RegexFirstMatch(BallValue self, BallValue input)
    {
        var match = RegexOf(self).Match(AsStr(input));
        return match.Success ? MatchValue(match) : BallValue.Null;
    }

    /// <summary><c>RegExp(pattern).hasMatch(input)</c> — whether the pattern occurs in the input.</summary>
    private static BallValue RegexHasMatch(BallValue self, BallValue input) =>
        BallValue.Bool(RegexOf(self).IsMatch(AsStr(input)));

    /// <summary><c>RegExp(pattern).allMatches(input)</c> — every non-overlapping match, in order.</summary>
    private static BallValue RegexAllMatches(BallValue self, BallValue input)
    {
        var list = new BallList();
        foreach (Match match in RegexOf(self).Matches(AsStr(input)))
        {
            list.Add(MatchValue(match));
        }

        return list;
    }

    /// <summary><c>Match.group(n)</c> — the n-th capturing group (0 = whole match), or <c>null</c> if it did not participate.</summary>
    private static BallValue MatchGroup(BallValue self, BallValue index)
    {
        if (self is not BallMessage m || m.TypeName != MatchMarker)
        {
            throw new BallRuntimeException($"group() on a non-match value: {TypeName(self)}");
        }

        var groups = AsList(m.Get("groups") ?? BallValue.Null);
        var n = AsIndex(index);
        if (n >= groups.Count)
        {
            throw new BallThrow(BallValue.Str($"RangeError: no group {n} (match has {groups.Count} groups)"));
        }

        return groups.Get(n);
    }
}
