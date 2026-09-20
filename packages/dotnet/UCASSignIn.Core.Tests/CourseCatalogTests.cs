using System.Text.Json;

namespace UCASSignIn.Core.Tests;

public sealed class CourseCatalogTests
{
    static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();
    static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", name + ".json"));

    [Fact]
    public async Task CatalogEndpointsUseDocumentedFormsAndSession()
    {
        using var handler = new FakeHttp(request => request.Uri.AbsolutePath switch
        {
            "/app/course/get_base_school_year.action" => Fixture("semesters"),
            "/app/choosecourse/get_myall_course.action" => Fixture("catalog-courses"),
            "/app/my/get_my_course_sign_detail.action" => Fixture("course-attendance"),
            _ => throw new InvalidOperationException(request.Uri.AbsolutePath)
        });
        using var client = new SchoolClient(handler);
        var session = TestData.Session();
        var semesters = await client.SemestersAsync(session);
        var courses = await client.CatalogCoursesAsync(session, semesters.Single().Id);
        var attendance = await client.CourseAttendanceAsync(session, courses[0].Id);

        Assert.All(handler.Requests, r => Assert.Equal("s-a", r.Headers["sessionId"]));
        Assert.Contains("userId=u-a", handler.Requests[0].Body);
        Assert.Contains("type=2", handler.Requests[0].Body);
        Assert.Contains("user_type=1", handler.Requests[1].Uri.Query);
        Assert.Contains("xq_code=2026-autumn", handler.Requests[1].Body);
        Assert.Contains("courseId=course-fictional-1", handler.Requests[2].Body);
        Assert.Equal(2, attendance.Records.Count);
    }

    [Fact]
    public void CatalogRejectsTruncationAndSemesterMismatch()
    {
        Assert.Equal("COURSE_CATALOG_INCOMPLETE", Assert.Throws<SchoolException>(() => ResponseParser.CatalogCourses(
            Json("""{"STATUS":0,"total":2,"result":[{"course_id":"1","course_name":"x","semesterId":"s"}]}"""), "s")).Code);
        Assert.Equal("COURSE_CATALOG_SEMESTER_MISMATCH", Assert.Throws<SchoolException>(() => ResponseParser.CatalogCourses(
            Json("""{"STATUS":0,"result":[{"course_id":"1","course_name":"x","semesterId":"other"}]}"""), "s")).Code);
    }

    [Fact]
    public void AttendanceRejectsAnotherCourseAndAcceptsStringOrNumberStates()
    {
        var summary = ResponseParser.CourseAttendance(Json(Fixture("course-attendance")), "course-fictional-1");
        Assert.Equal(1, summary.SignedCount);
        Assert.Single(summary.Records, x => x.Signed);
        Assert.Throws<SchoolException>(() => ResponseParser.CourseAttendance(Json(Fixture("course-attendance")), "another-course"));
    }

    [Fact]
    public void OldVaultJsonGetsNewPreferenceDefaults()
    {
        var vault = JsonSerializer.Deserialize<AccountVault>("""{"Version":1,"Accounts":[{"Session":{"UserId":"u","SessionId":"s","StudentNo":"n"},"LoginUsername":"n","LastUsedAt":"2026-09-16T00:00:00+08:00","Settings":{"AutoSignEnabled":true,"RemindersEnabled":false}}],"ActiveAccountId":"n"}""")!;
        vault.Validate();
        var preferences = vault.Accounts.Single().Preferences;
        Assert.True(preferences.AutoSignEnabled);
        Assert.False(preferences.ConfirmBeforeSign);
        Assert.Equal(10, preferences.ReminderLeadMinutes);
        Assert.Empty(preferences.Courses);
    }

    [Fact]
    public async Task FreshCatalogCacheAvoidsNetworkAndForceRefreshBypassesTtl()
    {
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account()], "a") };
        var data = new MemoryData(); var school = new FakeSchool(); var clock = new FakeClock(TestData.Now);
        var semester = new SchoolSemester("2026", "2026 秋季", "20260901", "20270131", true);
        var course = new CatalogCourse("official-1", "CS1", "课程", "教师", null, semester.Id, semester.BeginDate, semester.EndDate);
        data.Semesters["a"] = new(SemesterCache.CurrentVersion, "a", clock.Now, [semester]);
        data.Catalogs["a|2026"] = new(CourseCatalogCache.CurrentVersion, "a", "2026", clock.Now, [course]);
        var model = new AccountCoordinator(school, accounts, data, data, new FakeReminders(), clock);
        await model.InitializeAsync();
        await model.RefreshCatalogAsync();
        Assert.Equal("official-1", Assert.Single(model.CatalogCourses).Id);
        Assert.Equal(0, school.SemesterReads);
        Assert.Equal(0, school.CatalogReads);
        await model.RefreshCatalogAsync(true);
        Assert.Equal(1, school.SemesterReads);
        Assert.Equal(1, school.CatalogReads);
    }

    [Fact]
    public async Task CourseOverrideCanEnableServiceWhileGlobalDefaultIsOff()
    {
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account()], "a") };
        var data = new MemoryData(); var model = new AccountCoordinator(new FakeSchool(), accounts, data, data, new FakeReminders(), new FakeClock(TestData.Now));
        await model.InitializeAsync();
        await model.SetCoursePreferencesAsync("official-1", new(AutoSign: PreferenceOverride.Enabled));
        Assert.True(model.EffectiveAutoSign("official-1"));
        Assert.True(model.NeedsAutoSignService);
        await model.SetCoursePreferencesAsync("official-1", new(AutoSign: PreferenceOverride.Enabled, SignInDisabled: true));
        Assert.False(model.EffectiveAutoSign("official-1"));
        Assert.False(model.NeedsAutoSignService);
    }

    [Fact]
    public async Task DisablingCourseDuringPreparationPreventsSignSubmission()
    {
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account()], "a") };
        var data = new MemoryData(); var school = new FakeSchool();
        school.Query = (_, date) => Task.FromResult(new CourseQueryResult([TestData.Course() with { Day = CourseTime.DayKey(date), CourseId = "official-1" }], ""));
        var reachedClockWait = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseClockWait = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        school.BeforeSignAuthorization = async () => { reachedClockWait.SetResult(); await releaseClockWait.Task; };
        var model = new AccountCoordinator(school, accounts, data, data, new FakeReminders(), new FakeClock(TestData.Now));
        await model.InitializeAsync();
        await model.SetCoursePreferencesAsync("official-1", new(AutoSign: PreferenceOverride.Enabled));
        var course = Assert.Single(model.Courses);
        var pending = model.SignAsync(course, model.Generation, true);
        await reachedClockWait.Task;
        await model.SetCoursePreferencesAsync("official-1", new(AutoSign: PreferenceOverride.Enabled, SignInDisabled: true));
        releaseClockWait.SetResult();
        await pending;
        Assert.Equal(0, school.Signs);
        Assert.Empty(model.Records);
    }

    [Fact]
    public async Task ConcurrentCatalogRefreshesJoinOneRequest()
    {
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account()], "a") };
        var data = new MemoryData(); var school = new FakeSchool();
        var release = new TaskCompletionSource<IReadOnlyList<SchoolSemester>>(TaskCreationOptions.RunContinuationsAsynchronously);
        school.SemesterQuery = async () => await release.Task;
        var model = new AccountCoordinator(school, accounts, data, data, new FakeReminders(), new FakeClock(TestData.Now));
        await model.InitializeAsync();
        var first = model.RefreshCatalogAsync(true);
        var second = model.RefreshCatalogAsync(true);
        Assert.Same(first, second);
        release.SetResult([new("2026", "2026 秋季", "20260901", "20270131", true)]);
        await first;
        Assert.Equal(1, school.SemesterReads);
        Assert.Equal(1, school.CatalogReads);
    }

    [Fact]
    public async Task AutomaticCatalogFailuresUseOneTwoFiveMinuteBackoff()
    {
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account()], "a") };
        var data = new MemoryData(); var school = new FakeSchool(); var clock = new FakeClock(TestData.Now);
        school.SemesterQuery = () => throw new IOException("offline");
        var model = new AccountCoordinator(school, accounts, data, data, new FakeReminders(), clock);
        await model.InitializeAsync();
        await model.RefreshCatalogAsync();
        await model.RefreshCatalogAsync();
        Assert.Equal(1, school.SemesterReads);
        clock.Now += TimeSpan.FromMinutes(1);
        await model.RefreshCatalogAsync();
        Assert.Equal(2, school.SemesterReads);
        clock.Now += TimeSpan.FromMinutes(1);
        await model.RefreshCatalogAsync();
        Assert.Equal(2, school.SemesterReads);
        clock.Now += TimeSpan.FromMinutes(1);
        await model.RefreshCatalogAsync();
        Assert.Equal(3, school.SemesterReads);
    }

    [Fact]
    public void InvalidStoredCoursePreferencesAreNormalized()
    {
        var preferences = JsonSerializer.Deserialize<AccountPreferences>("""{"AutoSignEnabled":false,"RemindersEnabled":false,"ReminderLeadMinutes":99,"Courses":{"course":{"AutoSign":99,"ReminderLeadMinutes":7}}}""")!;
        Assert.Equal(10, preferences.ReminderLeadMinutes);
        Assert.Equal(PreferenceOverride.Inherit, preferences.Courses["course"].AutoSign);
        Assert.Null(preferences.Courses["course"].ReminderLeadMinutes);
    }
}
