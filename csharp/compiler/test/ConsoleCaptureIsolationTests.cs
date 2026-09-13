using System.Threading;
using System.Threading.Tasks;

namespace Ball.Compiler.Tests;

/// <summary>
/// The isolation guard for <see cref="CSharpRunner"/>'s stdout capture — issue #611.
///
/// <para><b>What went wrong.</b> <c>CSharpRunner.Run</c> captured a compiled program's
/// stdout by swapping <c>Console.Out</c>, which is PROCESS-GLOBAL: for the duration of one
/// test's <c>Invoke</c>, <em>every</em> write anywhere in the process landed in that test's
/// <see cref="StringWriter"/>. A <c>lock</c> around the redirect only serialises the tests
/// that take it; it cannot restrain a writer that never asks for it. In
/// <c>Ball.Encoder.Tests</c> there is exactly such a writer —
/// <c>RealWorldSweepTests.RealWorldSweep_ReportsHonestBaseline</c> ends with a bare
/// <c>Console.Write(report)</c> — and xUnit v3 runs test classes in parallel by default
/// (<see href="https://xunit.net/docs/running-tests-in-parallel"/>: each class is its own
/// collection and collections run concurrently, with no <c>xunit.runner.json</c> or
/// assembly-level attribute in this repo turning that off). So the sweep's
/// <c>Results: 9 passed, 2 failed, 11 total…</c> line could be swallowed by whichever
/// capture happened to be open, and <c>BucketIFixtureEncodesCompilesAndRuns</c> read it
/// instead of its own <c>BALL\n</c> (CI run 34732470492).
/// </para>
///
/// <para><b>What these tests pin.</b> (1) A foreign, uncaptured write made from an
/// unrelated execution context while a program is running must NOT appear in that
/// program's captured output. (2) Two programs capturing at the same time must each see
/// only their own output — and must genuinely overlap, which also fails if the capture is
/// ever re-serialised behind a global lock.</para>
/// </summary>
public class ConsoleCaptureIsolationTests
{
    /// <summary>Bounded, non-flaky handshake: poll for a marker file rather than sleeping a
    /// fixed amount, and surface a timeout as a real failure instead of a silent pass.</summary>
    private const int HandshakeTimeoutMs = 30_000;

    private static bool WaitForFile(string path)
    {
        var deadline = Environment.TickCount64 + HandshakeTimeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            if (File.Exists(path))
            {
                return true;
            }

            Thread.Sleep(5);
        }

        return false;
    }

    /// <summary>A program that announces it is running, waits (bounded) for
    /// <paramref name="awaitPath"/> to appear, then prints <paramref name="tag"/>.</summary>
    private static string HandshakeProgram(string tag, string announcePath, string awaitPath) => $$""""
        using System;

        class Program
        {
            static void Main()
            {
                System.IO.File.WriteAllText(@"{{announcePath}}", "1");
                var deadline = Environment.TickCount64 + {{HandshakeTimeoutMs}};
                while (!System.IO.File.Exists(@"{{awaitPath}}") && Environment.TickCount64 < deadline)
                {
                    System.Threading.Thread.Sleep(5);
                }

                if (System.IO.File.Exists(@"{{awaitPath}}"))
                {
                    System.IO.File.WriteAllText(@"{{announcePath}}.saw", "1");
                }

                Console.WriteLine("{{tag}}");
            }
        }
        """";

    /// <summary>
    /// The #611 repro, deterministic: a write issued straight to <c>Console</c> from an
    /// unrelated execution context, timed (by file handshake, not by sleeping) to land
    /// exactly while a compiled program is mid-run, must not be captured as that program's
    /// output. <c>FOREIGN-SWEEP-LINE</c> stands in for <c>RealWorldSweepTests</c>' summary.
    /// </summary>
    [Fact]
    public async Task AForeignConsoleWriteDuringARunIsNotCapturedAsTheProgramsOutput()
    {
        var dir = Directory.CreateTempSubdirectory("ball-capture-guard-");
        try
        {
            var running = Path.Combine(dir.FullName, "running");
            var foreignDone = Path.Combine(dir.FullName, "foreign-done");
            var source = HandshakeProgram("MINE", running, foreignDone);

            var foreignReachedTheWrite = false;

            // Read before SuppressFlow — inside it there is no ambient TestContext.
            var token = TestContext.Current.CancellationToken;

            // SuppressFlow models the real collision faithfully: the sweep test runs on its
            // own xUnit-scheduled context, having inherited nothing from this test.
            Task foreign;
            using (ExecutionContext.SuppressFlow())
            {
                foreign = Task.Run(
                    () =>
                {
                    if (!WaitForFile(running))
                    {
                        return;
                    }

                    Console.Write("FOREIGN-SWEEP-LINE\n");
                    foreignReachedTheWrite = true;
                    File.WriteAllText(foreignDone, "1");
                },
                    token);
            }

            var captured = CSharpRunner.Run(source);
            Assert.Same(foreign, await Task.WhenAny(foreign, Delay(HandshakeTimeoutMs)));

            // Positive floor: the foreign write must actually have happened, inside the
            // capture window (the program only prints once it has observed foreignDone).
            // Without this the assertion below could pass by the race never occurring.
            Assert.True(foreignReachedTheWrite, "the foreign console write never ran");
            Assert.True(File.Exists(running + ".saw"), "the program did not observe the foreign write's completion");

            Assert.Equal("MINE\n", captured);
        }
        finally
        {
            TryDelete(dir);
        }
    }

    /// <summary>
    /// Two captures open at once, each seeing only its own program. The <c>.saw</c> markers
    /// are the positive floor: they prove the two runs genuinely overlapped, so this also
    /// fails if the capture is ever put back behind a process-wide lock that serialises them.
    /// </summary>
    [Fact]
    public async Task TwoConcurrentRunsEachCaptureOnlyTheirOwnOutput()
    {
        var dir = Directory.CreateTempSubdirectory("ball-capture-pair-");
        try
        {
            var a = Path.Combine(dir.FullName, "a");
            var b = Path.Combine(dir.FullName, "b");

            var runA = Task.Run(() => CSharpRunner.Run(HandshakeProgram("A", a, b)));
            var runB = Task.Run(() => CSharpRunner.Run(HandshakeProgram("B", b, a)));
            var both = Task.WhenAll(runA, runB);
            Assert.Same(both, await Task.WhenAny(both, Delay(HandshakeTimeoutMs * 2)));

            Assert.True(
                File.Exists(a + ".saw") && File.Exists(b + ".saw"),
                "the two runs never overlapped — is the capture serialised behind a global lock again?");

            Assert.Equal("A\n", await runA);
            Assert.Equal("B\n", await runB);
        }
        finally
        {
            TryDelete(dir);
        }
    }

    /// <summary>Best-effort cleanup: a handshake that timed out can leave a program still
    /// polling the directory, and an <see cref="IOException"/> from the delete must never
    /// replace the real assertion failure that got us here.</summary>
    private static void TryDelete(DirectoryInfo dir)
    {
        try
        {
            dir.Delete(recursive: true);
        }
        catch (IOException)
        {
            // The temp directory is disposable; leaving it is better than masking a failure.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    /// <summary>A cancellable timeout arm for <see cref="Task.WhenAny(Task[])"/> — the
    /// non-blocking spelling of "fail rather than hang".</summary>
    private static Task Delay(int milliseconds) =>
        Task.Delay(milliseconds, TestContext.Current.CancellationToken);
}
