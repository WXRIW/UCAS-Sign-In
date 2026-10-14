using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace UCASSignIn.Core;

public abstract class EncryptedAccountStore(string path) : IAccountStore
{
    readonly SemaphoreSlim gate = new(1);
    protected abstract byte[] Protect(byte[] plain);
    protected abstract byte[] Unprotect(byte[] cipher);
    public async Task<AccountVault> LoadAsync(CancellationToken ct = default)
    {
        await gate.WaitAsync(ct);
        try
        {
            return Read();
        }
        finally { gate.Release(); }
    }
    AccountVault Read()
    {
        if (!File.Exists(path))
            return AccountVault.Empty;
        var plain = Unprotect(File.ReadAllBytes(path));
        try
        {
            var vault = JsonSerializer.Deserialize<AccountVault>(plain) ?? throw new IOException("本机账户数据无法读取");
            vault.Validate();
            return vault;
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    public async Task SaveAsync(AccountVault vault, CancellationToken ct = default)
    {
        await gate.WaitAsync(ct);
        try
        {
            vault.Validate();
            _ = Read(); // Never overwrite corrupt or newer data.
            var plain = JsonSerializer.SerializeToUtf8Bytes(vault);
            try
            {
                AtomicFile.Write(path, Protect(plain));
            }
            finally { CryptographicOperations.ZeroMemory(plain); }
        }
        finally { gate.Release(); }
    }
}
public static class AtomicFile
{
    public static void Write(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temp, bytes);
            File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public static void WriteJson<T>(string path, T value) => Write(path, JsonSerializer.SerializeToUtf8Bytes(value));
    public static T? ReadJson<T>(string path) => File.Exists(path) ? JsonSerializer.Deserialize<T>(File.ReadAllBytes(path)) : default;
}
public sealed class FileDataStore(string root) : ICourseStore, IRecordStore, ICourseCatalogStore, IScheduleStore, IAttendanceStateStore, IAutoSignStore, IHistoryRetentionStore
{
    public Task<HistoryRetentionSettings> LoadHistoryRetentionAsync(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var path = Path.Combine(root, "history-retention.json");
        var settings = File.Exists(path)
            ? AtomicFile.ReadJson<HistoryRetentionSettings>(path) ?? throw new IOException("记录保留设置无法读取，原始数据已保留")
            : new HistoryRetentionSettings();
        settings.Validate();
        return Task.FromResult(settings);
    }
    public async Task SaveHistoryRetentionAsync(HistoryRetentionSettings settings, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        settings.Validate();
        _ = await LoadHistoryRetentionAsync(ct); // Never overwrite corrupt existing settings.
        ct.ThrowIfCancellationRequested();
        AtomicFile.WriteJson(Path.Combine(root, "history-retention.json"), settings);
    }
    static T? ReadCache<T>(string path)
    {
        try { return AtomicFile.ReadJson<T>(path); }
        catch (JsonException) { return default; } // Invalid cache is a miss; secure account data remains strict.
    }
    string AccountPath(string id) => Path.Combine(root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))));
    public Task<CourseCache?> LoadAsync(string accountId, string day, CancellationToken ct = default)
        => Task.FromResult(ReadCache<CourseCache>(Path.Combine(AccountPath(accountId), CourseTime.NormalizeDay(day) + ".json")));
    public Task SaveAsync(string accountId, string day, CourseCache cache, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        AtomicFile.WriteJson(Path.Combine(AccountPath(accountId), CourseTime.NormalizeDay(day) + ".json"), cache);
        return Task.CompletedTask;
    }
    Task<List<AttendanceRecord>> IRecordStore.LoadAsync(string accountId, CancellationToken ct)
        => Task.FromResult(AtomicFile.ReadJson<List<AttendanceRecord>>(Path.Combine(AccountPath(accountId), "records.json")) ?? []);
    public Task SaveAsync(string accountId, IReadOnlyList<AttendanceRecord> records, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        AtomicFile.WriteJson(Path.Combine(AccountPath(accountId), "records.json"), records);
        return Task.CompletedTask;
    }
    public Task RemoveAsync(string accountId, CancellationToken ct = default)
    {
        var path = AccountPath(accountId);
        if (Directory.Exists(path))
            Directory.Delete(path, true);
        return Task.CompletedTask;
    }
    string CatalogPath(string accountId, params string[] parts) => Path.Combine([AccountPath(accountId), "catalog", .. parts]);
    public Task<SemesterCache?> LoadSemestersAsync(string accountId, CancellationToken ct = default)
        => Task.FromResult(ReadCache<SemesterCache>(CatalogPath(accountId, "semesters.json")));
    public Task SaveSemestersAsync(string accountId, SemesterCache cache, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); AtomicFile.WriteJson(CatalogPath(accountId, "semesters.json"), cache); return Task.CompletedTask;
    }
    public Task<CourseCatalogCache?> LoadCatalogAsync(string accountId, string semesterId, CancellationToken ct = default)
        => Task.FromResult(ReadCache<CourseCatalogCache>(CatalogPath(accountId, "courses-" + Safe(semesterId) + ".json")));
    public Task SaveCatalogAsync(string accountId, string semesterId, CourseCatalogCache cache, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); AtomicFile.WriteJson(CatalogPath(accountId, "courses-" + Safe(semesterId) + ".json"), cache); return Task.CompletedTask;
    }
    public Task<CourseAttendanceCache?> LoadAttendanceAsync(string accountId, string semesterId, string courseId, CancellationToken ct = default)
        => Task.FromResult(ReadCache<CourseAttendanceCache>(CatalogPath(accountId, "attendance-" + Safe(semesterId) + "-" + Safe(courseId) + ".json")));
    public Task SaveAttendanceAsync(string accountId, string semesterId, string courseId, CourseAttendanceCache cache, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); AtomicFile.WriteJson(CatalogPath(accountId, "attendance-" + Safe(semesterId) + "-" + Safe(courseId) + ".json"), cache); return Task.CompletedTask;
    }
    public Task RemoveCatalogAsync(string accountId, CancellationToken ct = default)
    {
        var path = CatalogPath(accountId); if (Directory.Exists(path)) Directory.Delete(path, true); return Task.CompletedTask;
    }
    static string Safe(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    string SchedulePath(string id) => Path.Combine(AccountPath(id), "schedule");
    public Task<IReadOnlyList<ScheduleSnapshot>> LoadSchedulesAsync(string accountId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); var path = SchedulePath(accountId);
        IReadOnlyList<ScheduleSnapshot> result = Directory.Exists(path) ? Directory.EnumerateFiles(path, "semester-*.json")
            .Select(ReadCache<ScheduleSnapshot>).Where(x => x is not null && x.AccountId == accountId).Cast<ScheduleSnapshot>().ToArray() : [];
        return Task.FromResult(result);
    }
    public Task SaveScheduleAsync(ScheduleSnapshot snapshot, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        AtomicFile.WriteJson(Path.Combine(SchedulePath(snapshot.AccountId), "semester-" + Safe(snapshot.Semester.Id) + ".json"), snapshot);
        return Task.CompletedTask;
    }
    public Task<IReadOnlyList<string>> CachedDaysAsync(string accountId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); var path = AccountPath(accountId);
        IReadOnlyList<string> result = Directory.Exists(path) ? Directory.EnumerateFiles(path, "*.json")
            .Select(Path.GetFileNameWithoutExtension).Select(CourseTime.NormalizeDay).OfType<string>().Order().ToArray() : [];
        return Task.FromResult(result);
    }
    public Task<ScheduleRetryTargets?> LoadScheduleRetriesAsync(string accountId, CancellationToken ct = default)
        => Task.FromResult(ReadCache<ScheduleRetryTargets>(Path.Combine(SchedulePath(accountId), "retries.json")));
    public Task SaveScheduleRetriesAsync(string accountId, ScheduleRetryTargets targets, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); AtomicFile.WriteJson(Path.Combine(SchedulePath(accountId), "retries.json"), targets); return Task.CompletedTask;
    }
    public Task<AttendanceEvidenceCache?> LoadAttendanceStateAsync(string accountId, CancellationToken ct = default)
        => Task.FromResult(ReadCache<AttendanceEvidenceCache>(Path.Combine(AccountPath(accountId), "attendance-state.json")));
    public Task SaveAttendanceStateAsync(AttendanceEvidenceCache state, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        AtomicFile.WriteJson(Path.Combine(AccountPath(state.AccountId), "attendance-state.json"), state);
        return Task.CompletedTask;
    }

    public Task<AutoSignLedger?> LoadAutoSignAsync(string accountId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var path = Path.Combine(AccountPath(accountId), "auto-sign.json");
        if (!File.Exists(path)) return Task.FromResult<AutoSignLedger?>(null);
        // A damaged execution log must never be interpreted as a fresh, safe-to-submit state.
        var result = AtomicFile.ReadJson<AutoSignLedger>(path);
        if (result is null) throw new IOException("自动签到记录无法读取，已暂停自动提交");
        result.Validate(accountId);
        var cleaned = result.Cleaned();
        if (result.Version != AutoSignLedger.CurrentVersion || result.Executions.Count != cleaned.Executions.Count)
            AtomicFile.WriteJson(path, cleaned);
        return Task.FromResult<AutoSignLedger?>(cleaned);
    }
    public Task SaveAutoSignAsync(AutoSignLedger ledger, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        ledger.Validate(ledger.AccountId);
        AtomicFile.WriteJson(Path.Combine(AccountPath(ledger.AccountId), "auto-sign.json"), ledger);
        return Task.CompletedTask;
    }

}
