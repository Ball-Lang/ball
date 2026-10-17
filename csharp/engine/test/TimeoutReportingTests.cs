using Ball.Engine.Conformance;

namespace Ball.Engine.Tests;

/// <summary>
/// Guards issue #737: the round-trip leg's failure listing capped ALL non-pass
/// results at 50 lines, so a <see cref="FixtureStatus.Timeout"/> ranked 51st or
/// later among a leg's non-pass results never reached the log at all. That log
/// is exactly what <c>tools/ci/roundtrip_floor.sh</c>'s "no fixture may hang"
/// gate (issue #693) greps for a <c>TIMEOUT</c> line, so a hang ranked past the
/// cap was invisible to the one gate that exists specifically to catch it — the
/// C# round-trip row runs 76 passed / 282 failed at head, well past 50.
///
/// <para>The fix keeps the 50-line cap for ordinary (<see cref="FixtureStatus.Fail"/>/
/// <see cref="FixtureStatus.Error"/>) entries — the cap is a legitimate log-size
/// bound for those — and prints every <see cref="FixtureStatus.Timeout"/>
/// unconditionally.</para>
/// </summary>
public class TimeoutReportingTests
{
    private static List<FixtureResult> OrdinaryFailures(int count, string prefix = "a")
    {
        var results = new List<FixtureResult>();
        for (var i = 0; i < count; i++)
        {
            results.Add(new FixtureResult($"{prefix}_{i:D3}", FixtureStatus.Fail, "golden mismatch"));
        }

        return results;
    }

    [Fact]
    public void ATimeout_RankedPastThe50LineCap_StillPrints()
    {
        // 60 ordinary failures sort before "z_timeout_fixture" (issue #737's
        // reproduction needs the timeout to land AFTER the cap is exhausted),
        // so the pre-fix `.Take(50)` over the whole non-pass list would never
        // reach it.
        var results = OrdinaryFailures(60);
        results.Add(new FixtureResult("z_timeout_fixture", FixtureStatus.Timeout, "killed after 60s"));

        var writer = new StringWriter();
        Summary.Print("Round-Trip (compile -> encode -> Dart engine)", results, skippedCarveouts: 0, writer);
        var output = writer.ToString();

        Assert.Contains("z_timeout_fixture: TIMEOUT", output);
    }

    [Fact]
    public void MultipleTimeouts_PastTheCap_AllPrint()
    {
        var results = OrdinaryFailures(55);
        results.Add(new FixtureResult("z_timeout_one", FixtureStatus.Timeout, "killed after 60s"));
        results.Add(new FixtureResult("z_timeout_two", FixtureStatus.Timeout, "killed after 60s"));

        var writer = new StringWriter();
        Summary.Print("Round-Trip", results, skippedCarveouts: 0, writer);
        var output = writer.ToString();

        Assert.Contains("z_timeout_one: TIMEOUT", output);
        Assert.Contains("z_timeout_two: TIMEOUT", output);
    }

    /// <summary>
    /// The 50-line cap is a real bound, not accidentally removed along with the
    /// timeout fix: ordinary Fail/Error entries beyond the 50th must still be
    /// suppressed, and the "... and N more" count must reflect only the
    /// suppressed ORDINARY entries (never counting the always-printed timeouts).
    /// </summary>
    [Fact]
    public void OrdinaryFailures_StillCapAt50_AndTheSuppressedCountExcludesTimeouts()
    {
        var results = OrdinaryFailures(60);
        results.Add(new FixtureResult("z_timeout_fixture", FixtureStatus.Timeout, "killed after 60s"));

        var writer = new StringWriter();
        Summary.Print("Round-Trip", results, skippedCarveouts: 0, writer);
        var output = writer.ToString();

        // 60 ordinary failures, 50 printed, 10 suppressed — the timeout is
        // printed separately and must not inflate or deflate that count.
        Assert.Contains("... and 10 more", output);
        Assert.DoesNotContain("a_050:", output); // the 51st ordinary failure (0-indexed) is suppressed
        Assert.Contains("a_049:", output); // the 50th ordinary failure (0-indexed) still prints
    }

    /// <summary>Negative control: a leg with no timeout keeps its pre-#737 output exactly.</summary>
    [Fact]
    public void NoTimeouts_BehavesExactlyAsBefore()
    {
        var results = OrdinaryFailures(3);
        var writer = new StringWriter();
        var exit = Summary.Print("Compiler", results, skippedCarveouts: 0, writer);
        var output = writer.ToString();

        Assert.Equal(1, exit);
        Assert.Contains("Results: 0 passed, 3 failed, 3 total (0 skipped carve-outs)", output);
        Assert.Contains("a_000: FAIL", output);
        Assert.Contains("a_001: FAIL", output);
        Assert.Contains("a_002: FAIL", output);
        Assert.DoesNotContain("more", output);
    }

    /// <summary>A leg with zero failures still exits 0 and prints no failure block.</summary>
    [Fact]
    public void AllPassing_ExitsZero_AndPrintsNoFailureBlock()
    {
        var results = new List<FixtureResult> { new("a_000", FixtureStatus.Pass) };
        var writer = new StringWriter();
        var exit = Summary.Print("Engine", results, skippedCarveouts: 0, writer);

        Assert.Equal(0, exit);
        Assert.DoesNotContain("failures", writer.ToString());
    }
}
