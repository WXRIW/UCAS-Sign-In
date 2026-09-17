using System.Net;
using System.Text;

namespace UCASSignIn.Core.Tests;

public class GitHubReleaseCheckerTests
{
    [Theory]
    [InlineData("1.2.3", "1.2.3")]
    [InlineData("v10.20.30", "10.20.30")]
    [InlineData("0.1.0", "0.1.0")]
    public void ParsesReleaseVersions(string input, string expected) =>
        Assert.Equal(Version.Parse(expected), GitHubReleaseChecker.ParseVersion(input));

    [Theory]
    [InlineData("1.2")]
    [InlineData("v1.2.3-beta")]
    [InlineData("01.2.3")]
    [InlineData("")]
    public void RejectsUnsupportedReleaseTags(string input) =>
        Assert.Null(GitHubReleaseChecker.ParseVersion(input));

    [Fact]
    public async Task ReturnsNewerPublishedRelease()
    {
        var checker = Checker("""{"tag_name":"v1.10.0","html_url":"https://github.com/WXRIW/UCAS-Sign-In/releases/tag/v1.10.0"}""");
        var release = await checker.CheckAsync("1.9.9");
        Assert.Equal(new Version(1, 10, 0), release?.Version);
        Assert.Equal("v1.10.0", release?.Tag);
    }

    [Theory]
    [InlineData("1.10.0")]
    [InlineData("2.0.0")]
    public async Task DoesNotOfferSameOrOlderRelease(string installed)
    {
        var checker = Checker("""{"tag_name":"v1.10.0","html_url":"https://github.com/WXRIW/UCAS-Sign-In/releases/tag/v1.10.0"}""");
        Assert.Null(await checker.CheckAsync(installed));
    }

    [Fact]
    public async Task RejectsReleaseUrlOutsideExpectedRepository()
    {
        var checker = Checker("""{"tag_name":"v2.0.0","html_url":"https://example.com/download"}""");
        await Assert.ThrowsAsync<InvalidOperationException>(() => checker.CheckAsync("1.0.0"));
    }

    static GitHubReleaseChecker Checker(string json) => new(new HttpClient(new StubHandler(json)));

    sealed class StubHandler(string json) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.Equal(GitHubReleaseChecker.LatestReleaseApi, request.RequestUri);
            Assert.Contains("UCAS-Sign-In-Update-Checker", request.Headers.UserAgent.ToString());
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json")
            });
        }
    }
}
