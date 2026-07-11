using Ball.Shared;

namespace Ball.Shared.Tests;

/// <summary>
/// The JSON codec (<c>const JsonEncoder()/JsonDecoder().convert(x)</c>) and
/// DateTime built-in methods (<c>fromMillisecondsSinceEpoch</c>/<c>parse</c>/
/// <c>toIso8601String</c>) the self-hosted engine's <c>std_convert</c>/
/// <c>std_time</c> handlers dispatch to (issue #383). Semantics must match the
/// Dart reference engine byte-for-byte.
/// </summary>
public class JsonAndDateTimeMethodTests
{
    private static BallValue Call(string method, BallValue self, params BallValue[] args)
    {
        var input = new BallMap { ["self"] = self };
        for (var i = 0; i < args.Length; i++)
        {
            input.Set($"arg{i}", args[i]);
        }

        return BallRuntime.CallMethod(method, input);
    }

    private static BallValue JsonEncoder() => new BallMessage("main:JsonEncoder", new BallMap());

    private static BallValue JsonDecoder() => new BallMessage("main:JsonDecoder", new BallMap());

    // ── JSON encode ───────────────────────────────────────────────────────

    [Fact]
    public void JsonEncodeRendersCompactObject()
    {
        var data = new BallMap { ["name"] = BallValue.Str("Alice"), ["age"] = BallValue.Int(30) };
        Assert.Equal(BallValue.Str("{\"name\":\"Alice\",\"age\":30}"), Call("convert", JsonEncoder(), data));
    }

    [Fact]
    public void JsonEncodeHandlesListsNullBoolAndStringEscapes()
    {
        var data = new BallList(new BallValue[]
        {
            BallValue.Int(1),
            BallValue.Str("a\"b\n\t"),
            BallValue.Bool(true),
            BallValue.Null,
            new BallMap { ["k"] = BallValue.Double(1.5) },
        });
        Assert.Equal(BallValue.Str("[1,\"a\\\"b\\n\\t\",true,null,{\"k\":1.5}]"), Call("convert", JsonEncoder(), data));
    }

    [Fact]
    public void JsonEncodeKeepsWholeDoubleTrailingZero()
    {
        // Dart's num.toString() (which jsonEncode uses) keeps 2.0's `.0`.
        Assert.Equal(BallValue.Str("2.0"), Call("convert", JsonEncoder(), BallValue.Double(2.0)));
    }

    // ── JSON decode ───────────────────────────────────────────────────────

    [Fact]
    public void JsonDecodeParsesObjectPreservingOrderAndNumberKinds()
    {
        var decoded = Call("convert", JsonDecoder(), BallValue.Str("{\"x\":1,\"y\":2.5}"));
        var map = Assert.IsType<BallMap>(decoded);
        Assert.Equal("{x: 1, y: 2.5}", map.ToString()); // source order preserved
        Assert.IsType<BallInt>(map.Get("x"));           // integer literal → int
        Assert.IsType<BallDouble>(map.Get("y"));        // fractional literal → double
    }

    [Fact]
    public void JsonRoundTripsThroughEncodeThenDecode()
    {
        var original = new BallMap
        {
            ["a"] = BallValue.Int(1),
            ["b"] = new BallList(new BallValue[] { BallValue.Int(2), BallValue.Int(3) }),
        };
        var json = Call("convert", JsonEncoder(), original);
        var back = Call("convert", JsonDecoder(), json);
        Assert.Equal("{a: 1, b: [2, 3]}", back.ToString());
    }

    // ── DateTime ──────────────────────────────────────────────────────────

    [Fact]
    public void DateTimeFromMillisToIso8601StringIsUtcSuffixed()
    {
        var input = new BallMap
        {
            ["self"] = BallRuntime.TypeLiteral("DateTime"),
            ["arg0"] = BallValue.Int(1704067200000),
            ["isUtc"] = BallValue.Bool(true),
        };
        var dt = BallRuntime.CallMethod("fromMillisecondsSinceEpoch", input);
        Assert.Equal(BallValue.Str("2024-01-01T00:00:00.000Z"), Call("toIso8601String", dt));
    }

    [Fact]
    public void DateTimeParseRoundTripsMilliseconds()
    {
        var parsed = Call("parse", BallRuntime.TypeLiteral("DateTime"), BallValue.Str("2024-01-01T00:00:00.000Z"));
        Assert.Equal(BallValue.Int(1704067200000), ((BallMessage)parsed).Get("millisecondsSinceEpoch"));
    }
}
