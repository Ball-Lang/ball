namespace Ball.Cli;

/// <summary>
/// A CLI-level failure carrying its own process exit code (issue #385's exit-code contract):
/// <c>1</c> runtime error, <c>2</c> invalid/unparseable program, <c>3</c>
/// file-not-found/I/O error. <c>0</c> (success) is never represented here — it is simply the
/// absence of a thrown <see cref="CliError"/>.
///
/// <para>The C# analog of <c>rust/cli/src/error.rs</c>'s <c>CliError</c> enum, expressed as an
/// exception hierarchy (the idiomatic .NET shape) rather than a Rust-style tagged union:
/// <see cref="Program.Main"/> catches this at the top level, writes <c>ball: &lt;message&gt;</c>
/// to stderr, and returns <see cref="ExitCode"/> as the process exit code.</para>
/// </summary>
public abstract class CliError : Exception
{
    private protected CliError(string message)
        : base(message)
    {
    }

    /// <summary>The process exit code this failure maps to.</summary>
    public abstract int ExitCode { get; }
}

/// <summary>
/// File-not-found or another I/O failure reading input or writing <c>--output</c>. Exit code
/// <c>3</c>. Covers both "file not found" and general I/O failure — the issue's contract puts
/// both in one bucket.
/// </summary>
public sealed class CliIoError : CliError
{
    /// <summary>Create an I/O failure with the given message.</summary>
    public CliIoError(string message)
        : base(message)
    {
    }

    /// <inheritdoc/>
    public override int ExitCode => 3;
}

/// <summary>
/// The input was not a valid <c>ball.v1.Program</c> (bad JSON/binary shape, or — for
/// <c>encode</c> — source that could not be turned into one), or a loaded program was too
/// malformed to compile. Exit code <c>2</c>.
/// </summary>
public sealed class CliParseError : CliError
{
    /// <summary>Create a parse/encode/compile failure with the given message.</summary>
    public CliParseError(string message)
        : base(message)
    {
    }

    /// <inheritdoc/>
    public override int ExitCode => 2;
}

/// <summary>
/// A loaded program executed but failed at run time (a <c>throw</c> that escaped <c>main</c>,
/// the engine itself reporting a failure, or a cli-core verb needing a build the current binary
/// doesn't have — see <see cref="SelfHostPendingException"/>/the <c>CliCore</c>/<c>SelfHost</c>
/// MSBuild properties). Exit code <c>1</c>.
/// </summary>
public sealed class CliRuntimeError : CliError
{
    /// <summary>Create a runtime failure with the given message.</summary>
    public CliRuntimeError(string message)
        : base(message)
    {
    }

    /// <inheritdoc/>
    public override int ExitCode => 1;
}
