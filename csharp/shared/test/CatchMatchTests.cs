using Ball.Shared;

namespace Ball.Shared.Tests;

/// <summary>
/// The clause-selection rule the compiled <c>try</c> dispatch relies on (issue
/// #615): a typed <c>on &lt;Type&gt; catch</c> matches a thrown value's type tag
/// by its FULL or BARE spelling, and an untagged value reports
/// <c>std.throw</c>'s own default, <c>Exception</c>.
/// </summary>
public class CatchMatchTests
{
    [Fact]
    public void BothSpellingsOfAModuleQualifiedTagMatch()
    {
        var thrown = new BallThrow(new BallMessage("main:StateError", new BallMap
        {
            ["arg0"] = BallValue.Str("boom"),
        }));

        Assert.True(BallRuntime.CatchMatches(thrown, "StateError"));
        Assert.True(BallRuntime.CatchMatches(thrown, "main:StateError"));
        Assert.False(BallRuntime.CatchMatches(thrown, "ArgumentError"));
        // A clause qualified by a DIFFERENT module must not match.
        Assert.False(BallRuntime.CatchMatches(thrown, "other:StateError"));
    }

    [Fact]
    public void AnExplicitTypeNameWinsOverThePayloadTag()
    {
        // The runtime-synthesized typed throw (int.parse, an out-of-range index).
        var thrown = new BallThrow("FormatException", "cannot parse");

        Assert.Equal("FormatException", BallRuntime.ExceptionTypeName(thrown));
        Assert.True(BallRuntime.CatchMatches(thrown, "FormatException"));
        Assert.False(BallRuntime.CatchMatches(thrown, "StateError"));
    }

    [Fact]
    public void AMapsTypeTagIsRead_AndAnUntaggedValueDefaultsToException()
    {
        var tagged = new BallThrow(new BallMap { ["__type__"] = BallValue.Str("RangeError") });
        Assert.True(BallRuntime.CatchMatches(tagged, "RangeError"));
        Assert.False(BallRuntime.CatchMatches(tagged, "StateError"));

        // std.throw tags an untagged value `Exception` (engine_std.dart).
        var untagged = new BallThrow(BallValue.Str("oops"));
        Assert.True(BallRuntime.CatchMatches(untagged, "Exception"));
        Assert.False(BallRuntime.CatchMatches(untagged, "StateError"));
    }

    [Fact]
    public void ThrowAliasesArg0AsMessage()
    {
        // The encoder stores `StateError('boom')`'s argument positionally while
        // Dart source reads it back as `e.message` — std.throw renames it.
        var thrown = new BallThrow(new BallMessage("main:StateError", new BallMap
        {
            ["arg0"] = BallValue.Str("boom"),
        }));

        Assert.Equal(BallValue.Str("boom"), BallRuntime.FieldGet(thrown.Payload, "message"));
    }

    [Fact]
    public void AnExplicitMessageIsNeverClobberedByArg0()
    {
        var thrown = new BallThrow(new BallMessage("main:StateError", new BallMap
        {
            ["arg0"] = BallValue.Str("positional"),
            ["message"] = BallValue.Str("explicit"),
        }));

        Assert.Equal(BallValue.Str("explicit"), BallRuntime.FieldGet(thrown.Payload, "message"));
    }
}
