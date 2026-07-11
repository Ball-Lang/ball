using System.Reflection;

namespace Ball.Cli.Commands;

/// <summary>
/// <c>ball version</c> — print the CLI's version (issue #385, epic #361 cli-core adoption
/// pattern).
///
/// <para><b>Version policy</b> (mirrors <c>rust/cli/src/commands/version.rs</c>'s issue #366
/// policy): <c>ball version</c> reports the ECOSYSTEM package version — the NuGet
/// <c>Ball.Cli</c> version (issue #369 ships this binary to nuget.org), single-sourced from
/// <c>&lt;Version&gt;</c> in <c>csharp/cli/Ball.Cli.csproj</c> (via the compiler-emitted
/// <see cref="AssemblyInformationalVersionAttribute"/>) — the deliberate cross-target decision:
/// each CLI stays true to its own registry (crates.io for Rust, npm for TypeScript, pub.dev for
/// Dart, NuGet for C#) rather than carrying a shared toolchain string.</para>
///
/// <para>Unlike <c>info</c>/<c>validate</c>/<c>tree</c>, this subcommand is <b>not</b> gated
/// behind the <c>CliCore</c> MSBuild property: <c>cli_core.versionLine</c>'s entire logic is
/// <c>"ball " + version</c> (see <c>dart/shared/lib/cli_core.dart</c>), a Program-free, one-line
/// format. Duplicating that single line here keeps <c>ball version</c> working in every build,
/// while still calling the <i>actual</i> compiled <c>versionLine</c> when <c>CliCore</c> is built
/// in.</para>
/// </summary>
public static class VersionCommand
{
    /// <summary>
    /// The CLI's own package version — <see cref="AssemblyInformationalVersionAttribute"/> mirrors
    /// the csproj's <c>&lt;Version&gt;</c> exactly (unlike the normalized 4-part
    /// <see cref="AssemblyName.Version"/>).
    /// </summary>
    private static readonly string PackageVersion =
        typeof(VersionCommand).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion
        ?? "0.0.0";

    /// <summary>Print the version line (<c>"ball &lt;version&gt;"</c>) to stdout.</summary>
    public static void Run() => Console.WriteLine(VersionLine());

    private static string VersionLine()
    {
#if CLI_CORE
        return BallProgram.versionLine(Ball.Shared.BallValue.Str(PackageVersion)).ToString() ?? string.Empty;
#else
        return $"ball {PackageVersion}";
#endif
    }
}
