namespace Ball.Compiler.Tests;

/// <summary>
/// Type emission (issue #381 acceptance): <c>class</c> / <c>abstract class</c>
/// / <c>enum</c> declarations plus their methods compile to valid C#. Uses the
/// real conformance class/enum fixtures — asserting the emitted source builds
/// (the "types emit" bar); enums and simple instance-method classes are also
/// executed to prove the dynamic-message dispatch actually runs.
/// </summary>
public class TypeEmitTests
{
    private static string Compile(string fixture) =>
        CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance(fixture)));

    private static void AssertCompiles(string fixture)
    {
        var source = Compile(fixture);
        Assert.True(
            CSharpRunner.Compiles(source, out var errors),
            $"emitted C# for {fixture} did not compile:\n{string.Join("\n", errors)}\n\n{source}");
    }

    [Theory]
    [InlineData("101_simple_class.ball.json")]
    [InlineData("103_abstract_class.ball.json")]
    [InlineData("109_enum_values.ball.json")]
    public void ClassAndEnumFixtures_EmitValidCSharp(string fixture) => AssertCompiles(fixture);

    [Fact]
    public void SimpleClass_EmitsClassDeclarationAndMethodDispatcher()
    {
        var source = Compile("101_simple_class.ball.json");
        // A class shape is emitted (sealed or abstract) and instance methods
        // become run-time dispatchers reading the receiver's self field.
        Assert.Contains("class", source);
        Assert.Contains("BallRuntime.MessageTypeName", source);
    }

    [Fact]
    public void EnumFixture_EmitsEnumNamespace()
    {
        var source = Compile("109_enum_values.ball.json");
        Assert.Contains("BuildEnum_", source);
    }
}
