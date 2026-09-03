using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ball.CoverageStudy;

/// <summary>Front-end for the C# Tier A coverage study (issue #493) — the
/// sibling of <c>dart run tools/coverage-study/rq1_study.dart</c>.
///
/// <code>
/// dotnet run --project csharp/coverage-study/Ball.CoverageStudy.csproj -- \
///     --pins tools/coverage-study/packages/csharp.json --checkouts &lt;dir&gt; [--json &lt;out&gt;]
/// dotnet run --project csharp/coverage-study/Ball.CoverageStudy.csproj -- \
///     --package &lt;name&gt; --source-dir &lt;dir&gt; [--json &lt;out&gt;]
/// </code>
///
/// Report-only; see tests/conformance/COVERAGE_STUDY.md. The one thing that
/// fails here is a run that scored zero files — a harness/checkout failure,
/// never a 0% result.</summary>
public static class EntryPoint
{
    private sealed record Pin(string Name, string Repo, string Ref, string? Lib);

    private sealed record PinFile(List<Pin> Packages);

    private static readonly JsonSerializerOptions PinOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    public static int Main(string[] args)
    {
        var pins = Arg(args, "pins");
        var checkouts = Arg(args, "checkouts");
        var package = Arg(args, "package");
        var sourceDir = Arg(args, "source-dir");
        var jsonOut = Arg(args, "json");

        var results = new List<FileResult>();
        var missingPins = new List<string>();

        if (pins is not null)
        {
            if (checkouts is null)
            {
                Console.Error.WriteLine("--pins requires --checkouts <dir>");
                return 2;
            }

            var parsed = JsonSerializer.Deserialize<PinFile>(File.ReadAllText(pins), PinOptions)
                ?? throw new InvalidOperationException($"could not read pin list {pins}");
            foreach (var pin in parsed.Packages)
            {
                var directory = Path.Combine(checkouts, pin.Name, pin.Lib ?? "src");
                if (!Directory.Exists(directory))
                {
                    // An unreachable pin is NOT an encoder regression — report it
                    // as a distinct outcome instead of scoring it as a failure.
                    missingPins.Add(pin.Name);
                    continue;
                }

                results.AddRange(TierA.StudyDirectory(pin.Name, directory));
            }
        }
        else if (package is not null && sourceDir is not null)
        {
            if (!Directory.Exists(sourceDir))
            {
                Console.Error.WriteLine($"--source-dir does not exist: {sourceDir}");
                return 2;
            }

            results.AddRange(TierA.StudyDirectory(package, sourceDir));
        }
        else
        {
            Console.Error.WriteLine(
                "Usage: Ball.CoverageStudy --pins <file> --checkouts <dir> [--json <out>]\n" +
                "       Ball.CoverageStudy --package <name> --source-dir <dir> [--json <out>]");
            return 2;
        }

        if (jsonOut is not null)
        {
            File.WriteAllText(jsonOut, JsonSerializer.Serialize(
                new { missingPins, files = results },
                new JsonSerializerOptions { WriteIndented = true }) + "\n");
        }

        var report = new StringBuilder();
        var exitCode = Report(report, results, missingPins);
        Console.Out.Write(report.ToString());
        return exitCode;
    }

    /// <summary>Prints the same summary shape as every other Tier A harness.</summary>
    public static int Report(StringBuilder output, List<FileResult> results, List<string> missingPins)
    {
        var scored = results.Where(r => r.Scored).ToList();
        var total = scored.Count;
        var clean = scored.Count(r => r.Clean);
        var irStable = scored.Count(r => r.IrStable);

        var byReason = scored
            .GroupBy(r => r.Reason.Split(':', 2)[0], StringComparer.Ordinal)
            .OrderByDescending(g => g.Count())
            .ThenBy(g => g.Key, StringComparer.Ordinal);
        foreach (var group in byReason)
        {
            output.Append($"  {group.Key}: {group.Count()}\n");
        }

        var skipped = results.Count - total;
        if (skipped > 0)
        {
            output.Append($"  skipped (no declarations, not scored): {skipped}\n");
        }

        if (missingPins.Count > 0)
        {
            output.Append($"  unreachable pins (not scored): {string.Join(", ", missingPins)}\n");
        }

        if (total > 0)
        {
            output.Append("Funnel (scored files that survived each stage):\n");
            foreach (var (threshold, label) in TierA.Stages)
            {
                var reached = scored.Count(r => TierA.StageReached(r.Reason) >= threshold);
                output.Append($"  {label}: {reached}/{total}\n");
            }
        }

        var pct = total == 0 ? 0 : (int)Math.Round(clean * 100.0 / total, MidpointRounding.AwayFromZero);
        output.Append($"Tier A: {clean}/{total} clean ({pct}%)\n");
        output.Append($"Tier A (IR fixpoint, informational): {irStable}/{total} stable\n");
        output.Append($"Results: {clean} passed, {total - clean} failed, {total} total\n");

        if (total < 1)
        {
            Console.Error.WriteLine("ERROR: Tier A scored 0 files — no package checkout was readable.");
            return 1;
        }

        return 0;
    }

    private static string? Arg(string[] args, string name)
    {
        var index = Array.IndexOf(args, $"--{name}");
        return index == -1 || index + 1 >= args.Length ? null : args[index + 1];
    }
}
