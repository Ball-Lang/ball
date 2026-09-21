using System.Text;

namespace Ball.Compiler.Tests;

/// <summary>
/// Extension-override dispatch (issue #670, fixture
/// <c>479_extension_override_selection</c>).
///
/// <para><c>Ext(receiver).member</c> is encoded as a call NAMING the
/// extension's own member (<c>&lt;module&gt;:&lt;Ext&gt;.&lt;member&gt;</c>)
/// with the receiver in <c>self</c>, because the selection is the whole meaning
/// of the node: two extensions can declare the SAME member on the SAME type,
/// and the plain <c>receiver.member</c> emission resolves by ordinary lookup —
/// a DIFFERENT member.</para>
///
/// <para>C# has no extensions in this lowering, so each member becomes a flat
/// static impl (<c>AlphaTag__tag</c>). The qualified call name matched no
/// callable, so it fell to <c>BallRuntime.CallMethod("main:AlphaTag.tag", …)</c>
/// — the Dart-SDK dispatcher, which asks the RECEIVER (an ordinary list here)
/// and could not tell the two extensions apart even if it knew the name.</para>
///
/// <para>These run on EVERY PR (<c>dotnet test Ball.slnx</c> in ci.yml's
/// <c>csharp</c> job). The whole-corpus <c>csharp-compiler</c> leg lives only
/// in conformance-matrix.yml, which has no <c>pull_request:</c> trigger and
/// RATCHETS an aggregate count — it fails only on a DROP, so it was green with
/// this fixture failing.</para>
/// </summary>
public class ExtensionOverrideTests
{
    private const string Fixture = "479_extension_override_selection";

    /// <summary>Reads a golden as BYTES, normalising only CRLF pairs (a lone <c>\r</c> can be semantic).</summary>
    private static string Golden(string expectedFile) =>
        Encoding.UTF8.GetString(File.ReadAllBytes(expectedFile)).Replace("\r\n", "\n");

    [Fact]
    public void ExtensionOverride_CallsTheNamedMemberImpl()
    {
        var source = CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance($"{Fixture}.ball.json")));

        foreach (var impl in new[]
                 {
                     "AlphaTag__tag(", "BetaTag__tag(",
                     "AlphaTag__label(", "BetaTag__label(",
                     "AlphaTag__scale(", "BetaTag__scale(",
                 })
        {
            Assert.Contains(impl, source);
        }

        // ...and none of them may go through the receiver-asking dispatcher,
        // which cannot tell the two extensions apart.
        Assert.DoesNotContain("BallRuntime.CallMethod(\"main:", source);
    }

    [Fact]
    public void ExtensionOverride_Runs_ByteExact()
    {
        var output = CSharpRunner.Run(
            CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance($"{Fixture}.ball.json"))));
        Assert.Equal(Golden(RepoPaths.Conformance($"{Fixture}.expected_output.txt")), output);
    }
}
