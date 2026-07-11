namespace Ball.Engine.Conformance;

/// <summary>
/// The primary Phase-7 leg (issue #384): drives the compiled self-hosted C#
/// engine over the whole <c>tests/conformance/</c> corpus and diffs each
/// fixture's stdout against its golden — the same corpus, comparison, and
/// carve-out handling as the Dart/Rust/C++ runners, so a pass here is
/// Dart-identical output. Requires <c>-p:SelfHost=true</c> (propagated to the
/// <c>Ball.Engine</c> project reference) — without it every fixture reports
/// <see cref="SelfHostPendingException"/>.
/// </summary>
internal static class EngineLeg
{
    /// <summary>Per-fixture wall-clock budget — a latent infinite loop must not wedge the whole sweep.</summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(120);

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
                if (onlyFixture is not null)
                {
                    Console.WriteLine($"[{name}] SKIP (no golden — behavioral carve-out)");
                }

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

        return Summary.Print("Self-Hosted Engine", results, skipped);
    }

    private static FixtureResult RunOne(string name, IReadOnlyList<string> expected)
    {
        var json = File.ReadAllText(Fixtures.JsonPath(name));

        Task<IReadOnlyList<string>> task = Task.Run(() => Ball.Engine.BallEngine.FromJson(json).Run());
        bool finished;
        try
        {
            finished = task.Wait(Timeout);
        }
        catch (AggregateException ex)
        {
            var inner = ex.InnerException ?? ex;
            return new FixtureResult(name, FixtureStatus.Error, inner.Message);
        }

        if (!finished)
        {
            // The engine's internal worker thread is left running (harmless for
            // a measurement run — mirrors the Rust runner's documented choice).
            return new FixtureResult(name, FixtureStatus.Timeout);
        }

        var prints = task.Result;
        var actual = Fixtures.ActualLines(prints);
        if (actual.SequenceEqual(expected, StringComparer.Ordinal))
        {
            return new FixtureResult(name, FixtureStatus.Pass);
        }

        var detail =
            $"expected ({expected.Count}): {DescribeFirst(expected)}\n" +
            $"actual   ({actual.Count}): {DescribeFirst(actual)}";
        return new FixtureResult(name, FixtureStatus.Fail, detail);
    }

    private static string DescribeFirst(IReadOnlyList<string> lines) =>
        lines.Count == 0 ? "<none>" : lines[0];
}
