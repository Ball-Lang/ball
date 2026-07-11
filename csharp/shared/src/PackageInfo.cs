namespace Ball.Shared;

/// <summary>
/// Assembly name marker — a Phase 1 (#378) scaffold artifact kept only as a stable
/// <c>PackageInfo.Name</c> constant other packages' own tests still assert against. The runtime
/// value model (<c>BallValue</c>/<c>BallList</c>/<c>BallMap</c>/<c>BallFunction</c>) and the
/// <c>BallRuntime</c> base-op helper layer landed in issue #380 — see those types (and
/// <c>csharp/AGENTS.md</c>), not this marker.
/// </summary>
public static class PackageInfo
{
    public const string Name = "Ball.Shared";
}
