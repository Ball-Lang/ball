using Ball.Shared;

namespace Ball.Shared.Tests;

/// <summary>
/// Dynamic built-in-method dispatch the self-hosted engine relies on (issue
/// #383): the <c>RegExp</c> surface (<c>firstMatch</c>/<c>hasMatch</c>/
/// <c>allMatches</c>/<c>group</c>) the engine parses type/expression strings
/// with, and the core-collection copy/fill constructors
/// (<c>Map.from</c>/<c>List.of</c>/<c>List.filled</c>). Semantics must match the
/// Dart reference engine.
/// </summary>
public class BallMethodDispatchTests
{
    private static BallValue RegExp(string pattern) =>
        new BallMessage("main:RegExp", new BallMap { ["arg0"] = BallValue.Str(pattern) });

    private static BallValue Call(string method, BallValue self, params BallValue[] args)
    {
        var input = new BallMap { ["self"] = self };
        for (var i = 0; i < args.Length; i++)
        {
            input.Set($"arg{i}", args[i]);
        }

        return BallRuntime.CallMethod(method, input);
    }

    // ── RegExp ────────────────────────────────────────────────────────────

    [Fact]
    public void FirstMatchReturnsGroups()
    {
        var match = Call("firstMatch", RegExp(@"(\w+)\[(\d+)\]"), BallValue.Str("arr[42]"));
        Assert.IsNotType<BallNull>(match);
        Assert.Equal(BallValue.Str("arr[42]"), Call("group", match, BallValue.Int(0)));
        Assert.Equal(BallValue.Str("arr"), Call("group", match, BallValue.Int(1)));
        Assert.Equal(BallValue.Str("42"), Call("group", match, BallValue.Int(2)));
    }

    [Fact]
    public void FirstMatchReturnsNullWhenNoMatch()
    {
        Assert.IsType<BallNull>(Call("firstMatch", RegExp(@"\d+"), BallValue.Str("no digits")));
    }

    [Fact]
    public void HasMatchReflectsPresence()
    {
        Assert.Equal(BallValue.Bool(true), Call("hasMatch", RegExp("a"), BallValue.Str("cat")));
        Assert.Equal(BallValue.Bool(false), Call("hasMatch", RegExp("z"), BallValue.Str("cat")));
    }

    [Fact]
    public void AllMatchesEnumeratesEveryMatchInOrder()
    {
        var matches = (BallList)Call("allMatches", RegExp(@"\d"), BallValue.Str("a1b2c3"));
        Assert.Equal(3, matches.Count);
        Assert.Equal(BallValue.Str("1"), Call("group", matches.Get(0), BallValue.Int(0)));
        Assert.Equal(BallValue.Str("2"), Call("group", matches.Get(1), BallValue.Int(0)));
        Assert.Equal(BallValue.Str("3"), Call("group", matches.Get(2), BallValue.Int(0)));
    }

    [Fact]
    public void NonParticipatingGroupIsNull()
    {
        // The second alternative's group does not participate when the first matches.
        var match = Call("firstMatch", RegExp(@"(a)|(b)"), BallValue.Str("a"));
        Assert.Equal(BallValue.Str("a"), Call("group", match, BallValue.Int(1)));
        Assert.IsType<BallNull>(Call("group", match, BallValue.Int(2)));
    }

    [Fact]
    public void GroupOutOfRangeThrowsCatchably()
    {
        var match = Call("firstMatch", RegExp(@"(\d)"), BallValue.Str("7"));
        Assert.Throws<BallThrow>(() => Call("group", match, BallValue.Int(5)));
    }

    // ── Core-collection copy / fill constructors ───────────────────────────

    [Fact]
    public void MapCopyIsIndependentOfSource()
    {
        var source = new BallMap { ["a"] = BallValue.Int(1) };
        var copy = (BallMap)BallRuntime.MapCopy(source);
        source.Set("b", BallValue.Int(2));
        Assert.Equal(BallValue.Int(1), copy.Get("a"));
        Assert.Null(copy.Get("b")); // the later source mutation is not observed
    }

    [Fact]
    public void ListCopyIsIndependentOfSource()
    {
        var source = new BallList(new BallValue[] { BallValue.Int(1) });
        var copy = (BallList)BallRuntime.ListCopy(source);
        source.Add(BallValue.Int(2));
        Assert.Equal(1, copy.Count);
    }

    [Fact]
    public void ListFilledRepeatsTheFillValue()
    {
        var list = (BallList)BallRuntime.ListFilled(BallValue.Int(3), BallValue.Str("x"));
        Assert.Equal(3, list.Count);
        Assert.Equal(BallValue.Str("x"), list.Get(0));
        Assert.Equal(BallValue.Str("x"), list.Get(2));
    }
}
