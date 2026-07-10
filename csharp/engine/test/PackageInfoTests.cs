namespace Ball.Engine.Tests;

public class PackageInfoTests
{
    [Fact]
    public void Name_MatchesPackage()
    {
        Assert.Equal("Ball.Engine", PackageInfo.Name);
    }
}
