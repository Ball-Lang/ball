using System.Text;

namespace Ball.Compiler.Tests;

/// <summary>
/// A <c>final</c> field a BODYLESS constructor's own initializer list assigns,
/// next to a user-written setter of the same name (issue #706, fixture
/// <c>472_initializer_list_field_with_setter</c>).
///
/// <para><b>The mechanism, measured.</b> <c>IndexConstructors</c> recorded a
/// class's UNNAMED constructor only when it carried a BODY, and
/// <c>CompileMessageCreation</c> invokes the constructor impl only for a class
/// that has such a recording. A bodyless
/// <c>FixedSlice(this.source, int end) : windowSize = end;</c> therefore took
/// the inline-field-map path, which knows <c>metadata.params</c> (the
/// <c>this.</c>-formals) but NOT <c>metadata.initializers</c> — so the emitted
/// instance carried the constructor's plain parameter <c>end</c> as a bogus
/// field and never carried <c>windowSize</c> at all.
/// <c>print(slice.windowSize)</c> then read a missing key and printed
/// <c>null</c>: a SILENT WRONG ANSWER, not a build failure.</para>
///
/// <para>Note what the mechanism is NOT: issue #706 hypothesised that "the
/// emitted setter shadows the field read". It does not. C# routes a property
/// read through <c>BallAccessors.Get__…</c>, which is emitted only for a name
/// some class declares as a GETTER — and a plain <c>final</c> field declares
/// none — so the read was an ordinary <c>BallRuntime.FieldGet</c> all along.
/// Dropping the initializer list is the whole of it, and it bites every
/// bodyless constructor with an initializer list, setter or no setter.</para>
///
/// <para>These run on EVERY PR (<c>dotnet test Ball.slnx</c> in ci.yml's
/// <c>csharp</c> job, default build). The whole-corpus <c>csharp-compiler</c>
/// leg that would also have measured this lives only in
/// conformance-matrix.yml, which has no <c>pull_request:</c> trigger and is a
/// RATCHET on an aggregate count — it fails only on a DROP, so it was green
/// with this fixture failing and stays green now that it passes.</para>
/// </summary>
public class FinalFieldSetterTests
{
    /// <summary>Reads a golden as BYTES, normalising only CRLF pairs (a lone <c>\r</c> can be semantic).</summary>
    private static string Golden(string expectedFile) =>
        Encoding.UTF8.GetString(File.ReadAllBytes(expectedFile)).Replace("\r\n", "\n");

    /// <summary>The field-READ pin: <c>print(slice.windowSize)</c> must print <c>3</c>, never <c>null</c>.</summary>
    [Fact]
    public void Fixture472_FinalFieldWithSetter_Runs_ByteExact()
    {
        var output = CSharpRunner.Run(
            CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance("472_initializer_list_field_with_setter.ball.json"))));
        Assert.Equal(Golden(RepoPaths.Conformance("472_initializer_list_field_with_setter.expected_output.txt")), output);
    }

    /// <summary>
    /// The construction site must INVOKE the constructor impl — the only place
    /// the initializer list is applied — and the INSTANCE map that impl builds
    /// must carry the initialized field, not the plain constructor parameter.
    ///
    /// <para>The distinction matters: the ARGUMENT map the call site packs is
    /// keyed by parameter name, so <c>["end"] = Int(3L)</c> is correct there.
    /// Only the <c>new BallMessage(...)</c> map is the instance, so the
    /// assertion is scoped to it.</para>
    /// </summary>
    [Fact]
    public void BodylessConstructorWithAnInitializerList_IsInvoked()
    {
        var source = CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance("472_initializer_list_field_with_setter.ball.json")));
        Assert.Contains("FixedSlice__new(", source, StringComparison.Ordinal);

        const string marker = "new BallMessage(\"main:FixedSlice\", new BallMap { ";
        var start = source.IndexOf(marker, StringComparison.Ordinal);
        Assert.True(start >= 0, $"no FixedSlice instance map in the emitted C#\n---\n{source}");
        var instanceMap = source[(start + marker.Length)..source.IndexOf('}', start)];
        Assert.Contains("[\"windowSize\"] = end", instanceMap, StringComparison.Ordinal);
        Assert.DoesNotContain("[\"end\"] = ", instanceMap, StringComparison.Ordinal);
    }

    /// <summary>The control: a constructor that DOES carry a body already applied its initializer list (issue #527) and must keep doing so.</summary>
    [Fact]
    public void Fixture438_BodyCarryingConstructorInitializerList_Runs_ByteExact()
    {
        var output = CSharpRunner.Run(
            CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance("438_ctor_initializer_list_with_body.ball.json"))));
        Assert.Equal(Golden(RepoPaths.Conformance("438_ctor_initializer_list_with_body.expected_output.txt")), output);
    }
}
