namespace UCASSignIn.Core;

public interface ISchoolClient
{
    Task<SchoolSession> LoginAsync(string username, string password, CancellationToken ct = default);
    Task<CourseQueryResult> CoursesAsync(SchoolSession session, DateOnly date, CancellationToken ct = default);
    Task<IReadOnlyList<SchoolSemester>> SemestersAsync(SchoolSession session, CancellationToken ct = default);
    Task<IReadOnlyList<CatalogCourse>> CatalogCoursesAsync(SchoolSession session, string semesterId, CancellationToken ct = default);
    Task<CourseAttendanceSummary> CourseAttendanceAsync(SchoolSession session, string courseId, CancellationToken ct = default);
    Task<SignResult> SignAsync(Course course, SchoolSession session, CancellationToken ct = default, Func<bool>? authorize = null);
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
public interface ICourseCatalogStore
{
    Task<SemesterCache?> LoadSemestersAsync(string accountId, CancellationToken ct = default);
    Task SaveSemestersAsync(string accountId, SemesterCache cache, CancellationToken ct = default);
    Task<CourseCatalogCache?> LoadCatalogAsync(string accountId, string semesterId, CancellationToken ct = default);
    Task SaveCatalogAsync(string accountId, string semesterId, CourseCatalogCache cache, CancellationToken ct = default);
    Task<CourseAttendanceCache?> LoadAttendanceAsync(string accountId, string semesterId, string courseId, CancellationToken ct = default);
    Task SaveAttendanceAsync(string accountId, string semesterId, string courseId, CourseAttendanceCache cache, CancellationToken ct = default);
    Task RemoveCatalogAsync(string accountId, CancellationToken ct = default);
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
