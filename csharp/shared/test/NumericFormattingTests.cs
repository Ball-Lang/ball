using Ball.Shared;

namespace Ball.Shared.Tests;

/// <summary>
/// <c>num.toStringAsFixed / toStringAsExponential / toStringAsPrecision</c> must
/// be byte-exact with the Dart reference engine (the self-hosted engine formats
/// numbers through these helpers). The three divergences from .NET's built-in
/// numeric format strings that these cover: round-half-<b>away-from-zero</b> on
/// an exact tie (not banker's ties-to-even), a <em>minimal</em> exponent
/// (<c>e+2</c>, not <c>e+002</c>), and Dart's trailing-zero padding + shortest
/// round-trip mantissa. Mirrors <c>cpp/shared/include/ball_emit_runtime.h</c> and
/// <c>rust/shared/src/runtime.rs</c>; the golden strings match
/// <c>tests/conformance/316_to_string_as_fixed</c> and
/// <c>357_num_exponential_precision</c>.
/// </summary>
public class NumericFormattingTests
{
    [Theory]
    // Positive / zero / integer / high-precision receivers.
    [InlineData(3.14159, 2, "3.14")]
    [InlineData(3.14159, 0, "3")]
    [InlineData(3.14159, 4, "3.1416")]
    [InlineData(0.0, 2, "0.00")]
    [InlineData(123.456, 1, "123.5")]
    [InlineData(1000.0, 2, "1000.00")]
    [InlineData(3.14159265358979, 5, "3.14159")]
    // Negative receivers, including the round-half-away-from-zero tie.
    [InlineData(-2.71828, 3, "-2.718")]
    [InlineData(-123.456, 1, "-123.5")]
    [InlineData(-1000.0, 2, "-1000.00")]
    [InlineData(-2.5, 0, "-3")] // .NET "F0" gives banker's -2; Dart rounds away → -3.
    [InlineData(2.5, 0, "3")]
    [InlineData(-3.14159265358979, 5, "-3.14159")]
    public void ToStringAsFixed_matches_Dart(double value, int digits, string expected) =>
        Assert.Equal(BallValue.Str(expected), BallRuntime.ToStringAsFixed(BallValue.Double(value), BallValue.Int(digits)));

    [Fact]
    public void ToStringAsFixed_on_int_receiver()
    {
        Assert.Equal(BallValue.Str("42.00"), BallRuntime.ToStringAsFixed(BallValue.Int(42), BallValue.Int(2)));
        Assert.Equal(BallValue.Str("-42.00"), BallRuntime.ToStringAsFixed(BallValue.Int(-42), BallValue.Int(2)));
    }

    [Fact]
    public void ToStringAsFixed_preserves_negative_zero()
    {
        // Dart keeps the sign of -0.0 (`(-0.0).toStringAsFixed(1)` → "-0.0"), and
        // .NET 10's IEEE-compliant "F" format preserves it too — no re-adding needed.
        Assert.Equal(BallValue.Str("-0.0"), BallRuntime.ToStringAsFixed(BallValue.Double(-0.0), BallValue.Int(1)));
    }

    [Theory]
    [InlineData(123.456, 2, "1.23e+2")]
    [InlineData(123.456, 0, "1e+2")]
    [InlineData(0.0, 2, "0.00e+0")]
    [InlineData(0.0, 0, "0e+0")]
    [InlineData(1.0, 3, "1.000e+0")] // trailing-zero padding
    [InlineData(100000.0, 2, "1.00e+5")]
    [InlineData(0.0001234, 2, "1.23e-4")] // negative exponent
    [InlineData(1234567.0, 3, "1.235e+6")]
    [InlineData(9.999, 2, "1.00e+1")] // rounding carry
    [InlineData(2.5, 0, "3e+0")] // exact tie, away from zero
    [InlineData(1.5, 0, "2e+0")]
    [InlineData(0.05, 1, "5.0e-2")]
    [InlineData(-123.456, 2, "-1.23e+2")]
    public void ToStringAsExponential_with_digits_matches_Dart(double value, int digits, string expected) =>
        Assert.Equal(BallValue.Str(expected), BallRuntime.ToStringAsExponential(BallValue.Double(value), BallValue.Int(digits)));

    [Theory]
    [InlineData(123.456, "1.23456e+2")] // shortest round-trip mantissa
    [InlineData(100000.0, "1e+5")]
    [InlineData(0.0001234, "1.234e-4")]
    [InlineData(1.0, "1e+0")]
    public void ToStringAsExponential_no_arg_is_shortest(double value, string expected) =>
        Assert.Equal(BallValue.Str(expected), BallRuntime.ToStringAsExponential(BallValue.Double(value), BallValue.Null));

    [Theory]
    [InlineData(123.456, 5, "123.46")] // fixed form
    [InlineData(123.456, 2, "1.2e+2")] // exponential form
    [InlineData(1.0, 3, "1.00")] // trailing-zero padding
    [InlineData(0.0001234, 2, "0.00012")] // small-magnitude fixed
    [InlineData(1234567.0, 3, "1.23e+6")]
    [InlineData(9.999, 2, "10")] // rounding carry
    [InlineData(55.0, 1, "6e+1")] // exact tie, away from zero
    [InlineData(100.0, 5, "100.00")]
    [InlineData(0.0, 3, "0.00")]
    [InlineData(-123.456, 4, "-123.5")]
    public void ToStringAsPrecision_matches_Dart(double value, int precision, string expected) =>
        Assert.Equal(BallValue.Str(expected), BallRuntime.ToStringAsPrecision(BallValue.Double(value), BallValue.Int(precision)));
}
