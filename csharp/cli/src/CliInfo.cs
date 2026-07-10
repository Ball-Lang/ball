namespace Ball.Cli;

/// <summary>
/// Phase 1 (#378) scaffold marker. Real subcommands (`run`/`compile`/
/// `encode`/`check`, per .claude/skills/new-ball-language/SKILL.md Phase 5)
/// land in issue #385. <see cref="Banner"/> exists to prove, at build and
/// test time, that this project's references to shared/compiler/encoder/
/// engine all resolve — the C# analog of the Rust Phase 1a workspace wiring.
/// </summary>
public static class CliInfo
{
    public const string Name = "Ball.Cli";

    public static string Banner => string.Join(
        ", ",
        Ball.Shared.PackageInfo.Name,
        Ball.Compiler.PackageInfo.Name,
        Ball.Encoder.PackageInfo.Name,
        Ball.Engine.PackageInfo.Name);
}
