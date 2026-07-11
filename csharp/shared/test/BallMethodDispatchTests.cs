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

    // ── Higher-order callbacks the engine invokes on its own values ─────────

    [Fact]
    public void FunctionApplyInvokesCalleeWithTheSolePositionalArgument()
    {
        // Function.apply(callee, [arg]) — self is the `Function` type literal.
        var callee = new BallFunction("inc", x => BallRuntime.Add(x, BallValue.Int(1)));
        var result = Call(
            "apply",
            BallRuntime.TypeLiteral("Function"),
            callee,
            new BallList(new[] { BallValue.Int(41) }));
        Assert.Equal(BallValue.Int(42), result);
    }

    [Fact]
    public void ReceiverApplyFormInvokesTheReceiver()
    {
        // callee.apply([arg]) — self is the callee itself.
        var callee = new BallFunction("double", x => BallRuntime.Multiply(x, BallValue.Int(2)));
        var result = Call("apply", callee, new BallList(new[] { BallValue.Int(21) }));
        Assert.Equal(BallValue.Int(42), result);
    }

    [Fact]
    public void FoldAccumulatesWithATwoParameterCombine()
    {
        // Iterable.fold(0, (acc, elem) => acc + elem) — the combine binds its two
        // parameters positionally (arg0/arg1), as the compiled engine emits them.
        var combine = new BallFunction(
            "add",
            input => BallRuntime.Add(
                BallRuntime.ArgGet(input, "acc", "arg0"),
                BallRuntime.ArgGet(input, "elem", "arg1")));
        var list = new BallList(new[] { BallValue.Int(1), BallValue.Int(2), BallValue.Int(3), BallValue.Int(4) });
        var result = Call("fold", list, BallValue.Int(0), combine);
        Assert.Equal(BallValue.Int(10), result);
    }

    [Fact]
    public void FoldOverAnEmptyListReturnsTheInitialValue()
    {
        var combine = new BallFunction("never", _ => throw new BallRuntimeException("must not run"));
        var result = Call("fold", new BallList(), BallValue.Str("seed"), combine);
        Assert.Equal(BallValue.Str("seed"), result);
    }
}
