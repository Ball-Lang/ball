using Ball.Engine.Conformance;

namespace Ball.Engine.Tests;

/// <summary>
/// Guards issue #896 (generalizing #836's Rust fix to C#/Go/Python): a
/// round-trip leg's output must name its own per-fixture PASSING SET, because
/// a pass-COUNT floor cannot distinguish "nothing changed" from "one fixture
/// newly passes while a different one regresses" — the printed
/// <c>Results:</c> count is identical either way. Mirrors
/// <c>rust/engine/tests/roundtrip_conformance.rs</c>'s own
/// <c>format_passing_block</c> tests.
/// </summary>
public class PassingFixturesTests
{
    [Fact]
    public void HeaderNamesTheCount_AndListsEveryFixtureTwoSpaceIndented()
    {
        var block = PassingFixtures.Format(new[] { "100_a", "101_b" });

        Assert.Equal("Passing fixtures (2, sorted):\n  100_a\n  101_b\n", block);
    }

    [Fact]
    public void AnEmptyPassingSet_StillPrintsAWellFormedHeader()
    {
        Assert.Equal("Passing fixtures (0, sorted):\n", PassingFixtures.Format(Array.Empty<string>()));
    }

    /// <summary>
    /// THE regression this block exists to let a set-difference gate catch: a
    /// net-zero fixture swap (same cardinality, different membership) must
    /// print a DIFFERENT block — a bare count could never distinguish these
    /// two sets.
    /// </summary>
    [Fact]
    public void ANetZeroFixtureSwap_ChangesThePrintedBlock_EvenThoughTheCountIsUnchanged()
    {
        var before = new[] { "100_a", "101_b", "102_c" };
        var after = new[] { "100_a", "102_c", "103_d" }; // 101_b regressed, 103_d is new

        Assert.Equal(before.Length, after.Length);
        Assert.NotEqual(PassingFixtures.Format(before), PassingFixtures.Format(after));
    }

    [Fact]
    public void Print_WritesTheBlockPlusATrailingBlankLine()
    {
        var writer = new StringWriter();
        PassingFixtures.Print(new[] { "100_a" }, writer);

        Assert.Equal("Passing fixtures (1, sorted):\n  100_a\n\n", writer.ToString());
    }

    /// <summary>
    /// <see cref="RoundTripLeg"/> prints the passing block BEFORE
    /// <see cref="Summary.Print"/>'s own header + <c>Results:</c> line, so the
    /// block's own blank-line terminator must stop
    /// <c>tools/ci/roundtrip_passset.sh</c>'s parser before it ever reaches
    /// that unrelated header text.
    /// </summary>
    [Fact]
    public void TheBlockAloneTerminatesOnItsOwnBlankLine_BeforeAnyFollowingText()
    {
        var writer = new StringWriter();
        PassingFixtures.Print(new[] { "100_a", "101_b" }, writer);
        writer.Write("=== C# Round-Trip (compile -> encode -> Dart engine) ===\n");
        writer.Write("Results: 2 passed, 0 failed, 2 total\n");

        var lines = writer.ToString().Split('\n');
        Assert.Equal("Passing fixtures (2, sorted):", lines[0]);
        Assert.Equal("  100_a", lines[1]);
        Assert.Equal("  101_b", lines[2]);
        Assert.Equal(string.Empty, lines[3]); // the blank-line terminator
    }
}
