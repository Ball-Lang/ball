using Ball.Shared;

namespace Ball.Compiler.Tests;

/// <summary>
/// What a USER-THROWN built-in Dart error reads as, on the compiled C# target
/// (issue #658).
///
/// <para><b>The bug.</b> Two mechanisms have to line up, and only one of them
/// was in place. The KEY: #616's <see cref="BallValue.DartErrorToString"/> reads
/// the <c>message</c> field, while every encoder stores a built-in error's
/// constructor argument POSITIONALLY (<c>StateError('boom')</c> is
/// <c>{arg0: 'boom'}</c> — a Dart built-in carries no <c>TypeDefinition</c>, so
/// the <c>argN</c> → parameter-name remap has nothing to resolve against). This
/// target closes that in <see cref="BallThrow"/>'s untyped constructor (#615),
/// NOT in the compiler, which is why the assertions below drive a real
/// <c>BallRuntime.Throw</c> rather than reading a hand-built message. The TABLE:
/// <c>ArgumentError</c> had NO entry — Dart spells it
/// <c>Invalid argument(s): nope</c>, and no runtime in the repo raises one, so
/// the name sat in no target's table while #641's closed-set checks (all keyed
/// on what a runtime RAISES) stayed green.</para>
///
/// <para><b>Why the tests did not catch it.</b> <c>465</c>/<c>467</c> print a
/// caught value only for a RUNTIME-raised error, whose payload
/// <see cref="BallThrow"/>'s typed constructor already built with a
/// <c>message</c> field; <c>146</c>/<c>464</c> read <c>e.message</c> but run on
/// the ENGINE, never through this compiler. The literal-throw path — the common
/// one in user code — was in no test on this target.</para>
///
/// <para>The cross-target guard is conformance fixture
/// <c>473_caught_user_thrown_builtin_error</c>, run by the compiler leg of
/// <c>csharp/engine/conformance</c>. This pins the runtime contract directly,
/// including the two things the fixture cannot state on its own: that
/// <c>.message</c> and <c>arg0</c> BOTH survive unprefixed, and that the table
/// stays closed.</para>
/// </summary>
public class UserThrownBuiltinErrorTests
{
    public static TheoryData<string, string, string> LiteralThrows() => new()
    {
        { "StateError", "boom", "Bad state: boom" },
        { "FormatException", "bad", "FormatException: bad" },
        { "RangeError", "oops", "RangeError: oops" },
        { "ArgumentError", "nope", "Invalid argument(s): nope" },
    };

    [Theory]
    [MemberData(nameof(LiteralThrows))]
    public void ALiteralThrow_ReadsAsDartsToString_AndKeepsItsRawMessage(
        string shortName, string message, string expected)
    {
        // Exactly what the compiler emits for `throw StateError('boom')`: the
        // module-qualified tag plus the positional ctor argument.
        var payload = new BallMessage(
            "main:" + shortName,
            new BallMap { ["arg0"] = BallValue.Str(message) });

        var ex = Assert.Throws<BallThrow>(() => BallRuntime.Throw(payload));

        Assert.Equal(expected, ex.Payload.ToString());
        // `.message` is the OTHER observable and a DIFFERENT string — the raw
        // constructor argument, never the prefixed form (conformance 464 reads
        // it). The positional key is kept too: nothing may depend on it being
        // consumed.
        Assert.Equal(BallValue.Str(message), payload.Get("message"));
        Assert.Equal(BallValue.Str(message), payload.Get("arg0"));
    }

    /// <summary>An explicit <c>message</c> is never overwritten by <c>arg0</c>.</summary>
    [Fact]
    public void AnExplicitMessageField_SurvivesTheAlias()
    {
        var payload = new BallMessage(
            "main:StateError",
            new BallMap { ["message"] = BallValue.Str("explicit"), ["arg0"] = BallValue.Str("positional") });

        Assert.Throws<BallThrow>(() => BallRuntime.Throw(payload));

        Assert.Equal(BallValue.Str("explicit"), payload.Get("message"));
        Assert.Equal("Bad state: explicit", payload.ToString());
    }

    /// <summary>
    /// The table stays CLOSED over Dart's own names: a user class whose name
    /// merely ends in <c>Error</c> and which carries a <c>message</c> field is
    /// not a Dart error and keeps the map rendering.
    /// </summary>
    [Fact]
    public void AUserErrorSuffixedClass_IsNotRenderedAsADartError()
    {
        var user = new BallMessage(
            "main:ValidationError",
            new BallMap { ["message"] = BallValue.Str("not a dart error") });

        Assert.Equal("{message: not a dart error}", user.ToString());
    }
}
