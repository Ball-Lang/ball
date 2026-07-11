using Ball.Compiler;

namespace Ball.Engine.Conformance;

/// <summary>
/// The compiler-conformance leg (issue #384 acceptance item 2): compile each
/// fixture Ball → C# (<see cref="CSharpCompiler.Compile(V1.Program)"/>), run
/// the emitted C# in-memory with Roslyn (<see cref="CSharpRunner"/> — the same
/// technique <c>csharp/compiler/test/EndToEndTests.cs</c> uses for its four
/// proof programs, generalized to the whole corpus), and diff against the
/// golden. No <c>SelfHost</c> build flag needed — this never touches the
/// self-hosted engine. A fixture the Phase-4 compiler cannot yet emit for
/// (a documented scope gap — see <c>csharp/AGENTS.md</c>'s "Compiler" section)
/// counts as a failure, not a crash: the leg's job is an honest count.
/// </summary>
internal static class CompilerLeg
{
    public static int Run(string? onlyFixture)
    {
        var names = Fixtures.AllNames();
        var results = new List<FixtureResult>();
        var skipped = 0;

        foreach (var name in names)
        {
            if (onlyFixture is not null && name != onlyFixture)
            {
                continue;
            }

            if (!Fixtures.HasGolden(name))
            {
                skipped++;
                continue;
            }

            var expected = Fixtures.GoldenLines(name);
            var result = RunOne(name, expected);
            results.Add(result);

            if (onlyFixture is not null)
            {
                Console.WriteLine($"[{name}] {result.Status}" + (result.Detail is null ? "" : $"\n{result.Detail}"));
            }
        }

        return Summary.Print("Compiler (compile -> dotnet run)", results, skipped);
    }

    private static FixtureResult RunOne(string name, IReadOnlyList<string> expected)
    {
        string source;
        try
        {
            var program = Fixtures.LoadProgram(Fixtures.JsonPath(name));
            source = CSharpCompiler.Compile(program);
        }
        catch (Exception ex)
        {
            return new FixtureResult(name, FixtureStatus.Error, $"compile: {ex.Message}");
        }

        var outcome = CSharpRunner.Run(source);
        if (!outcome.Success)
        {
            return new FixtureResult(name, FixtureStatus.Error, outcome.Error);
        }

        var actual = Fixtures.SplitLines(outcome.Stdout!);
        if (actual.SequenceEqual(expected, StringComparer.Ordinal))
        {
            return new FixtureResult(name, FixtureStatus.Pass);
        }

        var detail =
            $"expected ({expected.Count}): {(expected.Count == 0 ? "<none>" : expected[0])}\n" +
            $"actual   ({actual.Count}): {(actual.Count == 0 ? "<none>" : actual[0])}";
        return new FixtureResult(name, FixtureStatus.Fail, detail);
    }
}
