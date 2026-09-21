using System.Net;
using System.Text.Json;
namespace UCASSignIn.Core.Tests;

public static class TestData
{
    public static DateTimeOffset Now => new(2026, 9, 16, 8, 30, 0, TimeSpan.FromHours(8));
    public static SchoolSession Session(string id = "a") => new("u-" + id, "s-" + id, id, "测试同学");
    public static Course Course(string id = "1234567") => new(id, "", "示例课程", "示例教师", null, "08:30", "10:10", "20260916");
    public static StoredAccount Account(string id = "a", bool remember = false) => new(Session(id), remember ? new(id, "fictional-password") : null, id, Now);
}
public sealed class FakeClock(DateTimeOffset now) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = now; public override DateTimeOffset GetUtcNow() => Now;
}
public sealed class FakeHttp : HttpMessageHandler
{
    public sealed record Request(HttpMethod Method, Uri Uri, string Body, Dictionary<string, string> Headers);
    public List<Request> Requests { get; } = [];
    public Func<Request, Task<string>> Respond
    {
        get; set;
    }
    public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
    public FakeHttp(Func<Request, string> respond) => Respond = r => Task.FromResult(respond(r));
    public FakeHttp(Func<Request, Task<string>> respond) => Respond = respond;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var r = new Request(request.Method, request.RequestUri!, request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken), request.Headers.ToDictionary(p => p.Key, p => string.Join(",", p.Value), StringComparer.OrdinalIgnoreCase));
        Requests.Add(r);
        return new(Status)
        {
            Content = new StringContent(await Respond(r))
        };
    }
}
public sealed class MemoryAccounts : IAccountStore
{
    public AccountVault Vault = AccountVault.Empty;
    public bool FailSave;
    static AccountVault Clone(AccountVault vault) => JsonSerializer.Deserialize<AccountVault>(JsonSerializer.Serialize(vault))!;
    public Task<AccountVault> LoadAsync(CancellationToken ct = default) => Task.FromResult(Clone(Vault));
    public Task SaveAsync(AccountVault vault, CancellationToken ct = default)
    {
        if (FailSave)
            throw new IOException("simulated secure-store write failure");
        vault.Validate();
        Vault = Clone(vault);
        return Task.CompletedTask;
    }
}
public class MemoryData : ICourseStore, IRecordStore, ICourseCatalogStore
{
    public Dictionary<string, CourseCache> Cache = [];
    public int CourseCacheWrites;
    public Dictionary<string, List<AttendanceRecord>> Records = [];
    public Dictionary<string, SemesterCache> Semesters = [];
    public Dictionary<string, CourseCatalogCache> Catalogs = [];
    public Dictionary<string, CourseAttendanceCache> Attendance = [];
    public Func<string, string, Task<CourseCache?>>? LoadCourses;
    public Task<CourseCache?> LoadAsync(string accountId, string day, CancellationToken ct = default) => LoadCourses?.Invoke(accountId, day) ?? Task.FromResult(Cache.GetValueOrDefault(accountId + "|" + day));
    public Task SaveAsync(string accountId, string day, CourseCache cache, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        CourseCacheWrites++;
        Cache[accountId + "|" + day] = cache;
        return Task.CompletedTask;
    }
    Task<List<AttendanceRecord>> IRecordStore.LoadAsync(string accountId, CancellationToken ct) => Task.FromResult(Records.GetValueOrDefault(accountId) ?? []);
    public Task SaveAsync(string accountId, IReadOnlyList<AttendanceRecord> records, CancellationToken ct = default)
    {
        Records[accountId] = records.ToList();
        return Task.CompletedTask;
    }
    public Task RemoveAsync(string accountId, CancellationToken ct = default)
    {
        foreach (var key in Cache.Keys.Where(k => k.StartsWith(accountId + "|")).ToArray())
            Cache.Remove(key);
        Records.Remove(accountId);
        return Task.CompletedTask;
    }
    public Task<SemesterCache?> LoadSemestersAsync(string accountId, CancellationToken ct = default) => Task.FromResult(Semesters.GetValueOrDefault(accountId));
    public Task SaveSemestersAsync(string accountId, SemesterCache cache, CancellationToken ct = default) { Semesters[accountId] = cache; return Task.CompletedTask; }
    public Task<CourseCatalogCache?> LoadCatalogAsync(string accountId, string semesterId, CancellationToken ct = default) => Task.FromResult(Catalogs.GetValueOrDefault(accountId + "|" + semesterId));
    public Task SaveCatalogAsync(string accountId, string semesterId, CourseCatalogCache cache, CancellationToken ct = default) { Catalogs[accountId + "|" + semesterId] = cache; return Task.CompletedTask; }
    public Task<CourseAttendanceCache?> LoadAttendanceAsync(string accountId, string semesterId, string courseId, CancellationToken ct = default) => Task.FromResult(Attendance.GetValueOrDefault(accountId + "|" + semesterId + "|" + courseId));
    public Task SaveAttendanceAsync(string accountId, string semesterId, string courseId, CourseAttendanceCache cache, CancellationToken ct = default) { Attendance[accountId + "|" + semesterId + "|" + courseId] = cache; return Task.CompletedTask; }
    public Task RemoveCatalogAsync(string accountId, CancellationToken ct = default)
    {
        Semesters.Remove(accountId);
        foreach (var key in Catalogs.Keys.Where(x => x.StartsWith(accountId + "|")).ToArray()) Catalogs.Remove(key);
        foreach (var key in Attendance.Keys.Where(x => x.StartsWith(accountId + "|")).ToArray()) Attendance.Remove(key);
        return Task.CompletedTask;
    }
}
public sealed class FakeSchool : ISchoolClient
{
    public Func<SchoolSession, DateOnly, Task<WeeklyScheduleResult>>? WeekQuery;
    public int WeekReads;
    public async Task<CourseQueryResult> DailyScheduleAsync(SchoolSession session, DateOnly date, CancellationToken ct = default)
    {
        var result = await CoursesAsync(session, date, ct);
        if (result.FromWeeklyFallback) throw new SchoolException("SCHEDULE_UNKNOWN_DAY", "学校未明确返回所选日期");
        return result with { Courses = result.Courses.Where(c => CourseTime.NormalizeDay(c.Day) == CourseTime.DayKey(date)).ToArray() };
    }
    public async Task<WeeklyScheduleResult> WeeklyScheduleAsync(SchoolSession session, DateOnly date, CancellationToken ct = default)
    {
        WeekReads++;
        if (WeekQuery is not null) return await WeekQuery(session, date);
        var days = Enumerable.Range(0, 7).Select(i => ScheduleLayout.Monday(date).AddDays(i)).ToArray();
        var courses = new List<Course>();
        foreach (var day in days) courses.AddRange((await CoursesAsync(session, day, ct)).Courses);
        return new(courses, days.Select(CourseTime.DayKey).ToArray());
    }
    public Func<string, Task<SchoolSession>> Login = id => Task.FromResult(TestData.Session(id));
    public Func<SchoolSession, DateOnly, Task<CourseQueryResult>> Query = (_, date) => Task.FromResult(new CourseQueryResult([TestData.Course() with { Day = CourseTime.DayKey(date) }], "同步成功"));
    public Func<Task<SignResult>> Sign = () => Task.FromResult(new SignResult(SignOutcome.Signed, "成功"));
    public Func<Task> BeforeSignAuthorization = () => Task.CompletedTask;
    public Func<Task<IReadOnlyList<SchoolSemester>>> SemesterQuery = () => Task.FromResult<IReadOnlyList<SchoolSemester>>([new("2026", "2026 秋季", "20260901", "20270131", true)]);
    public Func<string, Task<IReadOnlyList<CatalogCourse>>> CatalogQuery = semester => Task.FromResult<IReadOnlyList<CatalogCourse>>([new("course-1", "CS001", "示例课程", "示例教师", null, semester, "20260901", "20270131")]);
    public Func<string, Task<CourseAttendanceSummary>> AttendanceQuery = course => Task.FromResult(new CourseAttendanceSummary(0, 0, []));
    public int Logins, Reads, Signs, ClockReads, SemesterReads, CatalogReads, AttendanceReads;
    public Course? LastSignedCourse;
    public Task<SchoolSession> LoginAsync(string username, string password, CancellationToken ct = default)
    {
        Logins++;
        return Login(username);
    }
    public Task<CourseQueryResult> CoursesAsync(SchoolSession session, DateOnly date, CancellationToken ct = default)
    {
        Reads++;
        return Query(session, date);
    }
    public Task<IReadOnlyList<SchoolSemester>> SemestersAsync(SchoolSession session, CancellationToken ct = default) { SemesterReads++; return SemesterQuery(); }
    public Task<IReadOnlyList<CatalogCourse>> CatalogCoursesAsync(SchoolSession session, string semesterId, CancellationToken ct = default) { CatalogReads++; return CatalogQuery(semesterId); }
    public Task<CourseAttendanceSummary> CourseAttendanceAsync(SchoolSession session, string courseId, CancellationToken ct = default) { AttendanceReads++; return AttendanceQuery(courseId); }
    public async Task<SignResult> SignAsync(Course course, SchoolSession session, CancellationToken ct = default, Func<bool>? authorize = null)
    {
        await BeforeSignAuthorization();
        if (authorize is not null && !authorize()) throw new OperationCanceledException();
        Signs++;
        LastSignedCourse = course;
        return await Sign();
    }
    public Task<QrSnapshot> QrAsync(Course course, CancellationToken ct = default) => throw new NotImplementedException();
    public Task<DateTimeOffset> SchoolNowAsync(CancellationToken ct = default)
    {
        ClockReads++;
        return Task.FromResult(TestData.Now);
    }
    public void ClearClock()
    {
    }
}
public sealed class FakeReminders : IReminderScheduler
{
    public Func<Task<bool>> Permission = () => Task.FromResult(true);
    public IReadOnlyList<Reminder> Scheduled = [];
    public Task<bool> RequestPermissionAsync() => Permission();
    public Task ReplaceAsync(IReadOnlyList<Reminder> reminders)
    {
        Scheduled = reminders;
        return Task.CompletedTask;
    }
}
