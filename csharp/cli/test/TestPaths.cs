namespace Ball.Cli.Tests;

/// <summary>Locates repo-relative resources (fixtures/examples/goldens) for the cli test suite — mirrors <c>csharp/engine/test/TestPaths.cs</c>.</summary>
internal static class TestPaths
{
    /// <summary>
    /// Walk up from the test binary's directory to the repo root (the directory containing
    /// <c>proto/ball/v1/ball.proto</c>) — the same discovery the regen tools use, so tests
    /// resolve committed fixtures regardless of the build output layout.
    /// </summary>
    public static string RepoRoot()
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

        throw new InvalidOperationException("could not locate the ball repo root from the test binary directory");
    }

    /// <summary>Resolve a path relative to the repo root.</summary>
    public static string RepoPath(params string[] segments) =>
        Path.Combine([RepoRoot(), .. segments]);
}
