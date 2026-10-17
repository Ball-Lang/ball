namespace Ball.Engine.Conformance;

/// <summary>
/// Prints the per-fixture PASSING SET a round-trip leg's output must carry
/// (issue #896, generalizing #836's Rust fix to the C#/Go/Python legs) so
/// <c>tools/ci/roundtrip_passset.sh</c> can diff it as a SET against a
/// committed baseline — a pass-COUNT floor cannot tell "nothing changed" from
/// "one fixture newly passes while a different one regresses", because the
/// count is identical either way.
///
/// <para>Mirrors <c>rust/engine/tests/roundtrip_conformance.rs</c>'s
/// <c>format_passing_block</c> byte for byte: the same
/// <c>Passing fixtures (&lt;N&gt;, sorted):</c> header, the same two-space
/// indent per fixture name, and a trailing blank line so
/// <c>tools/ci/roundtrip_passset.sh</c>'s parser — which stops at the first
/// blank line or the next <c>Results:</c> line, whichever comes first —
/// terminates the block cleanly regardless of what <see cref="Summary.Print"/>
/// writes afterward.</para>
///
/// <para><c>\n</c> is written explicitly rather than through
/// <see cref="TextWriter.WriteLine()"/>, so the block's line endings do not
/// depend on <see cref="TextWriter.NewLine"/> (CI runs this leg on
/// <c>ubuntu-latest</c>, but the parser is a plain line-oriented bash script
/// that must never see a stray <c>\r</c> baked into a fixture name).</para>
/// </summary>
internal static class PassingFixtures
{
    /// <summary>
    /// <paramref name="passing"/> must already be sorted (callers pass fixture
    /// names in the order <see cref="Fixtures.AllNames"/> produced them) — this
    /// never re-sorts it, mirroring the Rust printer's own contract.
    /// </summary>
    public static string Format(IEnumerable<string> passing)
    {
        var names = passing.ToList();
        var text = new System.Text.StringBuilder();
        text.Append("Passing fixtures (").Append(names.Count).Append(", sorted):\n");
        foreach (var name in names)
        {
            text.Append("  ").Append(name).Append('\n');
        }

        return text.ToString();
    }

    public static void Print(IEnumerable<string> passing, TextWriter? writer = null)
    {
        var w = writer ?? Console.Out;
        w.Write(Format(passing));
        w.Write('\n');
    }
}
