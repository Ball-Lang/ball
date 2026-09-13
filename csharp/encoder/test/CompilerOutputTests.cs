using System;
using System.IO;
using System.Linq;
using Ball.Compiler;
using Ball.Encoder;
using Ball.V1;
using Google.Protobuf;

namespace Ball.Encoder.Tests;

/// <summary>
/// The encoder must be able to read back what <see cref="CSharpCompiler"/> EMITS, not only
/// idiomatic hand-written C# (issue #642).
///
/// <para>Before this, the compiler's own output tripped three refusals at once — the
/// unconditional <c>BallOneofs</c> class, every <c>BallRuntime.*</c> base-call helper, and the
/// <c>BallValue</c> literal factories — so not one of the conformance fixtures could survive
/// Ball → C# → Ball, and the <c>csharp-roundtrip</c> matrix row measured a flat 0 while
/// reporting the harness healthy.</para>
///
/// <para>The whole-corpus proof is that row (<c>engine/conformance/RoundTripLeg.cs</c>, floored
/// and ratcheted in <c>conformance-matrix.yml</c>). These are the fast, in-solution guards on the
/// SHAPE, so a regression is a failing <c>dotnet test</c> rather than a matrix row nobody
/// ran.</para>
/// </summary>
public class CompilerOutputTests
{
    private static string CompileFixture(string name)
    {
        var root = RepoRoot();
        var path = Path.Combine(root, "tests", "conformance", name + ".ball.json");
        Assert.True(File.Exists(path), $"fixture {name} not found at {path}");
        var json = File.ReadAllText(path).Replace(
            "\"@type\": \"type.googleapis.com/ball.v1.Program\",", string.Empty);
        var program = JsonParser.Default.Parse<Program>(json);
        return CSharpCompiler.Compile(program);
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "tests", "conformance")))
        {
            dir = dir.Parent;
        }

        Assert.NotNull(dir);
        return dir!.FullName;
    }

    /// <summary>The compiler half: a program that references no oneof discriminator emits no
    /// <c>BallOneofs</c> class at all. It used to be emitted unconditionally — a dead five-field
    /// class in every compiled program, a hello-world included.</summary>
    [Fact]
    public void CompilerOutputHasNoDeadOneofClass()
    {
        var source = CompileFixture("265_enc_hello");
        Assert.DoesNotContain("BallOneofs", source, StringComparison.Ordinal);
    }

    /// <summary>The encoder half: the compiler's own hello-world re-encodes cleanly into a
    /// Program that declares <c>std.print</c> — proof that <c>BallRuntime.Print</c> and the
    /// <c>Str(...)</c> literal factory were both recognised.</summary>
    [Fact]
    public void EncodesCompilerOutput()
    {
        var source = CompileFixture("265_enc_hello");
        var program = CSharpEncoder.Encode(source);

        var std = program.Modules.Single(m => m.Name == "std");
        Assert.Contains(std.Functions, f => f.Name == "print");
    }

    /// <summary>The fail-loud boundary (issue #55): a <c>BallRuntime.*</c> helper with no
    /// universal std inverse is an error, never a silently dropped or guessed-at call.</summary>
    [Fact]
    public void UnknownRuntimeHelperFailsLoud()
    {
        const string source = """
            using Ball.Shared;
            internal static class BallProgram
            {
                public static void Main(string[] args)
                {
                    BallRuntime.SomeHelperThatDoesNotExist(BallValue.Null);
                }
            }
            """;

        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(source));
        Assert.Contains("unsupported runtime helper", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>The other half of the same boundary: a mapped helper called with the wrong
    /// number of arguments must fail rather than encode a base call with missing input
    /// fields.</summary>
    [Fact]
    public void RuntimeHelperArityIsChecked()
    {
        const string source = """
            using Ball.Shared;
            internal static class BallProgram
            {
                public static void Main(string[] args)
                {
                    BallRuntime.Add(BallValue.Null);
                }
            }
            """;

        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(source));
        Assert.Contains("expects 2 argument(s)", ex.Message, StringComparison.Ordinal);
    }

    /// <summary><c>BallValue.Null</c> is the compiler's spelling of a Ball null literal, and the
    /// encoder must read it as one rather than as a field access on an unknown receiver.</summary>
    [Fact]
    public void BallValueNullEncodesAsNullLiteral()
    {
        const string source = """
            using Ball.Shared;
            internal static class BallProgram
            {
                public static void Main(string[] args)
                {
                    BallRuntime.Print(BallValue.Null);
                }
            }
            """;

        var program = CSharpEncoder.Encode(source);
        var main = program.Modules.Single(m => m.Name == "main").Functions.Single(f => f.Name == "Main");
        var call = main.Body.Block.Statements[0].Expression.Call;
        Assert.Equal("std", call.Module);
        Assert.Equal("print", call.Function);
        var message = call.Input.MessageCreation.Fields.Single(f => f.Name == "message");
        Assert.Equal(Expression.ExprOneofCase.Literal, message.Value.ExprCase);
        Assert.Equal(Literal.ValueOneofCase.None, message.Value.Literal.ValueCase);
    }
}
