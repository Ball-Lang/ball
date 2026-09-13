using Ball.Shared;

namespace Ball.Shared.Tests;

/// <summary>
/// The two properties of the declared text sink (issue #630) that fail
/// SILENTLY when a target gets them wrong.
///
/// <list type="number">
/// <item><c>std.type_of</c> answers <c>"Sink"</c> — never the host type. A bare
/// <see cref="System.Text.StringBuilder"/> backing would answer
/// <c>"StringBuilder"</c> here and diverge from the reference engine and every
/// other target, so a Ball program branching on <c>type_of</c> would take a
/// different arm per target.</item>
/// <item>The sink is REFERENCE-SEMANTIC: a value handed to another function and
/// appended to there is observably longer to the caller. Precedent: issue #300,
/// where a by-value clone lost every list append.</item>
/// </list>
/// </summary>
public class SinkContractTests
{
    [Fact]
    public void SinkIsATaggedReferenceValue()
    {
        var sink = BallRuntime.SinkCreate(BallValue.Null);

        Assert.Equal("Sink", Assert.IsType<BallString>(BallStd.TypeOf(sink)).Value);

        BallRuntime.SinkWrite(sink, BallValue.Str("a"));
        // The by-value trap: hand the sink to a callee (what a compiled Ball
        // program does on every call) and append there.
        static void Append(BallValue s) => BallRuntime.SinkWrite(s, BallValue.Str("b"));
        Append(sink);

        Assert.Equal("ab", Assert.IsType<BallString>(BallRuntime.SinkToString(sink)).Value);
    }

    [Fact]
    public void SinkCreateSeedsFromInitial()
    {
        var sink = BallRuntime.SinkCreate(BallValue.Str("x"));
        BallRuntime.SinkWrite(sink, BallValue.Str("y"));
        Assert.Equal("xy", Assert.IsType<BallString>(BallRuntime.SinkToString(sink)).Value);
    }
}
