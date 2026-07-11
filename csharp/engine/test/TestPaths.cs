namespace Ball.Engine.Tests;

/// <summary>Locates repo-relative resources (fixtures/examples) for the engine test suite.</summary>
internal static class TestPaths
{
    /// <summary>
    /// Walk up from the test binary's directory to the repo root (the directory
    /// containing <c>proto/ball/v1/ball.proto</c>) — the same discovery the
    /// regen tool uses, so tests resolve committed fixtures regardless of the
    /// build output layout.
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
}
