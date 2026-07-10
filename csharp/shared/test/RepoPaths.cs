using System.Runtime.CompilerServices;

namespace Ball.Shared.Tests;

/// <summary>
/// Locates repo-root-relative canonical inventory files at test time. The test
/// assembly runs from <c>csharp/shared/test/bin/&lt;cfg&gt;/net10.0/</c>, so this
/// walks up from the build output until it finds the committed
/// <c>dart/shared/std.json</c> marker — no hardcoded absolute paths.
/// </summary>
public static class RepoPaths
{
    public static string RepoRoot { get; } = FindRepoRoot();

    private static string FindRepoRoot([CallerFilePath] string callerFilePath = "")
    {
        // Prefer the source location (stable across build configs); fall back to
        // the runtime base directory if the source tree is unavailable.
        foreach (var start in new[] { Path.GetDirectoryName(callerFilePath), AppContext.BaseDirectory })
        {
            var dir = start;
            while (!string.IsNullOrEmpty(dir))
            {
                if (File.Exists(Path.Combine(dir, "dart", "shared", "std.json")))
                {
                    return dir;
                }

                dir = Path.GetDirectoryName(dir);
            }
        }

        throw new InvalidOperationException("could not locate repo root (dart/shared/std.json marker not found)");
    }

    public static string StdJson => Path.Combine(RepoRoot, "dart", "shared", "std.json");

    public static string DartStdSource(string module) =>
        Path.Combine(RepoRoot, "dart", "shared", "lib", module + ".dart");
}
