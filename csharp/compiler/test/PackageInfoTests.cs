namespace Ball.Compiler.Tests;

public class PackageInfoTests
{
    [Fact]
    public void Name_MatchesPackage()
    {
        Assert.Equal("Ball.Compiler", PackageInfo.Name);
    }
}
