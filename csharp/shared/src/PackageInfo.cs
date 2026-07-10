namespace Ball.Shared;

/// <summary>
/// Assembly name marker, still referenced by the CLI's <c>CliInfo</c> to prove
/// the shared package resolves as a project reference. The runtime value model
/// (<c>BallValue</c>/<c>BallList</c>/<c>BallMap</c>/<c>BallFunction</c>) and the
/// <c>BallRuntime</c> base-op helper layer landed in issue #380 — see those
/// types (and <c>csharp/AGENTS.md</c>), not this marker.
/// </summary>
public static class PackageInfo
{
    public const string Name = "Ball.Shared";
}
