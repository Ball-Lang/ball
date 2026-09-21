using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Ball.Encoder;
using Google.Protobuf;

namespace Ball.Encoder.Tests;

/// <summary>
/// The executable half of the node-shaped <c>BallRuntime</c> arms' guard (issue #689): encode
/// compiler-shaped C#, write the re-encoded program out as <c>.ball.json</c>, and RUN it on the
/// <b>Dart reference engine</b> — the same ground truth the <c>csharp-roundtrip</c> matrix row
/// uses (<c>csharp/engine/conformance/RoundTripLeg.cs</c>), and the only instrument that can see
/// this class of defect.
///
/// <para><b>Why the reference engine and not the C# runtime.</b> The first cut of this encoder's
/// <c>ArgGet</c> arm encoded to <c>null_coalesce</c> over two <c>field_access</c> nodes. Every
/// other instrument was blind to it: <c>RuntimeNodeHelperTests</c> asserts the tree without
/// evaluating it, and evaluating that tree on the C# target cannot fail either, because
/// <c>BallRuntime.FieldGet</c> answers <c>BallValue.Null</c> for a missing map key
/// (<c>csharp/shared/src/BallRuntime.cs</c>). The reference engine does NOT: a
/// <c>field_access</c> on an absent key is <c>BallRuntimeError: Field "…" not found</c>
/// (<c>dart/engine/lib/engine_eval.dart</c>), and <c>std.null_coalesce</c> is eager, so BOTH
/// operands are evaluated whichever key won — while a real <c>ArgGet</c> input carries exactly
/// one of its two keys. The arm therefore threw on every real input, with every check green.</para>
///
/// <para><b>No skip.</b> These tests shell out to <c>dart</c> and an unresolvable <c>dart</c> is a
/// FAILURE, never a skip — a gate that quietly disappears on the machine that lacks its
/// dependency is exactly the fake-green this class exists to prevent. Dart is this repo's
/// reference implementation, so its SDK plus a resolved workspace (<c>dart pub get</c> at the
/// repo root) is a prerequisite for <c>dotnet test csharp/Ball.slnx</c>, and
/// <c>.github/workflows/ci.yml</c>'s <c>csharp</c> job sets Dart up BEFORE its <c>Test</c> step
/// for exactly this reason. <c>BALL_DART</c> overrides which executable is used.</para>
/// </summary>
public class ReferenceEngineExecutionTests
{
    /// <summary>
    /// The compiler's parameter prologue for a 2+-parameter callee, in both orders that matter:
    /// <c>FirstKeyPresent</c>'s input carries the FIRST key and not the second,
    /// <c>SecondKeyPresent</c>'s carries the second and not the first. Under the old
    /// two-<c>field_access</c> shape each one throws on the reference engine —
    /// <c>FirstKeyPresent</c> on its right operand, <c>SecondKeyPresent</c> on its left, because
    /// <c>std.null_coalesce</c> evaluates both — so this single program pins the defect from both
    /// sides.
    ///
    /// <para><b>Why the fallback key is not literally spelled <c>arg0</c> here.</b> The reference
    /// engine destructures a SINGLE-parameter function's input when the input map carries
    /// <c>arg0</c> and not the parameter's own name (<c>engine_invocation.dart</c>'s parameter
    /// binding) — so an <c>arg0</c>-keyed input never reaches the body as a whole map, and the
    /// callee would be reading a key off the bare argument VALUE. That is a property of
    /// re-encoded compiler output in general (the compiler's <c>__in</c> is the whole input
    /// message; the engine's one-parameter rule disagrees), independent of this arm and not
    /// something it can fix — it is one of the reasons the <c>csharp-roundtrip</c> row is a
    /// ratchet rather than a parity gate. This arm treats both keys identically (two string
    /// literals), so a non-<c>arg0</c> fallback key exercises the identical code path while
    /// keeping the map intact.</para>
    /// </summary>
    private const string ArgGetSource = """
        using System.Collections.Generic;
        using Ball.Shared;

        internal static class BallProgram
        {
            static BallValue FirstKeyPresent(BallValue __in)
            {
                return BallRuntime.ArgGet(__in, "lo", "missing");
            }

            static BallValue SecondKeyPresent(BallValue __in)
            {
                return BallRuntime.ArgGet(__in, "missing", "lo");
            }

            public static void Main(string[] args)
            {
                BallRuntime.Print(FirstKeyPresent(new Dictionary<string, int> { ["lo"] = 7 }));
                BallRuntime.Print(SecondKeyPresent(new Dictionary<string, int> { ["lo"] = 7 }));
            }
        }
        """;

    [Fact]
    public void ArgGetPrologueRunsOnTheReferenceEngine()
    {
        var output = EncodeAndRun(ArgGetSource);

        // 7 twice: the first key wins in the first callee, the fallback key in
        // the second. Not "an exception", and not an empty run.
        Assert.Equal(new[] { "7", "7" }, output);
    }

    /// <summary>
    /// The sibling arm: <c>BallRuntime.FieldGet(obj, "name")</c> IS the compiler's emission of a
    /// <c>field_access</c> node, so its inverse stays that node. This pins that the reference
    /// engine really does read the field the arm names — a positive result, not merely "it did
    /// not throw".
    /// </summary>
    [Fact]
    public void FieldGetRunsOnTheReferenceEngine()
    {
        var output = EncodeAndRun("""
            using System.Collections.Generic;
            using Ball.Shared;

            internal static class BallProgram
            {
                static BallValue ReadNamedKey(BallValue __in)
                {
                    return BallRuntime.FieldGet(__in, "lo");
                }

                public static void Main(string[] args)
                {
                    BallRuntime.Print(ReadNamedKey(new Dictionary<string, int> { ["lo"] = 41 }));
                }
            }
            """);

        Assert.Equal(new[] { "41" }, output);
    }

    /// <summary>
    /// The compiler's OBJECT MODEL, end to end (issue #689): a typed
    /// <c>new BallMessage(type, new BallMap { … })</c> instance, an instance-method call packed
    /// into an untyped <c>new BallMap { ["self"] = … }</c>, the <c>MessageTypeName</c> receiver
    /// probe the emitted dispatcher opens with, and a <c>FieldSet</c> WRITE that a later read
    /// must observe.
    ///
    /// <para>This source is <c>Ball.Compiler</c>'s own emission shape, trimmed — compiling
    /// <c>tests/conformance/101_simple_class.ball.json</c> produces exactly these constructs (a
    /// descriptor class per Ball type, one dispatcher per method name, <c>__t</c> compared
    /// against the full <c>module:Type</c> name and the short one). The assertion is a POSITIVE
    /// result on the Dart reference engine, not merely "it did not throw": <c>3!</c> proves the
    /// dispatcher resolved the receiver's type and read its field, and <c>9!</c> proves the
    /// field write landed on the SAME shared instance rather than on a copy.</para>
    ///
    /// <para>The dispatcher is what makes <c>MessageTypeName</c> → <c>std.type_of</c> testable at
    /// all: the probe's value is never printed, only compared, so only a run can show that the
    /// comparison the compiler emitted still selects the right arm.</para>
    /// </summary>
    private const string ObjectModelSource = """
        using Ball.Shared;
        using static Ball.Shared.BallValue;

        internal static class BallProgram
        {
            // Ball type main:Point — the compiler's descriptor shape.
            public sealed class Point
            {
                public BallValue? x { get; set; }
            }

            public static BallValue describe(BallValue input)
            {
                var __self = BallRuntime.FieldGet(input, "self");
                var __t = BallRuntime.MessageTypeName(__self);
                if (__t == "main:Point" || __t == "Point") return Point__describe(input);
                return BallRuntime.ToStringValue(__self);
            }

            private static BallValue Point__describe(BallValue __in0)
            {
                var self__L0 = BallRuntime.FieldGet(__in0, "self");
                return BallRuntime.Add(BallRuntime.ToStringValue(BallRuntime.FieldGet(self__L0, "x")), Str("!"));
            }

            public static void Main(string[] args)
            {
                var p__L1 = (BallValue)new BallMessage("main:Point", new BallMap { ["x"] = Int(3L) });
                BallRuntime.Print(describe((BallValue)new BallMap { ["self"] = p__L1 }));
                BallRuntime.FieldSet(p__L1, "x", Int(9L));
                BallRuntime.Print(describe((BallValue)new BallMap { ["self"] = p__L1 }));
            }
        }
        """;

    [Fact]
    public void CompilerObjectModelRunsOnTheReferenceEngine()
    {
        var output = EncodeAndRun(ObjectModelSource);

        Assert.Equal(new[] { "3!", "9!" }, output);
    }

    // ── harness ───────────────────────────────────────────────────────────

    private static readonly JsonFormatter JsonFormat = new(JsonFormatter.Settings.Default);

    private static readonly TimeSpan DartTimeout = TimeSpan.FromSeconds(180);

    /// <summary>Encode <paramref name="source"/>, write the program as <c>.ball.json</c>, run it
    /// on the Dart reference engine, and return its stdout lines. Fails with the engine's own
    /// stderr when the run is not a clean exit 0.</summary>
    private static IReadOnlyList<string> EncodeAndRun(string source)
    {
        var dart = RequireDart();
        var program = CSharpEncoder.Encode(source);

        var dir = Directory.CreateTempSubdirectory("ball-csharp-refengine-");
        try
        {
            var path = Path.Combine(dir.FullName, "program.ball.json");
            var envelope = JsonNode.Parse(JsonFormat.Format(program))!.AsObject();
            envelope["@type"] = "type.googleapis.com/ball.v1.Program";
            File.WriteAllText(path, envelope.ToJsonString());

            var (stdout, stderr, exitCode, timedOut) = RunDart(dart, path);
            Assert.False(timedOut, $"the reference engine did not finish within {DartTimeout.TotalSeconds:0}s");
            Assert.True(
                exitCode == 0,
                $"the re-encoded program failed on the Dart reference engine (exit {exitCode}):\n{stderr}");

            return stdout
                .Replace("\r\n", "\n", StringComparison.Ordinal)
                .Split('\n')
                .Where(l => l.Length > 0)
                .ToList();
        }
        finally
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

    /// <summary>The <c>dart</c> executable to drive. An unresolvable one is a hard failure — see
    /// the class remarks ("No skip").</summary>
    private static string RequireDart()
    {
        var dart = Environment.GetEnvironmentVariable("BALL_DART");
        if (string.IsNullOrWhiteSpace(dart))
        {
            dart = "dart";
        }

        Assert.True(
            DartRuns(dart),
            $"the Dart reference engine is not available (`{dart} --version` did not run). It is " +
            "a prerequisite of this suite, not an optional extra: install the Dart SDK and run " +
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

    private static (string Stdout, string Stderr, int ExitCode, bool TimedOut) RunDart(string dart, string ballJsonPath)
    {
        var script = Path.Combine(RepoRoot, "dart", "cli", "bin", "ball.dart");
        using var process = Process.Start(Psi(dart, new[] { "run", script, "run", ballJsonPath }))
            ?? throw new InvalidOperationException($"failed to start '{dart}'");

        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit((int)DartTimeout.TotalMilliseconds))
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Already exited between the timeout check and the Kill.
            }

            return (string.Empty, string.Empty, -1, true);
        }

        return (stdout.GetAwaiter().GetResult(), stderr.GetAwaiter().GetResult(), process.ExitCode, false);
    }

    /// <summary>
    /// On Windows the <c>dart</c> on PATH is a <c>.bat</c> shim, and .NET's
    /// <c>Process.Start</c> resolves a bare command through <c>CreateProcess</c>, which does not
    /// apply <c>PATHEXT</c> — so it must be launched through <c>cmd.exe /c</c> there. Same
    /// reasoning (and same shape) as <c>RoundTripLeg.RunDart</c>.
    /// </summary>
    private static ProcessStartInfo Psi(string dart, IReadOnlyList<string> arguments)
    {
        var windows = OperatingSystem.IsWindows();
        var psi = new ProcessStartInfo(windows ? "cmd.exe" : dart)
        {
            WorkingDirectory = RepoRoot,
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

    private static string RepoRoot { get; } = FindRepoRoot();

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

        throw new InvalidOperationException(
            "could not locate the ball repo root from the test binary directory");
    }
}
