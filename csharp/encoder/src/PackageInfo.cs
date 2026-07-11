namespace Ball.Encoder;

/// <summary>
/// Phase 1 (#378) scaffold marker — kept only as a stable <c>PackageInfo.Name</c> constant. The
/// real C# -> Ball encoder (Roslyn AST walk, routed entirely through universal std per
/// .claude/skills/new-ball-language/SKILL.md Phase 3) landed in issue #382 — see
/// CSharpEncoder.Encode.
/// </summary>
public static class PackageInfo
{
    public const string Name = "Ball.Encoder";
}
