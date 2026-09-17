namespace UCASSignIn.Core;

public interface ISchoolClient
{
    Task<SchoolSession> LoginAsync(string username, string password, CancellationToken ct = default);
    Task<CourseQueryResult> CoursesAsync(SchoolSession session, DateOnly date, CancellationToken ct = default);
    Task<SignResult> SignAsync(Course course, SchoolSession session, CancellationToken ct = default);
    Task<QrSnapshot> QrAsync(Course course, CancellationToken ct = default);
    Task<DateTimeOffset> SchoolNowAsync(CancellationToken ct = default);
    void ClearClock();
}
public interface IAccountStore
{
    Task<AccountVault> LoadAsync(CancellationToken ct = default);
    Task SaveAsync(AccountVault vault, CancellationToken ct = default);
}
public interface ICourseStore
{
    Task<CourseCache?> LoadAsync(string accountId, string day, CancellationToken ct = default);
    Task SaveAsync(string accountId, string day, CourseCache cache, CancellationToken ct = default);
    Task RemoveAsync(string accountId, CancellationToken ct = default);
}
public interface IRecordStore
{
    Task<List<AttendanceRecord>> LoadAsync(string accountId, CancellationToken ct = default);
    Task SaveAsync(string accountId, IReadOnlyList<AttendanceRecord> records, CancellationToken ct = default);
    Task RemoveAsync(string accountId, CancellationToken ct = default);
}
public interface IReminderScheduler
{
    Task<bool> RequestPermissionAsync();
    Task ReplaceAsync(IReadOnlyList<Reminder> reminders);
}
