using System.CommandLine;
using Ball.Cli.Commands;

namespace Ball.Cli;

/// <summary>
/// <c>ball</c> — the Ball language CLI (C# toolchain, issue #385).
///
/// <para>Subcommands: <c>run</c>, <c>compile</c>, <c>encode</c>, <c>check</c>, plus the
/// self-hosted cli-core verbs <c>info</c>, <c>validate</c>, <c>tree</c>, <c>version</c> (epic
/// #361 pattern — compiled from <c>dart/shared/lib/cli_core.dart</c>, see
/// <c>csharp/AGENTS.md</c>), mirroring the Rust/Dart/TS CLIs' shape (<c>rust/cli/</c>, the
/// closest sibling — see <c>rust/cli/AGENTS.md</c> — plus <c>dart/cli/</c>, <c>ts/cli/</c>)
/// where it applies to the C# toolchain's current surface (no package-registry commands like
/// <c>dart/cli</c>'s <c>init</c>/<c>add</c>/<c>resolve</c>/<c>publish</c>, and no <c>audit</c> —
/// its capability/termination analyzers don't self-host through the encoder yet; see issue
/// #362).</para>
///
/// <para><b>Named <c>CliEntryPoint</c>, not <c>Program</c></b> — deliberately, so an unqualified
/// <c>Program</c> everywhere else in this assembly (<c>Serialize.cs</c>,
/// <c>Commands/CheckCommand.cs</c>, ...) unambiguously means <c>Ball.V1.Program</c> (the Ball
/// program model) via their own <c>using Ball.V1;</c>, instead of colliding with this type in
/// C#'s "current namespace beats <c>using</c> imports" name-resolution rule.</para>
///
/// <para>## Exit codes</para>
/// <list type="table">
/// <item><description><c>0</c> — success</description></item>
/// <item><description><c>1</c> — runtime error: a Ball program ran but failed (a <c>throw</c> that escaped <c>main</c>, or the engine itself reporting an error)</description></item>
/// <item><description><c>2</c> — invalid/unparseable program: bad <c>.ball.json</c>/<c>.ball.bin</c> shape, C# source <c>encode</c> couldn't turn into a program, a loaded program was too malformed to compile, or <c>ball validate</c> found the program invalid</description></item>
/// <item><description><c>3</c> — file-not-found / other I/O error reading input or writing <c>--output</c></description></item>
/// </list>
/// <para>See <see cref="CliError"/> for the exact exit-code mapping.</para>
/// </summary>
internal static class CliEntryPoint
{
    private static int Main(string[] args)
    {
        // Ball program output (`ball run`'s stdout, and cli-core report text) is UTF-8 by
        // definition (Dart's `String` and every other engine's output are). The default Windows
        // console output codepage is NOT UTF-8, so non-ASCII stdout gets mangled to `?` without
        // this — verified against the Unicode conformance fixtures (190/191/193/247/249/250/255)
        // before this fix. Guarded: setting it can throw when stdout has no underlying console
        // handle at all on some hosts (rare, but never fatal to the CLI itself).
        try
        {
            Console.OutputEncoding = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        }
        catch (IOException)
        {
            // No console handle to reconfigure (e.g. some CI/service hosts) — leave the
            // platform default in place rather than fail the whole CLI over cosmetics.
        }

        // `Console.Out`/`Console.Error`'s `NewLine` defaults to `Environment.NewLine` ("\r\n" on
        // Windows). Every other Ball target's CLI/engine always terminates a printed line with a
        // bare "\n" (Dart's `print`/`IOSink.writeln` never platform-adapt; see
        // `BallRuntime.Print`'s doc comment in `Ball.Shared`) — force the same here so `ball run`
        // output and cli-core report text stay byte-identical across OSes and match the
        // `tests/conformance/*.expected_output.txt` goldens on Windows too.
        Console.Out.NewLine = "\n";
        Console.Error.NewLine = "\n";

        var programArgument = new Argument<string>("program")
        {
            Description = "Path to the program: .ball.json (proto3 JSON) or .ball.bin (binary protobuf).",
        };

        var outputOption = new Option<string?>("--output", "-o")
        {
            Description = "Write the output here instead of stdout.",
        };

        var formatOption = new Option<EncodeFormat>("--format")
        {
            Description = "Output format for `encode`.",
            DefaultValueFactory = _ => EncodeFormat.Json,
        };

        var compileFlagOption = new Option<bool>("--compile")
        {
            Description = "Additionally attempt a dry-run compile to C# (output discarded) — a " +
                "stronger, C#-target-specific check.",
        };

        var runCommand = new Command("run", "Execute a Ball program and print its stdout.") { programArgument };
        runCommand.SetAction(result => Invoke(() => RunCommand.Run(result.GetValue(programArgument)!)));

        var compileCommand = new Command("compile", "Compile a Ball program to C# source.")
        {
            programArgument,
            outputOption,
        };
        compileCommand.SetAction(result => Invoke(() =>
            CompileCommand.Run(result.GetValue(programArgument)!, result.GetValue(outputOption))));

        var sourceArgument = new Argument<string>("source")
        {
            Description = "Path to the C# source file (.cs) to encode.",
        };
        var encodeCommand = new Command("encode", "Encode a C# source file into a Ball program.")
        {
            sourceArgument,
            outputOption,
            formatOption,
        };
        encodeCommand.SetAction(result => Invoke(() => EncodeCommand.Run(
            result.GetValue(sourceArgument)!,
            result.GetValue(outputOption),
            result.GetValue(formatOption))));

        var checkCommand = new Command("check", "Parse and validate a Ball program without running it.")
        {
            programArgument,
            compileFlagOption,
        };
        checkCommand.SetAction(result => Invoke(() =>
            CheckCommand.Run(result.GetValue(programArgument)!, result.GetValue(compileFlagOption))));

        var infoCommand = new Command("info", "Inspect a Ball program's structure (modules, functions, type defs).")
        {
            programArgument,
        };
        infoCommand.SetAction(result => Invoke(() => InfoCommand.Run(result.GetValue(programArgument)!)));

        var validateCommand = new Command(
            "validate", "Check a Ball program's validity (entry point, module/function shape).")
        {
            programArgument,
        };
        validateCommand.SetAction(result => Invoke(() => ValidateCommand.Run(result.GetValue(programArgument)!)));

        var treeCommand = new Command("tree", "Print a Ball program's module/import dependency tree.")
        {
            programArgument,
        };
        treeCommand.SetAction(result => Invoke(() => TreeCommand.Run(result.GetValue(programArgument)!)));

        var versionCommand = new Command("version", "Print the CLI's version.");
        versionCommand.SetAction(_ => Invoke(VersionCommand.Run));

        var rootCommand = new RootCommand(
            "Ball language CLI (C# toolchain): run/compile/encode/check/info/validate/tree/version.\n\n" +
            "NOTE on `run`: it drives the self-hosted engine, built in via the `SelfHost` MSBuild " +
            "property (off by default — see csharp/engine/Ball.Engine.csproj). Without that property " +
            "every program honestly reports a runtime error instead of silently doing nothing.\n\n" +
            "NOTE on `info`/`validate`/`tree`: they drive the self-hosted cli-core, built in via the " +
            "`CliCore` MSBuild property (off by default — see csharp/cli/Ball.Cli.csproj). Without " +
            "that property they honestly report a runtime error instead of silently doing nothing. " +
            "`version` always works regardless of this property.")
        {
            runCommand,
            compileCommand,
            encodeCommand,
            checkCommand,
            infoCommand,
            validateCommand,
            treeCommand,
            versionCommand,
        };

        return rootCommand.Parse(args).Invoke();
    }

    /// <summary>
    /// Run <paramref name="action"/>, mapping a thrown <see cref="CliError"/> to
    /// <c>ball: &lt;message&gt;</c> on stderr plus its exit code (issue #385's contract — see the
    /// type doc comment above). <c>0</c> (success) is simply the absence of a thrown
    /// <see cref="CliError"/>, never an explicit branch.
    /// </summary>
    private static int Invoke(Action action)
    {
        try
        {
            action();
            return 0;
        }
        catch (CliError e)
        {
            Console.Error.WriteLine($"ball: {e.Message}");
            return e.ExitCode;
        }
    }
}
