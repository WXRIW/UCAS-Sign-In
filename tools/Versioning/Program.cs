using System.Text;
using System.Text.Json;

return VersioningTool.Run(args);

static class VersioningTool
{
    static readonly UTF8Encoding Utf8 = new(false);
    static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    public static int Run(string[] args)
    {
        try
        {
            var root = FindRepositoryRoot();
            var command = args.FirstOrDefault()?.ToLowerInvariant() ?? "show";
            return command switch
            {
                "show" => Show(root),
                "sync" => Sync(root, checkOnly: false),
                "check" => Sync(root, checkOnly: true),
                "set" => Set(root, args.Skip(1).ToArray()),
                "bump" => Bump(root, args.Skip(1).ToArray()),
                "--help" or "-h" or "help" => Help(),
                _ => throw new ArgumentException($"Unknown command: {command}")
            };
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"versioning: {exception.Message}");
            return 1;
        }
    }

    static int Help()
    {
        Console.WriteLine("Usage: dotnet run --project tools/Versioning -- <show|sync|check|set|bump>");
        Console.WriteLine("  show");
        Console.WriteLine("  sync");
        Console.WriteLine("  check");
        Console.WriteLine("  set VERSION [--build NUMBER]");
        Console.WriteLine("  bump <major|minor|patch|build>");
        return 0;
    }

    static int Show(string root)
    {
        var release = ReadVersion(root);
        Console.WriteLine($"{release.Version} (build {release.Build})");
        return 0;
    }

    static int Set(string root, string[] args)
    {
        if (args.Length is not (1 or 3) || args.Length == 3 && args[1] != "--build")
            throw new ArgumentException("Usage: set VERSION [--build NUMBER]");
        var current = ReadVersion(root);
        var build = args.Length == 3 ? ParseBuild(args[2]) : current.Build;
        var release = new ReleaseVersion(1, args[0], build);
        Validate(release);
        WriteVersion(root, release);
        return Sync(root, checkOnly: false);
    }

    static int Bump(string root, string[] args)
    {
        if (args.Length != 1)
            throw new ArgumentException("Usage: bump <major|minor|patch|build>");
        var current = ReadVersion(root);
        var version = Version.Parse(current.Version);
        var next = args[0].ToLowerInvariant() switch
        {
            "major" => new ReleaseVersion(1, $"{version.Major + 1}.0.0", current.Build + 1),
            "minor" => new ReleaseVersion(1, $"{version.Major}.{version.Minor + 1}.0", current.Build + 1),
            "patch" => new ReleaseVersion(1, $"{version.Major}.{version.Minor}.{version.Build + 1}", current.Build + 1),
            "build" => current with { Build = current.Build + 1 },
            _ => throw new ArgumentException("Bump kind must be major, minor, patch, or build.")
        };
        Validate(next);
        WriteVersion(root, next);
        return Sync(root, checkOnly: false);
    }

    static int Sync(string root, bool checkOnly)
    {
        var release = ReadVersion(root);
        var generated = new Dictionary<string, string>
        {
            [Path.Combine(root, "eng", "generated", "Version.props")] = RenderProps(release),
            [Path.Combine(root, "eng", "generated", "Version.xcconfig")] = RenderXcconfig(release),
            [Path.Combine(root, "apps", "windows", "UCASSignIn.Windows.Package", "Package.appxmanifest")] = RenderWindowsManifest(root, release)
        };
        var stale = new List<string>();
        foreach (var (path, content) in generated)
        {
            if (File.Exists(path) && File.ReadAllText(path, Utf8) == content)
                continue;
            var relative = Path.GetRelativePath(root, path).Replace('\\', '/');
            if (checkOnly)
            {
                stale.Add(relative);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, content, Utf8);
            Console.WriteLine($"generated {relative}");
        }
        if (stale.Count == 0)
        {
            Console.WriteLine($"version {release.Version} (build {release.Build}) is synchronized");
            return 0;
        }
        throw new InvalidOperationException($"generated version files are stale: {string.Join(", ", stale)}; run the sync command");
    }

    static ReleaseVersion ReadVersion(string root)
    {
        var path = Path.Combine(root, "eng", "version.json");
        var release = JsonSerializer.Deserialize<ReleaseVersion>(File.ReadAllText(path, Utf8), JsonOptions)
            ?? throw new InvalidOperationException("eng/version.json is empty.");
        Validate(release);
        return release;
    }

    static void WriteVersion(string root, ReleaseVersion release)
    {
        var path = Path.Combine(root, "eng", "version.json");
        File.WriteAllText(path, JsonSerializer.Serialize(release, JsonOptions) + "\n", Utf8);
        Console.WriteLine($"updated eng/version.json to {release.Version} (build {release.Build})");
    }

    static void Validate(ReleaseVersion release)
    {
        if (release.SchemaVersion != 1)
            throw new InvalidOperationException($"Unsupported version schema: {release.SchemaVersion}.");
        var fields = release.Version.Split('.');
        if (fields.Length != 3 || fields.Any(field => !ushort.TryParse(field, out _)) || !ushort.TryParse(fields[0], out var major) || major == 0)
            throw new InvalidOperationException("version must contain three numeric components, with a non-zero major version and values no greater than 65535.");
        if (release.Build is < 1 or > ushort.MaxValue)
            throw new InvalidOperationException("build must be between 1 and 65535.");
    }

    static int ParseBuild(string value) =>
        int.TryParse(value, out var build) ? build : throw new ArgumentException("build must be an integer.");

    static string RenderProps(ReleaseVersion release) => $$"""
        <!-- Generated from eng/version.json. Do not edit manually. -->
        <Project>
          <PropertyGroup>
            <Version>{{release.Version}}</Version>
            <VersionPrefix>{{release.Version}}</VersionPrefix>
            <InformationalVersion>{{release.Version}}</InformationalVersion>
            <AssemblyVersion>{{release.Version}}.0</AssemblyVersion>
            <FileVersion>{{release.Version}}.{{release.Build}}</FileVersion>
            <ApplicationDisplayVersion>{{release.Version}}</ApplicationDisplayVersion>
            <ApplicationVersion>{{release.Build}}</ApplicationVersion>
          </PropertyGroup>
        </Project>
        """ + "\n";

    static string RenderXcconfig(ReleaseVersion release) => $$"""
        // Generated from eng/version.json. Do not edit manually.
        MARKETING_VERSION = {{release.Version}}
        CURRENT_PROJECT_VERSION = {{release.Build}}
        """ + "\n";

    static string RenderWindowsManifest(string root, ReleaseVersion release)
    {
        var path = Path.Combine(root, "apps", "windows", "UCASSignIn.Windows.Package", "Package.appxmanifest.in");
        var template = File.ReadAllText(path, Utf8).Replace("\r\n", "\n");
        const string token = "@WINDOWS_PACKAGE_VERSION@";
        if (template.Split(token).Length != 2)
            throw new InvalidOperationException("Package.appxmanifest.in must contain exactly one Windows package version token.");
        return template.Replace(token, $"{release.Version}.0");
    }

    static string FindRepositoryRoot()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            for (var directory = new DirectoryInfo(start); directory is not null; directory = directory.Parent)
            {
                if (File.Exists(Path.Combine(directory.FullName, "eng", "version.json")))
                    return directory.FullName;
            }
        }
        throw new DirectoryNotFoundException("Could not locate the repository root containing eng/version.json.");
    }
}

sealed record ReleaseVersion(int SchemaVersion, string Version, int Build);
