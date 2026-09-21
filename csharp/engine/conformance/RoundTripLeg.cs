using System.Text.Json.Nodes;
using Ball.Compiler;
using Ball.Encoder;
using Google.Protobuf;

namespace Ball.Engine.Conformance;

/// <summary>
/// The round-trip leg (issue #384 acceptance item 2): compile each fixture
/// Ball → C# (<see cref="CSharpCompiler"/>), re-encode that C# source back
/// into a Ball program via the Roslyn encoder (<see cref="CSharpEncoder"/>),
/// then run the RE-ENCODED program on the Dart reference engine (ground
/// truth — not the C# self-hosted engine, which would only prove the C#
/// pipeline agrees with itself) and diff against the golden.
///
/// <para>This is the hardest leg by construction: the Phase-4 compiler emits
/// a single flat class dispatching through <c>BallRuntime.*</c> calls and
/// <c>BallValue</c> types — not the idiomatic, hand-written C# shapes the
/// Phase-5 syntactic encoder's heuristics target (see
/// <c>csharp/AGENTS.md</c>'s "Encoder" section, "Documented gaps"). A fixture
/// failing here is expected and reported honestly, per issue #384's
/// acceptance bar ("even if not yet at parity — honest counts") — this leg's
/// purpose is a regression guard + a measured baseline, not a parity gate.</para>
/// </summary>
internal static class RoundTripLeg
{
    private static readonly JsonFormatter JsonFormat = new(JsonFormatter.Settings.Default);

    public static int Run(string? onlyFixture, string dartExecutable)
    {
        var names = Fixtures.AllNames();
        var results = new List<FixtureResult>();
        var skipped = 0;
        var tempDir = Directory.CreateTempSubdirectory("ball-csharp-roundtrip-");

        try
        {
            // Prepared ONCE for the whole sweep; every fixture below then costs a
            // single process spawn (issue #784).
            var dartCli = DartCli.Prepare(dartExecutable, tempDir.FullName);

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
                var result = RunOne(name, expected, dartCli, tempDir.FullName);
                results.Add(result);

                if (onlyFixture is not null)
                {
                    Console.WriteLine($"[{name}] {result.Status}" + (result.Detail is null ? "" : $"\n{result.Detail}"));
                }
            }
        }
        finally
        {
            try
            {
                tempDir.Delete(recursive: true);
            }
            catch (IOException)
            {
                // Best-effort cleanup; a leaked temp dir doesn't affect the result.
            }
        }

        return Summary.Print("Round-Trip (compile -> encode -> Dart engine)", results, skipped);
    }

    private static FixtureResult RunOne(string name, IReadOnlyList<string> expected, DartCli dartCli, string tempDir)
    {
        string csharpSource;
        try
        {
            var program = Fixtures.LoadProgram(Fixtures.JsonPath(name));
            csharpSource = CSharpCompiler.Compile(program);
        }
        catch (Exception ex)
        {
            return new FixtureResult(name, FixtureStatus.Error, $"compile: {ex.Message}");
        }

        V1.Program reencoded;
        try
        {
            reencoded = CSharpEncoder.Encode(csharpSource);
        }
        catch (Exception ex)
        {
            return new FixtureResult(name, FixtureStatus.Error, $"re-encode: {ex.Message}");
        }

        string ballJsonPath = Path.Combine(tempDir, $"{name}.ball.json");
        try
        {
            WriteBallJson(reencoded, ballJsonPath);
        }
        catch (Exception ex)
        {
            return new FixtureResult(name, FixtureStatus.Error, $"serialize: {ex.Message}");
        }

        DartRunResult dartResult;
        try
        {
            dartResult = dartCli.Run(ballJsonPath, DartCli.FixtureTimeout);
        }
        catch (Exception ex)
        {
            return new FixtureResult(name, FixtureStatus.Error, $"dart exec: {ex.Message}");
        }

        if (dartResult.TimedOut)
        {
            return new FixtureResult(name, FixtureStatus.Timeout);
        }

        if (dartResult.ExitCode != 0)
        {
            return new FixtureResult(name, FixtureStatus.Error, $"dart run exited {dartResult.ExitCode}: {Head(dartResult.Stderr)}");
        }

        var actual = Fixtures.SplitLines(dartResult.Stdout);
        if (actual.SequenceEqual(expected, StringComparer.Ordinal))
        {
            return new FixtureResult(name, FixtureStatus.Pass);
        }

        return new FixtureResult(name, FixtureStatus.Fail, Fixtures.DescribeMismatch(expected, actual));
    }

    /// <summary>
    /// Serialize a re-encoded <see cref="V1.Program"/> to a proto3-JSON
    /// <c>google.protobuf.Any</c> envelope (an explicit <c>@type</c> key
    /// alongside the message's own fields) — the same <c>.ball.json</c> shape
    /// <c>dart/shared/lib/ball_file.dart</c> reads, mirrored by
    /// <c>Fixtures.LoadProgram</c>'s loader above.
    /// </summary>
    private static void WriteBallJson(V1.Program program, string path)
    {
        var body = JsonFormat.Format(program);
        var envelope = JsonNode.Parse(body)!.AsObject();
        envelope["@type"] = "type.googleapis.com/ball.v1.Program";
        File.WriteAllText(path, envelope.ToJsonString());
    }

    private static string Head(string s) => s.Length <= 200 ? s : s[..200] + "…";
}
