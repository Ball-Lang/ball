namespace Ball.Cli.Tests;

/// <summary>
/// Proves the cli project's references to all four sibling packages
/// (shared/compiler/encoder/engine) resolve at both compile and run time.
/// </summary>
public class CliInfoTests
{
    [Fact]
    public void Banner_ReferencesAllSiblingPackages()
    {
        Assert.Contains("Ball.Shared", CliInfo.Banner);
        Assert.Contains("Ball.Compiler", CliInfo.Banner);
        Assert.Contains("Ball.Encoder", CliInfo.Banner);
        Assert.Contains("Ball.Engine", CliInfo.Banner);
    }
}
