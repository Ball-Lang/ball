using System.ComponentModel;
using System.Diagnostics;
using Ball.Engine.Conformance;

namespace Ball.Engine.Tests;

/// <summary>
/// Guards how the round-trip leg LAUNCHES the Dart reference CLI (issue #784).
///
/// <para><b>The defect.</b> The leg used to spend one <c>dart run
/// dart/cli/bin/ball.dart run &lt;reencoded.ball.json&gt;</c> per fixture — on
/// Windows through <c>cmd.exe /c</c>, because .NET's <c>Process.Start</c>
/// resolves a bare command via <c>CreateProcess</c>, which does not apply
/// <c>PATHEXT</c> to find the SDK's <c>dart.bat</c> shim. <c>dart run</c> of a
/// package script pays kernel resolution + JIT front-end work on EVERY
/// invocation, and that cost is measured in seconds, not milliseconds: on the
/// Windows machine that filed #784 it was 20–31 s per fixture against the
/// harness's 30 s per-fixture cap, so ~14 fixtures that CI (ubuntu-latest,
/// where the same work is cheaper) counted as PASS were reported locally as
/// <c>TIMEOUT</c>. The arms under test are pure syntax→IR transforms with no
/// platform-dependent behaviour, so the divergence was entirely a harness
/// artifact — and it makes the locally-reported number useless as a proxy for
/// the gated CI number.</para>
///
/// <para><b>What is pinned.</b> Not a bigger timeout — a per-fixture launch
/// whose cost does not scale with the corpus. <see cref="DartCli.Prepare"/>
/// runs once per sweep and <see cref="DartCli.PlanFor"/> must then name an
/// already-built executable plus the fixture path and nothing else: no shell,
/// no interpreter, no <c>.dart</c> script. The timing test below states the
/// same property behaviourally and SELF-CALIBRATES — it compares against a warm
/// <c>dart run</c> measured on the machine running it, so it carries no
/// absolute millisecond constant that would rot across runners.</para>
///
/// <para><b>No skip.</b> Like <c>csharp/encoder/test/ReferenceEngineExecutionTests.cs</c>,
/// an unresolvable <c>dart</c> is a FAILURE here, never a skip — a gate that
/// quietly disappears on the machine lacking its dependency is the fake-green
/// this suite exists to prevent. <c>BALL_DART</c> overrides the executable.</para>
/// </summary>
public class DartCliLaunchTests
{
    /// <summary>
    /// The fixture #784 names in its single-fixture probe
    /// (<c>[206_integer_arithmetic_edge] Timeout</c>).
    /// </summary>
    private const string ProbeFixture = "206_integer_arithmetic_edge";

    /// <summary>
    /// How many prepared launches must together cost less than ONE warm
    /// <c>dart run</c> of the same program. Four is far below the corpus size
    /// (350+), so this is a weak statement of a strong property — and it is
    /// exactly the property a per-fixture <c>dart run</c> cannot have, at any
    /// speed, because there the two sides differ by a factor of four by
    /// construction.
    /// </summary>
    private const int PreparedLaunches = 4;

    /// <summary>
    /// The one-time <see cref="DartCli.Prepare"/> cost, expressed in warm
    /// <c>dart run</c>s. The sweep runs 350+ fixtures, so any budget well under
    /// that still leaves preparation a net win; 60 is generous enough not to be
    /// a flaky timing gate on a slow shared runner while still failing loudly if
    /// preparation ever grows into minutes.
    /// </summary>
    private const int PrepareAmortizationBudget = 60;

    [Fact]
    public void PreparedCli_LaunchesOneAlreadyBuiltExecutable_PerFixture()
    {
        var dart = RequireDart();
        var dir = Directory.CreateTempSubdirectory("ball-dartcli-plan-");
        try
        {
            var cli = DartCli.Prepare(dart, dir.FullName);
            var ballJsonPath = Path.Combine(dir.FullName, "program.ball.json");
            var plan = cli.PlanFor(ballJsonPath);

            Assert.False(
                plan.FileName.EndsWith("cmd.exe", StringComparison.OrdinalIgnoreCase),
                "the per-fixture launch must not go through a shell: `cmd.exe /c` is process " +
                "creation plus a command interpreter on top of whatever it launches, paid once " +
                "per fixture (issue #784).");

            Assert.DoesNotContain(
                plan.Arguments,
                a => a.EndsWith(".dart", StringComparison.OrdinalIgnoreCase));

            Assert.True(
                File.Exists(plan.FileName),
                $"the per-fixture launcher must be an executable prepared once for the whole " +
                $"sweep, not a name resolved (and a program re-compiled) per fixture; got " +
                $"'{plan.FileName}'.");

            Assert.Equal(new[] { "run", ballJsonPath }, plan.Arguments);
        }
        finally
        {
            Cleanup(dir);
        }
    }

    [Fact]
    public void PerFixtureCost_IsAmortized_NotAFreshDartStartupEachTime()
    {
        var dart = RequireDart();
        var fixturePath = Path.Combine(Fixtures.ConformanceDir, $"{ProbeFixture}.ball.json");
        Assert.True(File.Exists(fixturePath), $"missing conformance fixture: {fixturePath}");
        var golden = Fixtures.GoldenLines(ProbeFixture);

        // Baseline: ONE `dart run dart/cli/bin/ball.dart run <fixture>`, the shape
        // the leg used per fixture before #784. Measured WARM (a throwaway run
        // first) so the fix has to beat `dart run`'s best case, not its cold one.
        RunDartScript(dart, fixturePath);
        var baselineWatch = Stopwatch.StartNew();
        var baseline = RunDartScript(dart, fixturePath);
        baselineWatch.Stop();
        Assert.Equal(0, baseline.ExitCode);

        var dir = Directory.CreateTempSubdirectory("ball-dartcli-timing-");
        try
        {
            var prepareWatch = Stopwatch.StartNew();
            var cli = DartCli.Prepare(dart, dir.FullName);
            prepareWatch.Stop();

            var runWatch = Stopwatch.StartNew();
            for (var i = 0; i < PreparedLaunches; i++)
            {
                var result = cli.Run(fixturePath, DartCli.FixtureTimeout);
                Assert.False(result.TimedOut, $"run {i} hit the {DartCli.FixtureTimeout.TotalSeconds:0}s per-fixture cap");
                Assert.True(result.ExitCode == 0, $"run {i} exited {result.ExitCode}:\n{result.Stderr}");

                // Measuring a launch that produced nothing would prove nothing.
                Assert.Equal(golden, Fixtures.SplitLines(result.Stdout));
            }

            runWatch.Stop();

            Assert.True(
                runWatch.Elapsed < baselineWatch.Elapsed,
                $"{PreparedLaunches} prepared launches took {runWatch.Elapsed.TotalSeconds:0.00}s, " +
                $"more than a single warm `dart run` ({baselineWatch.Elapsed.TotalSeconds:0.00}s) — " +
                "so the per-fixture cost is still a fresh Dart startup and the sweep's wall time " +
                "still scales with the corpus (issue #784).");

            Assert.True(
                prepareWatch.Elapsed < baselineWatch.Elapsed * PrepareAmortizationBudget,
                $"preparing the reference CLI took {prepareWatch.Elapsed.TotalSeconds:0.00}s, over " +
                $"{PrepareAmortizationBudget} warm `dart run`s ({baselineWatch.Elapsed.TotalSeconds:0.00}s " +
                "each) — a one-time cost the 350+-fixture sweep can no longer amortize.");
        }
        finally
        {
            Cleanup(dir);
        }
    }

    /// <summary>
    /// The per-fixture <c>dart run &lt;script&gt;</c> invocation the leg used
    /// before #784 — kept here, and only here, as the BASELINE the fix is
    /// measured against.
    /// </summary>
    private static (int ExitCode, string Stderr) RunDartScript(string dart, string ballJsonPath)
    {
        var script = Path.Combine(Fixtures.RepoRoot, "dart", "cli", "bin", "ball.dart");
        using var process = Process.Start(Psi(dart, new[] { "run", script, "run", ballJsonPath }))
            ?? throw new InvalidOperationException($"failed to start '{dart}'");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        Assert.True(
            process.WaitForExit(120_000),
            "the baseline `dart run` did not finish within 120s");
        stdout.GetAwaiter().GetResult();
        return (process.ExitCode, stderr.GetAwaiter().GetResult());
    }

    /// <summary>The <c>dart</c> to drive. An unresolvable one is a hard failure — see the class remarks.</summary>
    private static string RequireDart()
    {
        var dart = Environment.GetEnvironmentVariable("BALL_DART");
        if (string.IsNullOrWhiteSpace(dart))
        {
            dart = "dart";
        }

        Assert.True(
            DartRuns(dart),
            $"the Dart reference CLI is not available (`{dart} --version` did not run). It is a " +
            "prerequisite of this suite, not an optional extra: install the Dart SDK and run " +
            "`dart pub get` at the repo root, or set BALL_DART to a specific executable.");

        return dart;
    }

    private static bool DartRuns(string dart)
    {
        try
        {
            using var probe = Process.Start(Psi(dart, new[] { "--version" }));
            if (probe is null)
            {
                return false;
            }

            probe.StandardOutput.ReadToEnd();
            probe.StandardError.ReadToEnd();
            return probe.WaitForExit(120_000) && probe.ExitCode == 0;
        }
        catch (Win32Exception)
        {
            return false;
        }
        catch (PlatformNotSupportedException)
        {
            return false;
        }
    }

    /// <summary>
    /// Launch <c>dart</c> itself. On Windows that still needs <c>cmd.exe /c</c>
    /// (the PATHEXT/.bat-shim reason spelled out in <see cref="DartCli"/>) — which
    /// is fine for a probe and for the baseline, and is exactly what must not
    /// happen once per fixture.
    /// </summary>
    private static ProcessStartInfo Psi(string dart, IReadOnlyList<string> arguments)
    {
        var windows = OperatingSystem.IsWindows();
        var psi = new ProcessStartInfo(windows ? "cmd.exe" : dart)
        {
            WorkingDirectory = Fixtures.RepoRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };

        if (windows)
        {
            psi.ArgumentList.Add("/c");
            psi.ArgumentList.Add(dart);
        }

        foreach (var argument in arguments)
        {
            psi.ArgumentList.Add(argument);
        }

        return psi;
    }

    private static void Cleanup(DirectoryInfo dir)
    {
        try
        {
            dir.Delete(recursive: true);
        }
        catch (IOException)
        {
            // Best-effort cleanup; a leaked temp dir does not affect the result.
        }
    }
}
