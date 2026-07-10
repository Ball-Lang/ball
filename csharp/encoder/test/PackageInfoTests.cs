namespace Ball.Encoder.Tests;

public class PackageInfoTests
{
    [Fact]
    public void Name_MatchesPackage()
    {
        Assert.Equal("Ball.Encoder", PackageInfo.Name);
    }
}
