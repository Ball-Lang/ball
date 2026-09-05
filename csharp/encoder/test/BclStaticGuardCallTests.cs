using System;
using System.IO;
using System.Linq;
using Ball.Compiler;
using Ball.Compiler.Tests;
using Ball.Shared;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// Static guard calls on a BCL type — <c>ArgumentNullException.ThrowIfNull(x)</c> and
/// <c>Debug.Assert(...)</c> — issue #492, bucket (i).
///
/// <para><b>Where the gap came from.</b> <c>EncodeMemberInvocation</c> knew exactly two
/// static BCL receivers, <c>Console</c> and <c>Math</c>. Every other capitalised receiver
/// fell through <c>StaticReceiverName</c>'s same-file-class lookup into
/// <c>DispatchInstanceOrBuiltinMethod</c>, which has no entry for either name and so threw
/// <c>unsupported method call `.ThrowIfNull(...)` with 1 argument(s)</c>. In a fresh Tier A
/// run over the four pinned packages that fallback throw accounts for 104 of the 349
/// first-pass encode errors, and <c>ThrowIfNull</c> is the highest-count NAMED shape inside
/// it (7 files); <c>Debug.Assert</c> is the same class of call with the same fix.</para>
///
/// <para><b>What they route to.</b> Both are "throw unless this holds", which is exactly
/// universal <c>std.assert</c> (<c>AssertInput { condition, message }</c>) — already declared
/// by <c>StdModuleBuilders</c>, already compiled by <c>BaseCall.CompileAssertStatement</c>,
/// already interpreted by every engine. No new base function, no proto change, no
/// cross-language work: this was purely an encoder-side gap in a function that has been wired
/// end to end since day one and that the C# encoder had simply never emitted.</para>
///
/// <para><b>Deliberate approximations, documented rather than hidden.</b> (1) The thrown
/// exception is a <c>BallRuntimeException</c>, not an <c>ArgumentNullException</c> or a
/// <c>DebugAssertException</c> — Ball's <c>assert</c> is the single portable "fail here"
/// primitive and the type of the fault is not modelled. (2) .NET compiles
/// <c>Debug.Assert</c> away outside a <c>DEBUG</c> build; Ball has no conditional compilation,
/// so the encoded assert always runs. That is a STRENGTHENING (an assertion that holds in a
/// debug build holds in a release build), never a weakening, and it is the same style of
/// documented approximation as <c>Console.Write</c> becoming a newline-terminated
/// <c>std.print</c>.</para>
///
/// <para><b>Why the 2-argument <c>ThrowIfNull(value, paramName)</c> overload is NOT routed.</b>
/// Its second argument is the exception's parameter name, and in the measured corpus it is
/// always spelled <c>nameof(x)</c> — a shape this syntax-only encoder has no model for at all
/// (it would encode as an unresolvable user call to a function named <c>nameof</c>). Routing
/// it would trade one loud encode error for a program that encodes and then does not build —
/// the "encodes, and then is wrong" defect class #492 has already had to fix once. It stays a
/// loud, specific error, and <see cref="TwoArgumentThrowIfNullStillFailsLoud"/> is the
/// regression guard that keeps it that way.</para>
/// </summary>
public class BclStaticGuardCallTests
{
    /// <summary>Bucket (i)'s committed fixture text, read from the same file the sweep
    /// encodes so the end-to-end proof below cannot drift from it.</summary>
    private static string BucketIFixture =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "realworld", "i_bcl_static_guards.cs"));

    [Fact]
    public void ThrowIfNullEncodesAsAnAssertOnNotEqualsNull()
    {
        var call = StatementCall("""
            using System;

            class Program
            {
                static void Main()
                {
                    var name = "ball";
                    ArgumentNullException.ThrowIfNull(name);
                }
            }
            """, index: 1);

        Assert.Equal("std", call.Module);
        Assert.Equal("assert", call.Function);
        Assert.Equal("AssertInput", call.Input.MessageCreation.TypeName);

        var condition = Field(call, "condition");
        Assert.Equal("std", condition.Call.Module);
        Assert.Equal("not_equals", condition.Call.Function);
        Assert.Equal("name", Field(condition.Call, "left").Reference.Name);

        // The null side must be a real null literal (no value set on the oneof),
        // not an all-defaults literal that merely reads back as 0 or "".
        var right = Field(condition.Call, "right");
        Assert.Equal(Expression.ExprOneofCase.Literal, right.ExprCase);
        Assert.Equal(Literal.ValueOneofCase.None, right.Literal.ValueCase);

        // The message names the guarded expression, so a failure says which one it was.
        Assert.Contains("name", Field(call, "message").Literal.StringValue);
    }

    /// <summary>The 1-argument <c>Debug.Assert(cond)</c> passes its condition straight
    /// through and emits NO message field — the compiler's own <c>"assertion failed"</c>
    /// default is the right text, and inventing one here would diverge from what every
    /// other target prints for a message-less assert.</summary>
    [Fact]
    public void OneArgumentDebugAssertPassesTheConditionThroughWithNoMessage()
    {
        var call = StatementCall("""
            using System.Diagnostics;

            class Program
            {
                static void Main()
                {
                    var ok = true;
                    Debug.Assert(ok);
                }
            }
            """, index: 1);

        Assert.Equal("std", call.Module);
        Assert.Equal("assert", call.Function);
        Assert.Equal("ok", Field(call, "condition").Reference.Name);
        Assert.DoesNotContain(call.Input.MessageCreation.Fields, f => f.Name == "message");
    }

    /// <summary>The 2-argument overload is a 1:1 passthrough of BOTH arguments — the
    /// cleanest possible route, with no derived condition at all.</summary>
    [Fact]
    public void TwoArgumentDebugAssertPassesConditionAndMessageThrough()
    {
        var call = StatementCall("""
            using System.Diagnostics;

            class Program
            {
                static void Main()
                {
                    var ok = true;
                    Debug.Assert(ok, "ok must hold");
                }
            }
            """, index: 1);

        Assert.Equal("assert", call.Function);
        Assert.Equal("ok", Field(call, "condition").Reference.Name);
        Assert.Equal("ok must hold", Field(call, "message").Literal.StringValue);
    }

    /// <summary>A same-file user class named <c>Debug</c> must WIN over the BCL route — the
    /// new arms are a fallback for a name this file does not declare, never a capture of the
    /// name itself. (<c>Debug</c> is a far more plausible user type name than
    /// <c>Console</c>/<c>Math</c>, which is why this guard exists.)</summary>
    [Fact]
    public void SameFileUserClassNamedDebugWinsOverTheBclRoute()
    {
        var call = StatementCall("""
            class Debug
            {
                public static bool Assert(bool condition)
                {
                    return condition;
                }
            }

            class Program
            {
                static void Main()
                {
                    var ok = true;
                    Debug.Assert(ok);
                }
            }
            """, index: 1);

        // A same-module user call carries an empty module (the encoder's
        // Builders.UserCall shape), never "std".
        Assert.Equal(string.Empty, call.Module);
        Assert.Equal("Debug_Assert", call.Function);
    }

    /// <summary><c>ArgumentNullException.ThrowIfNull(value, paramName)</c> must keep failing
    /// loud — see the class doc comment. The error has to name the receiver rather than fall
    /// back to the generic instance-dispatch message.</summary>
    [Fact]
    public void TwoArgumentThrowIfNullStillFailsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram("""
            using System;

            class Program
            {
                static void Main()
                {
                    string arg = "x";
                    ArgumentNullException.ThrowIfNull(arg, "arg");
                }
            }
            """));

        Assert.Contains("ArgumentNullException", ex.Message);
        Assert.Contains("ThrowIfNull", ex.Message);
    }

    /// <summary>An unmodelled member on either new receiver stays a loud error naming that
    /// receiver — a regression guard against over-widening the new arms into "anything
    /// called on <c>Debug</c> is an assert".</summary>
    [Theory]
    [InlineData("System.Diagnostics", "Debug.WriteLine(\"x\")", "Debug")]
    [InlineData("System", "ArgumentNullException.ThrowIfNullOrEmpty(\"x\")", "ArgumentNullException")]
    public void UnmodelledMemberOnAGuardReceiverFailsLoud(string usings, string call, string receiver)
    {
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram($$"""
            using {{usings}};

            class Program
            {
                static void Main()
                {
                    {{call}};
                }
            }
            """));

        Assert.Contains(receiver, ex.Message);
    }

    /// <summary>
    /// The end-to-end proof: bucket (i)'s own fixture, ENCODED, compiled back to C#, and
    /// executed on its satisfied guards — <c>"ball"</c> is non-null, starts with <c>"b"</c>
    /// and is non-empty, so all three guards pass and stdout is exactly <c>BALL\n</c>. An
    /// encode-only assertion would declare the bucket closed while its output did not run
    /// (the precedent is bucket (e), whose encoded fixture compiled clean and then crashed
    /// because the C# COMPILER read a LINQ callback under the wrong field name).
    /// </summary>
    [Fact]
    public void BucketIFixtureEncodesCompilesAndRuns()
    {
        var output = CSharpRunner.Run(CSharpCompiler.Compile(TestHelpers.EncodeProgram(BucketIFixture)));
        Assert.Equal("BALL\n", output);
    }

    /// <summary>
    /// The other half of the round-trip proof, and the one that makes an INVERTED condition
    /// visible: with a null argument the guard must actually throw. Encoding
    /// <c>ThrowIfNull</c> as <c>assert(equals(x, null))</c> would pass the happy-path test
    /// above and then silently never fire on a real null — this test is what fails on that.
    /// </summary>
    [Fact]
    public void ThrowIfNullOnANullArgumentThrowsAtRunTime()
    {
        var compiled = CSharpCompiler.Compile(TestHelpers.EncodeProgram("""
            using System;

            class Program
            {
                static void Main()
                {
                    string name = null;
                    ArgumentNullException.ThrowIfNull(name);
                    Console.WriteLine("unreachable");
                }
            }
            """));

        var ex = Assert.Throws<BallRuntimeException>(() => CSharpRunner.Run(compiled));
        Assert.Contains("name", ex.Message);
    }

    /// <summary>The same inversion guard for <c>Debug.Assert</c>: a false condition must
    /// throw, carrying the message the source gave it.</summary>
    [Fact]
    public void DebugAssertOnAFalseConditionThrowsAtRunTime()
    {
        var compiled = CSharpCompiler.Compile(TestHelpers.EncodeProgram("""
            using System;
            using System.Diagnostics;

            class Program
            {
                static void Main()
                {
                    var count = 0;
                    Debug.Assert(count > 0, "count must be positive");
                    Console.WriteLine("unreachable");
                }
            }
            """));

        var ex = Assert.Throws<BallRuntimeException>(() => CSharpRunner.Run(compiled));
        Assert.Contains("count must be positive", ex.Message);
    }

    /// <summary>A satisfied <c>Debug.Assert</c> must not swallow the rest of the program —
    /// the guard is a no-op on the happy path, in statement position.</summary>
    [Fact]
    public void SatisfiedDebugAssertRunsOn()
    {
        var compiled = CSharpCompiler.Compile(TestHelpers.EncodeProgram("""
            using System;
            using System.Diagnostics;

            class Program
            {
                static void Main()
                {
                    var count = 1;
                    Debug.Assert(count > 0, "count must be positive");
                    Console.WriteLine(count);
                }
            }
            """));

        Assert.Equal("1\n", CSharpRunner.Run(compiled));
    }

    private static Expression Field(FunctionCall call, string name) =>
        call.Input.MessageCreation.Fields.Single(f => f.Name == name).Value;

    private static FunctionCall StatementCall(string source, int index) =>
        TestHelpers.MainFunction(TestHelpers.EncodeProgram(source)).Body.Block.Statements[index].Expression.Call;
}
