using System.Diagnostics;
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
                var result = RunOne(name, expected, dartExecutable, tempDir.FullName);
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

    private static FixtureResult RunOne(string name, IReadOnlyList<string> expected, string dartExecutable, string tempDir)
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

        RunResult dartResult;
        try
        {
            dartResult = RunDart(dartExecutable, ballJsonPath);
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

        var detail =
            $"expected ({expected.Count}): {(expected.Count == 0 ? "<none>" : expected[0])}\n" +
            $"actual   ({actual.Count}): {(actual.Count == 0 ? "<none>" : actual[0])}";
        return new FixtureResult(name, FixtureStatus.Fail, detail);
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

    private static readonly TimeSpan DartTimeout = TimeSpan.FromSeconds(30);

    private static RunResult RunDart(string dartExecutable, string ballJsonPath)
    {
        var scriptPath = Path.Combine(Fixtures.RepoRoot, "dart", "cli", "bin", "ball.dart");

        // On Windows, the `dart` on PATH is typically a `.bat` shim (the SDK's
        // real dart.exe lives a few directories deeper) — .NET's Process.Start
        // resolves a bare command via CreateProcess, which (unlike a shell)
        // does not apply PATHEXT to find a batch script, so launching "dart"
        // directly throws Win32Exception "cannot find the file specified"
        // even though `dart` resolves fine in an interactive/CI shell. Route
        // through `cmd.exe /c` on Windows only; every other platform (CI runs
        // ubuntu-latest per the conformance-matrix precedent) invokes the
        // executable directly.
        ProcessStartInfo psi;
        if (OperatingSystem.IsWindows())
        {
            psi = new ProcessStartInfo("cmd.exe")
            {
                WorkingDirectory = Fixtures.RepoRoot,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            psi.ArgumentList.Add("/c");
            psi.ArgumentList.Add(dartExecutable);
            psi.ArgumentList.Add("run");
            psi.ArgumentList.Add(scriptPath);
            psi.ArgumentList.Add("run");
            psi.ArgumentList.Add(ballJsonPath);
        }
        else
        {
            psi = new ProcessStartInfo(dartExecutable)
            {
                WorkingDirectory = Fixtures.RepoRoot,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            psi.ArgumentList.Add("run");
            psi.ArgumentList.Add(scriptPath);
            psi.ArgumentList.Add("run");
            psi.ArgumentList.Add(ballJsonPath);
        }

        using var process = Process.Start(psi) ?? throw new InvalidOperationException($"failed to start '{dartExecutable}'");
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        var exited = process.WaitForExit((int)DartTimeout.TotalMilliseconds);
        if (!exited)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Already exited between the timeout check and Kill.
            }

            return new RunResult(string.Empty, string.Empty, -1, TimedOut: true);
        }

        return new RunResult(stdoutTask.GetAwaiter().GetResult(), stderrTask.GetAwaiter().GetResult(), process.ExitCode, TimedOut: false);
    }

    private static string Head(string s) => s.Length <= 200 ? s : s[..200] + "…";

    private sealed record RunResult(string Stdout, string Stderr, int ExitCode, bool TimedOut);
}
