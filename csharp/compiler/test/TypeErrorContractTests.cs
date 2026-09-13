using Ball.Shared;

namespace Ball.Compiler.Tests;

/// <summary>
/// What a CAUGHT <c>TypeError</c> READS AS, on the compiled C# target
/// (issue #641).
///
/// <para><b>The bug.</b> #616 gave three of the four built-in Dart errors a
/// rendering entry in <c>BallValue.DartErrorToString</c> and left the fourth
/// out — while <c>BallPatterns.PatternCastAssert</c> raises exactly that fourth
/// one for every failed cast pattern. So a caught failed cast printed the raw
/// map form <c>{message: type cast failed: not a int}</c>, where Rust printed
/// <c>TypeError: type cast failed: not a int</c> and the Dart reference engine
/// printed the bare message. Three answers for one program.</para>
///
/// <para><b>The contract.</b> Dart's failed cast raises a <c>TypeError</c>
/// whose <c>toString()</c> IS its message — it is the ODD ONE OUT of the four,
/// carrying no <c>TypeError: </c> prefix — and that message names the value's
/// RUNTIME type before the target type:
/// <c>type 'String' is not a subtype of type 'int' in type cast</c>. Measured
/// against the Dart SDK, and reproduced by the golden of conformance fixture
/// <c>466_caught_type_error_to_string</c> (which <c>generate_conformance.dart</c>
/// captures by RUNNING the Dart source, so the reference is real Dart).</para>
///
/// <para><b>Why the tests did not catch it.</b> <c>302_cast_patterns</c> proves
/// a failed cast pattern throws, and prints a hardcoded literal from its catch
/// body — it pins that a throw happened, never what the value reads.</para>
/// </summary>
public class TypeErrorContractTests
{
    public static TheoryData<BallValue, string, string> Mismatches() => new()
    {
        { BallValue.Str("hi"), "int", "type 'String' is not a subtype of type 'int' in type cast" },
        { BallValue.Double(1.5), "int", "type 'double' is not a subtype of type 'int' in type cast" },
        { BallValue.Bool(true), "int", "type 'bool' is not a subtype of type 'int' in type cast" },
        { BallValue.Null, "int", "type 'Null' is not a subtype of type 'int' in type cast" },
        { BallValue.Int(7), "String", "type 'int' is not a subtype of type 'String' in type cast" },
    };

    [Theory]
    [MemberData(nameof(Mismatches))]
    public void AFailedCastAssert_IsTypedAndReadsAsDartsToString(
        BallValue value, string typeName, string expected)
    {
        var ex = Assert.Throws<BallThrow>(() => BallPatterns.PatternCastAssert(false, value, typeName));

        Assert.Equal("TypeError", ex.TypeName);
        Assert.Equal(expected, ex.Payload.ToString());
    }

    /// <summary>A matching cast answers <c>true</c> so it can sit as a conjunct in the pattern's <c>&amp;&amp;</c> chain.</summary>
    [Fact]
    public void AMatchingCastAssert_PassesThrough()
    {
        Assert.True(BallPatterns.PatternCastAssert(true, BallValue.Int(42), "int"));
    }

    /// <summary>
    /// The rendering table stays CLOSED: a user class that merely declares a
    /// <c>message</c> field is not a Dart error and keeps the map rendering.
    /// </summary>
    [Fact]
    public void AUserMessageCarryingAMessageField_IsNotRenderedAsATypeError()
    {
        var user = new BallMessage("main:CastReport", new BallMap { ["message"] = BallValue.Str("hello") });

        Assert.Equal("{message: hello}", user.ToString());
    }
}
