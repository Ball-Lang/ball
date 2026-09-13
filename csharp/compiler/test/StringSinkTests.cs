namespace Ball.Compiler.Tests;

/// <summary>
/// The declared text sink (issue #630): <c>std.sink_create</c> /
/// <c>sink_write</c> / <c>sink_to_string</c>.
///
/// <para><b>What was wrong.</b> Before #630 this compiler had NO sink at all —
/// <c>grep -r __buffer__ csharp/</c> found nothing — so a Ball program using a
/// <c>StringBuffer</c> was refused outright, even though every self-hosted
/// engine runs one fine (an engine's own sink is compiled
/// <c>engine_std.dart</c>, not this compiler's base-call table). The
/// representation itself was undeclared: a <c>__type__</c>/<c>__buffer__</c> map
/// hardcoded by name in the Dart engine and, with two incompatible shapes, in
/// the TS engine (issue #633).</para>
///
/// <para>These tests compile and RUN. The fixture's
/// <c>appendWord(out, 'c')</c> line is the one that fails SILENTLY when a target
/// backs the sink by value: a <c>StringBuilder</c> held in a field of a
/// reference-typed <see cref="Ball.Shared.BallMap"/> survives the call, a copied
/// value would not (the C# analog of issue #300's lost list appends).</para>
/// </summary>
public class StringSinkTests
{
    private static string CompileAndRun(string ballJsonPath) =>
        CSharpRunner.Run(CSharpCompiler.Compile(BallJson.Load(ballJsonPath)));

    private static string Golden(string expectedFile) =>
        File.ReadAllText(expectedFile).Replace("\r\n", "\n");

    [Fact]
    public void StringSink_Compiles_And_Runs_ByteExact()
    {
        var output = CompileAndRun(RepoPaths.Conformance("465_string_sink.ball.json"));
        Assert.Equal(Golden(RepoPaths.Conformance("465_string_sink.expected_output.txt")), output);
    }

    [Fact]
    public void StringSink_Emits_The_Runtime_Helpers()
    {
        var source = CSharpCompiler.Compile(
            BallJson.Load(RepoPaths.Conformance("465_string_sink.ball.json")));
        Assert.Contains("BallRuntime.SinkCreate(", source);
        Assert.Contains("BallRuntime.SinkWrite(", source);
        Assert.Contains("BallRuntime.SinkToString(", source);
    }
}
