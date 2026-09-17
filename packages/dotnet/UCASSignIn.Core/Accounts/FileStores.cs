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
public sealed class FileDataStore(string root) : ICourseStore, IRecordStore
{
    string AccountPath(string id) => Path.Combine(root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))));
    public Task<CourseCache?> LoadAsync(string accountId, string day, CancellationToken ct = default)
        => Task.FromResult(AtomicFile.ReadJson<CourseCache>(Path.Combine(AccountPath(accountId), CourseTime.NormalizeDay(day) + ".json")));
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
        AtomicFile.WriteJson(Path.Combine(AccountPath(accountId), "records.json"), records.Take(100).ToArray());
        return Task.CompletedTask;
    }
    public Task RemoveAsync(string accountId, CancellationToken ct = default)
    {
        var path = AccountPath(accountId);
        if (Directory.Exists(path))
            Directory.Delete(path, true);
        return Task.CompletedTask;
    }
}
