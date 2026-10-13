using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace UCASSignIn.Core.Tests;

public sealed class AutoSignStoreTests
{
    static AutoSignExecution Preview(string key) => AutoSignExecution.New(key, TestData.Now) with
    {
        Events = [new(TestData.Now, AutoSignStage.Planned, "计划已生成"),
            new(TestData.Now, AutoSignStage.Planned, "计划已更新：09-16 08:25；账户默认")]
    };

    [Fact]
    public void CleanupRemovesOnlyUnambiguousPreviewAndKeepsProtectiveEvidence()
    {
        var preview = Preview("preview");
        var manual = AutoSignExecution.New("manual", TestData.Now)
            .Transition(AutoSignStage.Skipped, TestData.Now, "用户已手动接管");
        var submitted = preview with { Key = "submitted", Submissions = 1, LastSubmissionAt = TestData.Now };
        var verified = preview with { Key = "verified", FirstNegativeAt = TestData.Now, NegativeReads = 1 };
        var missed = preview with { Key = "missed", Stage = AutoSignStage.Missed };
        var uncertain = preview with { Key = "uncertain", Events = [new(TestData.Now, AutoSignStage.Planned, "旧版未知状态")] };
        var empty = AutoSignExecution.New("empty", TestData.Now);
        var executions = new[] { preview, manual, submitted, verified, missed, uncertain, empty }.ToDictionary(x => x.Key);
        var cleaned = new AutoSignLedger(1, "a", executions).Cleaned();
        Assert.Equal(2, cleaned.Version);
        Assert.False(cleaned.Executions.ContainsKey("preview"));
        Assert.Equal(6, cleaned.Executions.Count);
        Assert.False(manual.HasExecutionActivity);
        Assert.False(empty.HasExecutionActivity);
        Assert.All(new[] { submitted, verified, missed, uncertain }, x => Assert.True(x.HasExecutionActivity));
    }

    [Fact]
    public async Task LegacyFileMigratesAtomicallyAndSecondReadDoesNotRewrite()
    {
        var root = Path.Combine(Path.GetTempPath(), "ucas-auto-store-" + Guid.NewGuid());
        var path = Path.Combine(root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("a"))), "auto-sign.json");
        try
        {
            var manual = AutoSignExecution.New("manual", TestData.Now)
                .Transition(AutoSignStage.Skipped, TestData.Now, "用户已手动接管");
            var real = AutoSignExecution.New("real", TestData.Now).Begin(TestData.Course(), TestData.Now)
                .Transition(AutoSignStage.Missed, TestData.Now, "已错过自动执行时间");
            AtomicFile.WriteJson(path, new AutoSignLedger(1, "a", new() { ["preview"] = Preview("preview"), ["manual"] = manual, ["real"] = real }));
            var store = new FileDataStore(root);
            var migrated = (await store.LoadAutoSignAsync("a"))!;
            Assert.Equal(2, migrated.Version);
            Assert.Equal(new[] { "manual", "real" }, migrated.Executions.Keys.Order().ToArray());
            Assert.Equal(2, JsonSerializer.Deserialize<AutoSignLedger>(File.ReadAllText(path))!.Version);
            var originalTime = File.GetLastWriteTimeUtc(path);
            _ = await store.LoadAutoSignAsync("a");
            Assert.Equal(originalTime, File.GetLastWriteTimeUtc(path));
            Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(path)!, "*.tmp"));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact]
    public async Task CorruptFileIsRejectedWithoutOverwritingIt()
    {
        var root = Path.Combine(Path.GetTempPath(), "ucas-auto-corrupt-" + Guid.NewGuid());
        var path = Path.Combine(root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("a"))), "auto-sign.json");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            const string damaged = "{broken ledger";
            File.WriteAllText(path, damaged);
            await Assert.ThrowsAsync<JsonException>(() => new FileDataStore(root).LoadAutoSignAsync("a"));
            Assert.Equal(damaged, File.ReadAllText(path));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact]
    public async Task MigrationWriteFailurePreservesOriginalFile()
    {
        if (OperatingSystem.IsWindows()) return; // The Unix permission failure is exercised on macOS/Linux.
        var root = Path.Combine(Path.GetTempPath(), "ucas-auto-readonly-" + Guid.NewGuid());
        var directory = Path.Combine(root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("a"))));
        var path = Path.Combine(directory, "auto-sign.json");
        var mode = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
        try
        {
            AtomicFile.WriteJson(path, new AutoSignLedger(1, "a", new() { ["preview"] = Preview("preview") }));
            var original = File.ReadAllBytes(path);
            mode = File.GetUnixFileMode(directory);
            File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserExecute);
            var failure = await Record.ExceptionAsync(() => new FileDataStore(root).LoadAutoSignAsync("a"));
            Assert.NotNull(failure);
            Assert.True(failure is IOException or UnauthorizedAccessException);
            Assert.Equal(original, File.ReadAllBytes(path));
        }
        finally
        {
            if (Directory.Exists(directory)) File.SetUnixFileMode(directory, mode);
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    public void CourseAliasMergePreservesRuleAndMostRecentEnableTime()
    {
        var a = new CoursePreferences(AutoSignRule: new(OffsetMinutes: -15), AutoSignEnabledSince: TestData.Now);
        var b = new CoursePreferences(AutoSignRule: new(RetryMinutes: 5), AutoSignEnabledSince: TestData.Now.AddMinutes(1));
        var merged = CourseIdentity.MergePreferences([a, b]);
        Assert.Equal(-15, merged.AutoSignRule?.OffsetMinutes);
        Assert.Equal(5, merged.AutoSignRule?.RetryMinutes);
        Assert.Equal(TestData.Now.AddMinutes(1), merged.AutoSignEnabledSince);
    }
}
