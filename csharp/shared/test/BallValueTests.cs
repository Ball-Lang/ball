using Ball.Shared;

namespace Ball.Shared.Tests;

/// <summary>
/// Tests for the polymorphic <see cref="BallValue"/> model: construction,
/// numeric cross-type equality (Dart <c>num</c> semantics — <c>0 == 0.0</c>),
/// and reference-engine-exact <c>ToString()</c> formatting. Mirrors
/// <c>rust/shared/src/value.rs</c>'s value tests.
/// </summary>
public class BallValueTests
{
    [Fact]
    public void FactoriesProduceExpectedVariants()
    {
        Assert.IsType<BallNull>(BallValue.Null);
        Assert.IsType<BallBool>(BallValue.Bool(true));
        Assert.IsType<BallInt>(BallValue.Int(42));
        Assert.IsType<BallDouble>(BallValue.Double(3.5));
        Assert.IsType<BallString>(BallValue.Str("hi"));
        Assert.IsType<BallBytes>(BallValue.Bytes(new byte[] { 1, 2, 3 }));

        Assert.Equal(42L, ((BallInt)BallValue.Int(42)).Value);
        Assert.Equal(3.5, ((BallDouble)BallValue.Double(3.5)).Value);
        Assert.True(((BallBool)BallValue.Bool(true)).Value);
        Assert.Equal("hi", ((BallString)BallValue.Str("hi")).Value);
    }

    [Fact]
    public void NullAndBoolAreSingletons()
    {
        Assert.Same(BallValue.Null, BallValue.Null);
        Assert.Same(BallValue.Bool(true), BallValue.Bool(true));
        Assert.Same(BallValue.Bool(false), BallValue.Bool(false));
    }

    [Fact]
    public void NumericCrossTypeEqualityMatchesDartNumSemantics()
    {
        // Dart's num.== treats 0 == 0.0 as true (both int and double are num).
        Assert.Equal(BallValue.Int(0), BallValue.Double(0.0));
        Assert.Equal(BallValue.Double(2.0), BallValue.Int(2));
        Assert.NotEqual(BallValue.Int(2), BallValue.Double(2.5));
        Assert.NotEqual(BallValue.Int(1), (BallValue)BallValue.Bool(true));

        // Equal values must hash equal (int 2 and double 2.0).
        Assert.Equal(BallValue.Int(2).GetHashCode(), BallValue.Double(2.0).GetHashCode());
    }

    [Fact]
    public void NestedListEqualityRecursesThroughNumericRule()
    {
        var a = new BallList(new BallValue[] { BallValue.Int(1) });
        var b = new BallList(new BallValue[] { BallValue.Double(1.0) });
        Assert.Equal((BallValue)a, (BallValue)b);
    }

    [Fact]
    public void MapEqualityIsOrderIndependent()
    {
        var a = new BallMap();
        a["x"] = BallValue.Int(1);
        a["y"] = BallValue.Int(2);
        var b = new BallMap();
        b["y"] = BallValue.Int(2);
        b["x"] = BallValue.Int(1);
        Assert.Equal((BallValue)a, (BallValue)b);
    }

    [Fact]
    public void FunctionEqualityIsClosureIdentity()
    {
        Func<BallValue, BallValue> id = v => v;
        var f = new BallFunction("f", id);
        var g = new BallFunction("g", id);
        var h = new BallFunction("h", v => v);
        Assert.Equal((BallValue)f, (BallValue)g); // same underlying delegate
        Assert.NotEqual((BallValue)f, (BallValue)h); // distinct delegate
    }

    [Theory]
    [InlineData(5.0, "5.0")]
    [InlineData(-2.0, "-2.0")]
    [InlineData(0.0, "0.0")]
    [InlineData(3.25, "3.25")]
    [InlineData(0.1, "0.1")]
    public void DoubleToStringKeepsDartFormatting(double value, string expected)
    {
        Assert.Equal(expected, BallValue.Double(value).ToString());
    }

    [Fact]
    public void DoubleToStringHandlesSpecialValues()
    {
        Assert.Equal("-0.0", BallValue.Double(-0.0).ToString());
        Assert.Equal("NaN", BallValue.Double(double.NaN).ToString());
        Assert.Equal("Infinity", BallValue.Double(double.PositiveInfinity).ToString());
        Assert.Equal("-Infinity", BallValue.Double(double.NegativeInfinity).ToString());
    }

    [Fact]
    public void ToStringMatchesReferenceEngineFormatting()
    {
        Assert.Equal("null", BallValue.Null.ToString());
        Assert.Equal("true", BallValue.Bool(true).ToString());
        Assert.Equal("42", BallValue.Int(42).ToString());
        Assert.Equal("hi", BallValue.Str("hi").ToString());
        Assert.Equal("[1, 2, 3]", BallValue.Bytes(new byte[] { 1, 2, 3 }).ToString());

        var list = new BallList(new BallValue[] { BallValue.Int(1), BallValue.Int(2) });
        Assert.Equal("[1, 2]", list.ToString());

        var map = new BallMap();
        map["a"] = BallValue.Int(1);
        map["b"] = BallValue.Str("x");
        Assert.Equal("{a: 1, b: x}", map.ToString());

        var msg = new BallMessage("Point", new BallMap());
        msg.Set("x", BallValue.Int(1));
        Assert.Equal("{x: 1}", msg.ToString());

        Assert.Equal("<function print>", new BallFunction("print", v => v).ToString());
        Assert.Equal("<lambda>", new BallFunction("", v => v).ToString());
    }
}
