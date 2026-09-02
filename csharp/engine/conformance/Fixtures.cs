using System.Text.Json;
using System.Text.Json.Nodes;
using Ball.V1;
using Google.Protobuf;

namespace Ball.Engine.Conformance;

/// <summary>
/// Corpus discovery + golden loading, shared by every leg. Mirrors
/// <c>rust/engine/tests/self_host_conformance.rs</c>'s fixture walk.
/// </summary>
internal static class Fixtures
{
    /// <summary>
    /// The documented golden-less behavioral carve-outs (host-policy fixtures
    /// asserted by dedicated harnesses elsewhere, not by stdout diffing) — see
    /// <c>tests/conformance/CARVEOUTS.md</c>'s "Host-policy behavioral
    /// fixtures" section. Identical to the set the Dart/Rust/C++ runners skip.
    /// </summary>
    public static readonly IReadOnlySet<string> Carveouts = new HashSet<string>
    {
        "196_timeout",
        "197_memory_limit",
        "201_input_validation",
        "202_sandbox_mode",
    };

    public static string RepoRoot { get; } = FindRepoRoot();

    public static string ConformanceDir { get; } = Path.Combine(RepoRoot, "tests", "conformance");

    /// <summary>
    /// Every <c>tests/conformance/*.ball.json</c> fixture name (sorted,
    /// no extension), including carve-outs — callers filter as needed.
    /// </summary>
    public static IReadOnlyList<string> AllNames() =>
        Directory.EnumerateFiles(ConformanceDir, "*.ball.json")
            .Select(p => Path.GetFileName(p)[..^".ball.json".Length])
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToList();

    public static string JsonPath(string name) => Path.Combine(ConformanceDir, $"{name}.ball.json");

    public static string GoldenPath(string name) => Path.Combine(ConformanceDir, $"{name}.expected_output.txt");

    public static bool HasGolden(string name) => File.Exists(GoldenPath(name));

    /// <summary>
    /// Read the golden and split it into lines the same way captured stdout is
    /// split: normalize a trailing <c>\r</c> per line (goldens may carry
    /// Windows CRLF endings), and drop the single trailing empty element the
    /// terminating newline produces.
    /// </summary>
    public static IReadOnlyList<string> GoldenLines(string name) => SplitLines(File.ReadAllText(GoldenPath(name)));

    public static IReadOnlyList<string> SplitLines(string text)
    {
        var lines = text.Split('\n').Select(s => s.EndsWith('\r') ? s[..^1] : s).ToList();
        if (lines.Count > 0 && lines[^1].Length == 0)
        {
            lines.RemoveAt(lines.Count - 1);
        }

        return lines;
    }

    /// <summary>
    /// Reconstruct captured stdout exactly as the reference engines emit it
    /// (each <c>print(...)</c> writes its argument + <c>\n</c>) and split it
    /// the same way the golden is split — a single print's argument may embed
    /// its own <c>\n</c>, and the golden (captured from real stdout) splits
    /// those too. Mirrors the Rust self-host conformance runner.
    /// </summary>
    public static IReadOnlyList<string> ActualLines(IEnumerable<string> prints) =>
        SplitLines(string.Concat(prints.Select(s => s + "\n")));

    /// <summary>
    /// Describe an expected-vs-actual line mismatch by the FIRST line that
    /// actually differs, never by line 0. Printing only line 0 (what every leg
    /// used to do) renders a mismatch on any later line as a self-contradictory
    /// diff — <c>expected (3): 1</c> / <c>actual (3): 1</c> on a Fail — which
    /// reads as if the two matched and hides where they diverge.
    /// </summary>
    public static string DescribeMismatch(IReadOnlyList<string> expected, IReadOnlyList<string> actual)
    {
        var shared = Math.Min(expected.Count, actual.Count);
        for (var i = 0; i < shared; i++)
        {
            if (!string.Equals(expected[i], actual[i], StringComparison.Ordinal))
            {
                return $"line {i + 1} differs (expected {expected.Count} line(s), actual {actual.Count}): "
                    + $"expected {Quote(expected[i])} | actual {Quote(actual[i])}";
            }
        }

        // Every shared line matched, so one side is a strict prefix of the other.
        if (actual.Count > expected.Count)
        {
            return $"actual has {actual.Count} line(s), expected {expected.Count}; "
                + $"first extra line {Quote(actual[expected.Count])}";
        }

        if (actual.Count < expected.Count)
        {
            return $"actual has {actual.Count} line(s), expected {expected.Count}; "
                + $"first missing line {Quote(expected[actual.Count])}";
        }

        // Unreachable for a real mismatch (identical length + identical lines is
        // a pass) — say so rather than inventing a diff.
        return $"no line differs (expected and actual are both {expected.Count} identical line(s))";
    }

    private static string Quote(string s) => '"' + (s.Length <= 120 ? s : s[..120] + "…") + '"';

    // A handful of fixtures nest deeply enough (labeled loops, nested try-catch)
    // to exceed both System.Text.Json's default 64-level read cap and
    // Google.Protobuf's default 100-level JsonParser recursion limit (127/146/148
    // in the compiler/round-trip legs, mirroring the exact gap `Loader.cs`
    // documents and fixes for the engine leg). Lift both the same way.
    private const int MaxJsonDepth = 512;

    /// <summary>Load a <c>.ball.json</c> proto3-JSON <c>Any</c> envelope (strip <c>@type</c>) into a typed <see cref="Program"/>.</summary>
    public static Program LoadProgram(string path)
    {
        var envelope = JsonNode.Parse(File.ReadAllText(path), documentOptions: new JsonDocumentOptions { MaxDepth = MaxJsonDepth })!.AsObject();
        envelope.Remove("@type");
        var parser = new JsonParser(new JsonParser.Settings(MaxJsonDepth).WithIgnoreUnknownFields(true));
        return parser.Parse<Program>(envelope.ToJsonString());
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "proto", "ball", "v1", "ball.proto")))
            {
                return dir.FullName;
            }

            dir = dir.Parent;
        }

        throw new InvalidOperationException("could not locate the ball repo root from the conformance binary directory");
    }
}

/// <summary>Outcome of running one fixture through a leg.</summary>
internal enum FixtureStatus
{
    Pass,
    Fail,
    Error,
    Timeout,
}

/// <summary>One fixture's result, for the summary + failure listing.</summary>
internal sealed record FixtureResult(string Name, FixtureStatus Status, string? Detail = null);

/// <summary>
/// Shared summary printer — the exact <c>Results: N passed, M failed, T total</c>
/// line the CI matrix greps (issue #40/#384 precedent), plus a short failure
/// listing (capped, like the Rust runner) when not narrowed to a single fixture.
/// </summary>
internal static class Summary
{
    public static int Print(string legName, IReadOnlyList<FixtureResult> results, int skippedCarveouts)
    {
        var passed = results.Count(r => r.Status == FixtureStatus.Pass);
        var total = results.Count;
        var failed = total - passed;

        Console.WriteLine();
        Console.WriteLine($"=== C# {legName} ===");
        Console.WriteLine($"Results: {passed} passed, {failed} failed, {total} total ({skippedCarveouts} skipped carve-outs)");

        if (failed > 0)
        {
            Console.WriteLine();
            Console.WriteLine("--- failures ---");
            foreach (var r in results.Where(r => r.Status != FixtureStatus.Pass).Take(50))
            {
                var tag = r.Status switch
                {
                    FixtureStatus.Timeout => "TIMEOUT",
                    FixtureStatus.Error => "ERROR",
                    FixtureStatus.Fail => "FAIL",
                    _ => "?",
                };
                var detail = r.Detail is null ? "" : $": {Truncate(r.Detail, 200)}";
                Console.WriteLine($"  {r.Name}: {tag}{detail}");
            }

            if (results.Count(r => r.Status != FixtureStatus.Pass) > 50)
            {
                Console.WriteLine($"  ... and {results.Count(r => r.Status != FixtureStatus.Pass) - 50} more");
            }
        }

        return failed == 0 ? 0 : 1;
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "…";
}
