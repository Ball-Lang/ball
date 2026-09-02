using Ball.Engine.Conformance;

namespace Ball.Engine.Tests;

/// <summary>
/// Guards the conformance harness's own failure reporting.
///
/// <para>Every leg (<c>engine</c>/<c>compiler</c>/<c>roundtrip</c>) used to
/// describe an expected-vs-actual mismatch by printing line 0 of each side. When
/// the two agreed on line 0 and diverged later — fixture 406's golden was
/// <c>1/5/7</c> against an actual of <c>1/1/1</c> — the failure printed
/// <c>expected (3): 1</c> / <c>actual (3): 1</c>: a Fail whose own diff reads as
/// if the two matched. That is a silent-degradation bug in the diagnostics, and
/// it materially slowed down reading a real failure.</para>
///
/// <para>The invariant these tests pin: the description must always point at a
/// place the two sequences genuinely differ — a differing line index, or the
/// length difference — never at a line that matches.</para>
/// </summary>
public class MismatchDescriptionTests
{
    [Fact]
    public void Describes_TheFirstDifferingLine_NotLineZero()
    {
        var expected = new[] { "1", "5", "7" };
        var actual = new[] { "1", "1", "1" };

        var detail = Fixtures.DescribeMismatch(expected, actual);

        // The load-bearing part: it names line 2 (the first real divergence)
        // and shows both of THAT line's values, so the diff cannot read as a
        // match.
        Assert.Contains("line 2 differs", detail);
        Assert.Contains("expected \"5\"", detail);
        Assert.Contains("actual \"1\"", detail);
    }

    [Fact]
    public void Describes_AMissingTrailingLine_WhenActualIsShorter()
    {
        var detail = Fixtures.DescribeMismatch(["a", "b", "c"], ["a", "b"]);

        Assert.Contains("actual has 2 line(s), expected 3", detail);
        Assert.Contains("first missing line \"c\"", detail);
    }

    [Fact]
    public void Describes_AnExtraTrailingLine_WhenActualIsLonger()
    {
        var detail = Fixtures.DescribeMismatch(["a"], ["a", "b"]);

        Assert.Contains("actual has 2 line(s), expected 1", detail);
        Assert.Contains("first extra line \"b\"", detail);
    }

    [Fact]
    public void Describes_AnEmptyActual_AgainstANonEmptyGolden()
    {
        var detail = Fixtures.DescribeMismatch(["only"], []);

        Assert.Contains("actual has 0 line(s), expected 1", detail);
        Assert.Contains("first missing line \"only\"", detail);
    }

    /// <summary>
    /// Never invent a divergence: identical sequences are a pass, and if a leg
    /// ever asks for a description anyway it must say so plainly rather than
    /// printing a bogus line diff.
    /// </summary>
    [Fact]
    public void SaysSo_WhenNothingActuallyDiffers()
    {
        Assert.Contains("no line differs", Fixtures.DescribeMismatch(["a", "b"], ["a", "b"]));
    }
}
