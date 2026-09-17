using System.Net.Http.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace UCASSignIn.Core;

public sealed record AppRelease(Version Version, string Tag, Uri Url);

public sealed class GitHubReleaseChecker
{
    public static readonly Uri LatestReleaseApi = new("https://api.github.com/repos/WXRIW/UCAS-Sign-In/releases/latest");
    static readonly Regex VersionTag = new(@"^v?(?<version>(?:0|[1-9]\d*)\.\d+\.\d+)$", RegexOptions.CultureInvariant);
    static readonly HttpClient DefaultClient = new() { Timeout = TimeSpan.FromSeconds(5) };
    readonly HttpClient client;

    public GitHubReleaseChecker(HttpClient? client = null)
    {
        this.client = client ?? DefaultClient;
    }

    public async Task<AppRelease?> CheckAsync(string currentVersion, CancellationToken cancellationToken = default)
    {
        var installed = ParseVersion(currentVersion)
            ?? throw new InvalidOperationException("无法识别当前应用版本。");
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestReleaseApi);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.UserAgent.ParseAdd("UCAS-Sign-In-Update-Checker");
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        using var response = await client.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        var payload = await response.Content.ReadFromJsonAsync<ReleasePayload>(cancellationToken: cancellationToken)
            ?? throw new InvalidOperationException("GitHub 返回了空的版本信息。");
        var latest = ParseVersion(payload.TagName)
            ?? throw new InvalidOperationException("GitHub Release 标签不是有效的版本号。");
        if (!Uri.TryCreate(payload.HtmlUrl, UriKind.Absolute, out var url)
            || url.Scheme != Uri.UriSchemeHttps
            || !url.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
            || !url.AbsolutePath.StartsWith("/WXRIW/UCAS-Sign-In/", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("GitHub Release 链接无效。");
        return latest > installed ? new AppRelease(latest, $"v{latest}", url) : null;
    }

    public static Version? ParseVersion(string? value)
    {
        var match = VersionTag.Match(value?.Trim() ?? "");
        return match.Success && Version.TryParse(match.Groups["version"].Value, out var version) ? version : null;
    }

    sealed record ReleasePayload(
        [property: JsonPropertyName("tag_name")] string? TagName,
        [property: JsonPropertyName("html_url")] string? HtmlUrl);
}
