using System.Text.Json;

namespace UCASSignIn.Core.Tests;

public sealed class CourseScheduleTests
{
    static readonly SchoolSemester Term = new("fall", "秋季", "20261230", "20270302", true);
    static CatalogCourse Catalog(SchoolSemester? term = null) => new("catalog", "CS001", "课程", "目录教师", "目录教室",
        (term ?? Term).Id, (term ?? Term).BeginDate, (term ?? Term).EndDate);
    static Course Course(string day = "20261230", string id = "meeting") => new(id, "uuid-" + id, "课程", "张老师", "B203",
        "13:30", "16:10", day, false, "teacher-course", "CS001", "teacher");
    static CourseSchedulePresentation Build(params Course[] rows) => Core.CourseSchedule.Build(Catalog(), [Term], [Catalog()], rows);

    [Fact] public void CrossYearPartialWeeksAndGapsAreNotInvented()
    {
        var data = Build([.. new[] { "20261230", "20270106", "20270113", "20270217", "20270301" }.Select(d => Course(d))]);
        Assert.Equal(new[] { 1, 2, 3, 8, 10 }, data.Meetings.Select(m => m.Week));
        Assert.Equal("第 1–3、8、10 周", Core.CourseSchedule.CompressWeeks([1, 2, 3, 8, 10, 1]));
        Assert.Equal(2, data.Summaries.Length);
        Assert.Contains(data.Summaries, s => s.Weeks == "第 1–3、8 周");
        Assert.Equal(5, data.Meetings.Select(m => m.Id).Distinct().Count());
    }
    [Fact] public void TeachersMergeOnlyWithValidTimeAndKnownRoomAndOrderIsStable()
    {
        var a = Course(); var b = a with { Id = "other", Uuid = "uuid-other", Teacher = " 李老师 ", TeacherId = "t2" };
        var c = b with { Id = "third", Uuid = "uuid-third", Teacher = "张老师" };
        var rows = new[] { a, b, c, a with { Id = "other-room", Classroom = "B204" }, a with { Id = "other-time", BeginTime = "14:00" } };
        var data = Build(rows);
        Assert.Equal(3, data.Meetings.Length);
        var merged = Assert.Single(data.Meetings.Where(m => m.SourceIds.Length == 3));
        Assert.Equal(2, merged.Teachers.Length);
        Assert.Equal(JsonSerializer.Serialize(data), JsonSerializer.Serialize(Build(rows.Reverse().ToArray())));
    }
    [Fact] public void MissingRoomsAndInvalidTimesRemainSeparateAndSortAfterValidTimes()
    {
        var a = Course();
        var rows = new[] { a, a with { Id = "room1", Classroom = null }, a with { Id = "room2", Classroom = "" },
            a with { Id = "invalid", BeginTime = "bad" }, a with { Id = "reverse", BeginTime = "17:00" },
            a with { Id = "wrong-day", BeginTime = "2026-12-31 13:30" }, a with { Id = "missing", BeginTime = "", EndTime = "", Teacher = "" } };
        var data = Build(rows);
        Assert.Equal(rows.Length, data.Meetings.Length);
        Assert.All(data.Meetings.Take(3), m => Assert.NotNull(m.Start));
        Assert.All(data.Meetings.Skip(3), m => Assert.Null(m.Start));
        Assert.Equal(3, data.Meetings.Count(m => m.Time.Contains("时间待确认")));
        Assert.Contains(data.Meetings, m => m.Time.Contains("2026-12-31 13:30"));
        Assert.Equal(2, data.Meetings.Count(m => m.ClassroomText == "教室暂未提供"));
        Assert.Contains(data.Meetings, m => m.TeacherText == "教师暂未提供" && m.Time == "暂未提供");
        Assert.True(data.Summaries.Length > 3);
    }
    [Fact] public void IdentityRejectsNamesAmbiguityWrongSemesterAndUsesIdOnlyWithoutNumber()
    {
        Assert.Empty(Build(Course() with { CourseNumber = "different", CourseId = "catalog" }).Meetings);
        Assert.Single(Build(Course() with { CourseNumber = "", CourseId = "catalog" }).Meetings);
        Assert.Empty(Build(Course() with { CourseNumber = null, CourseId = "other" }).Meetings);
        Assert.NotNull(Core.CourseSchedule.Build(Catalog(), [Term], [Catalog(), Catalog() with { Id = "other" }], [Course()]).UnavailableReason);
        Assert.NotNull(Core.CourseSchedule.Build(Catalog(), [Term, Term with { Id = "overlap" }], [Catalog()], [Course()]).UnavailableReason);
        Assert.NotNull(Core.CourseSchedule.Build(Catalog() with { SemesterId = "missing" }, [Term], [Catalog()], [Course()]).UnavailableReason);
        Assert.Empty(Build(Course("20260916")).Meetings);
    }

    static readonly SchoolSemester Current = new("current", "当前", "20260914", "20260920", true);
    static readonly SchoolSemester History = new("history", "历史", "20260302", "20260315", false);
    sealed class Harness
    {
        public FakeClock Clock = new(TestData.Now);
        public MemoryScheduleData Data = new();
        public FakeSchool School = new();
        public MemoryAccounts Accounts = new() { Vault = new(1, [TestData.Account(), TestData.Account("b")], "a") };
        public AccountCoordinator Model;
        public Harness()
        {
            School.SemesterQuery = () => Task.FromResult<IReadOnlyList<SchoolSemester>>([Current, History]);
            School.CatalogQuery = id => Task.FromResult<IReadOnlyList<CatalogCourse>>([Catalog(id == History.Id ? History : Current)]);
            School.Query = (_, _) => Task.FromResult(new CourseQueryResult([], ""));
            School.WeekQuery = (_, d) => Task.FromResult(Week(d));
            Model = new(School, Accounts, Data, Data, new FakeReminders(), Clock);
        }
    }
    static WeeklyScheduleResult Week(DateOnly date, params Course[] courses) => new(courses,
        Enumerable.Range(0, 7).Select(i => CourseTime.DayKey(ScheduleLayout.Monday(date).AddDays(i))).ToArray());

    [Fact] public async Task HistoryDoesNotChangeSelectionAndFreshDataIsReused()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        var date = h.Model.SelectedDate; var selected = h.Model.SelectedSemester;
        var dayReads = h.School.Reads; var weeks = h.School.WeekReads;
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, Course(CourseTime.DayKey(d))));
        await h.Model.EnsureCourseScheduleAsync(Catalog(History));
        Assert.Equal(date, h.Model.SelectedDate); Assert.Equal(selected, h.Model.SelectedSemester);
        Assert.Equal(dayReads, h.School.Reads); Assert.Equal(weeks + 2, h.School.WeekReads);
        Assert.Equal(2, h.Model.CourseScheduleFor(Catalog(History)).Meetings.Length);
        var reads = (h.School.Reads, h.School.WeekReads, h.School.CatalogReads);
        await h.Model.EnsureCourseScheduleAsync(Catalog(History));
        Assert.Equal(reads, (h.School.Reads, h.School.WeekReads, h.School.CatalogReads));
        Assert.Null(h.Model.CourseScheduleStatus(Catalog(History)));
    }
    [Fact] public async Task DetailAndTimetableShareBatchAndUnrelatedBatchRetainsTarget()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
        h.School.WeekQuery = async (_, d) => { entered.TrySetResult(); await release.Task; return Week(d); };
        var weeks = h.School.WeekReads;
        var visible = h.Model.RefreshScheduleAsync(); await entered.Task;
        var first = h.Model.EnsureCourseScheduleAsync(Catalog(History));
        Assert.Same(first, h.Model.EnsureCourseScheduleAsync(Catalog(History)));
        release.SetResult(); await Task.WhenAll(first, visible);
        Assert.Equal(weeks + 3, h.School.WeekReads);
        Assert.True(h.Data.Schedules.ContainsKey("a|history"));
        Assert.Equal("本学期暂无排课", h.Model.CourseScheduleStatus(Catalog(History)));
    }
    [Fact] public async Task FailureKeepsKnownDayThenTimetableRecoveryClearsCooldown()
    {
        var h = new Harness();
        h.Data.Cache["a|20260304"] = new([Course("20260304")], TestData.Now, false);
        await h.Model.InitializeAsync();
        h.School.WeekQuery = (_, _) => throw new IOException("offline");
        await h.Model.EnsureCourseScheduleAsync(Catalog(History));
        Assert.Single(h.Model.CourseScheduleFor(Catalog(History)).Meetings);
        Assert.Contains("offline", h.Model.CourseScheduleError(History.Id));
        Assert.Equal("排课尚未完整同步", h.Model.CourseScheduleStatus(Catalog(History)));
        Assert.False(h.Data.Schedules.ContainsKey("a|history"));
        var reads = h.School.WeekReads;
        await h.Model.EnsureCourseScheduleAsync(Catalog(History)); Assert.Equal(reads, h.School.WeekReads);
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, Course("20260304")));
        await h.Model.SelectScheduleSemesterAsync(History.Id, h.Model.Generation);
        await h.Model.RefreshScheduleAsync();
        Assert.Null(h.Model.CourseScheduleError(History.Id));
        await h.Model.EnsureCourseScheduleAsync(Catalog(History));
        Assert.Null(h.Model.CourseScheduleError(History.Id)); Assert.Null(h.Model.CourseScheduleStatus(Catalog(History)));
    }
    [Fact] public async Task OpeningDetailDuringItsSemesterSyncDoesNotQueueDuplicateBatch()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
        h.School.WeekQuery = async (_, d) => { started.TrySetResult(); await release.Task; return Week(d); };
        var reads = h.School.WeekReads;
        var timetable = h.Model.RefreshScheduleAsync(); await started.Task;
        var detail = h.Model.EnsureCourseScheduleAsync(Catalog(Current));
        while (!h.Model.CourseScheduleLoading(Current.Id)) await Task.Yield();
        // Let the detail reach the shared runner while the school request remains pending.
        await Task.Yield(); await Task.Yield();
        release.SetResult(); await Task.WhenAll(timetable, detail);
        Assert.Equal(reads + 1, h.School.WeekReads);
    }
    [Fact] public async Task MissingMetadataDoesNotMoveSelectedDateOrLoadUncachedOtherTerms()
    {
        var h = new Harness(); h.School.SemesterQuery = () => Task.FromResult<IReadOnlyList<SchoolSemester>>([Current]);
        await h.Model.InitializeAsync(); var selected = h.Model.SelectedDate; var catalog = h.Model.SelectedSemester;
        h.School.SemesterQuery = () => Task.FromResult<IReadOnlyList<SchoolSemester>>([History]);
        var reads = h.School.WeekReads;
        await h.Model.EnsureCourseScheduleAsync(Catalog(History));
        Assert.Equal(selected, h.Model.SelectedDate); Assert.Equal(catalog, h.Model.SelectedSemester);
        Assert.Equal(reads + 2, h.School.WeekReads);
    }
    [Fact] public async Task ManualTimetableRefreshDoesNotMistakeUnrelatedDetailBatchForFreshCoverage()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
        h.School.WeekQuery = async (_, d) => { started.TrySetResult(); await release.Task; return Week(d); };
        var reads = h.School.WeekReads;
        var detail = h.Model.EnsureCourseScheduleAsync(Catalog(History)); await started.Task;
        var timetable = h.Model.RefreshScheduleAsync();
        release.SetResult(); await Task.WhenAll(detail, timetable);
        Assert.Equal(reads + 3, h.School.WeekReads);
    }
    [Fact] public async Task PresentationUsesNewerDailyOverlayAndPreservesSignedStatusDuringFullSync()
    {
        var h = new Harness();
        h.Data.Schedules["a|history"] = new(1, 1, "a", History, [Course("20260304")], TestData.Now, 10);
        h.Data.Cache["a|20260304"] = new([Course("20260304") with { Classroom = "NEW", Signed = true }], TestData.Now, false, 11);
        await h.Model.InitializeAsync(); await h.Model.EnsureCourseScheduleAsync(Catalog(History));
        Assert.Equal("NEW", Assert.Single(h.Model.CourseScheduleFor(Catalog(History)).Meetings).Classroom);
        var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
        h.Clock.Now += TimeSpan.FromDays(7);
        h.School.WeekQuery = async (_, d) => { started.TrySetResult(); await release.Task; return Week(d, Course("20260304")); };
        var detail = h.Model.EnsureCourseScheduleAsync(Catalog(History)); await started.Task;
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([Course("20260304") with { Classroom = "LATEST", Signed = true }], ""));
        await h.Model.CheckDayAsync(new(2026, 3, 4), true);
        release.SetResult(); await detail;
        Assert.Equal("LATEST", Assert.Single(h.Model.CourseScheduleFor(Catalog(History)).Meetings).Classroom);
        Assert.True(h.Model.Courses.Single(c => c.Day == "20260304").Signed);
    }
    [Theory]
    [InlineData(6.99, 1, false)]
    [InlineData(7, 1, true)]
    [InlineData(0, 0, true)]
    public async Task SevenDayBoundaryAndOldIdentityRequireFullSync(double days, int identity, bool refresh)
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        // Use a new coordinator so this snapshot follows the same persisted-cache path as a real launch.
        h.Data.Schedules["a|history"] = new(1, identity, "a", History, [], TestData.Now.AddDays(-days));
        var model = new AccountCoordinator(h.School, h.Accounts, h.Data, h.Data, new FakeReminders(), h.Clock);
        // Initialization also maintains already cached, expired terms.
        var reads = h.School.WeekReads;
        await model.InitializeAsync(); await model.EnsureCourseScheduleAsync(Catalog(History));
        Assert.Equal(refresh ? 2 : 0, h.School.WeekReads - reads);
    }
    [Fact] public async Task CatalogExpiresAndPresentationIgnoresSignOnlyChanges()
    {
        var h = new Harness(); h.School.Query = (_, d) => Task.FromResult(new CourseQueryResult([Course(CourseTime.DayKey(d))], ""));
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, Course("20260916")));
        await h.Model.InitializeAsync(); await h.Model.EnsureCourseScheduleAsync(Catalog(Current));
        var original = h.Model.CourseScheduleFor(Catalog(Current));
        h.School.Query = (_, d) => Task.FromResult(new CourseQueryResult([Course(CourseTime.DayKey(d)) with { Signed = true }], ""));
        await h.Model.CheckDayAsync(new(2026, 9, 16), true);
        Assert.Same(original, h.Model.CourseScheduleFor(Catalog(Current)));
        var reads = h.School.CatalogReads; h.Clock.Now += TimeSpan.FromMinutes(30);
        await h.Model.EnsureCourseScheduleAsync(Catalog(Current)); Assert.Equal(reads + 1, h.School.CatalogReads);
    }
    [Fact] public async Task AccountSwitchRejectsLateDetailResponse()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
        h.School.WeekQuery = async (s, d) => { if (s.StudentNo == "a") { entered.TrySetResult(); await release.Task; } return Week(d, Course("20260304")); };
        var task = h.Model.EnsureCourseScheduleAsync(Catalog(History)); await entered.Task;
        await h.Model.SwitchAsync("b"); release.SetResult(); await task;
        Assert.False(h.Model.CourseScheduleLoading(History.Id)); Assert.Null(h.Model.CourseScheduleError(History.Id));
        Assert.Empty(h.Model.CourseScheduleFor(Catalog(History)).Meetings);
        Assert.False(h.Data.Schedules.ContainsKey("b|history"));
    }
    [Fact] public async Task DemoIsOfflineAndContainsGapsTeachersAndDateScopedIds()
    {
        var h = new Harness(); await h.Model.InitializeDemoAsync();
        var course = h.Model.CatalogCourses[0]; var selected = h.Model.SelectedDate;
        await h.Model.EnsureCourseScheduleAsync(course);
        var data = h.Model.CourseScheduleFor(course);
        Assert.Null(data.UnavailableReason); Assert.True(data.Summaries.Length > 3);
        Assert.Contains(data.Meetings, m => m.Teachers.Length == 2 && m.SourceIds.Length == 2);
        Assert.Contains(data.Summaries, s => s.Weeks.Contains('、'));
        Assert.Equal(h.Model.Courses.Count, h.Model.Courses.Select(c => c.Id).Distinct().Count());
        Assert.Equal(selected, h.Model.SelectedDate);
        Assert.Equal(0, h.School.Reads + h.School.WeekReads + h.School.CatalogReads + h.School.SemesterReads);
    }
    [Fact] public async Task BackgroundPresentationUsesCapturedDataAndReusesCurrentCache()
    {
        var h = new Harness();
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, Course("20260916") with { Classroom = "OLD" }));
        await h.Model.InitializeAsync(); await h.Model.EnsureCourseScheduleAsync(Catalog(Current));
        Assert.Null(h.Model.CachedCourseScheduleFor(Catalog(Current)));
        var reads = (h.School.Reads, h.School.WeekReads, h.School.CatalogReads);
        var oldTask = h.Model.PrepareCourseScheduleAsync(Catalog(Current));
        var sharedTask = h.Model.PrepareCourseScheduleAsync(Catalog(Current));
        Assert.Same(await oldTask, await sharedTask);
        Assert.Equal(reads, (h.School.Reads, h.School.WeekReads, h.School.CatalogReads));
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([Course("20260916") with { Classroom = "NEW" }], ""));
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, Course("20260916") with { Classroom = "NEW" }));
        await h.Model.CheckDayAsync(new(2026, 9, 16), true);
        // A changed day also schedules a full refresh; finish it before asserting a stable cache identity.
        await h.Model.RefreshScheduleAsync();
        Assert.Null(h.Model.CachedCourseScheduleFor(Catalog(Current)));
        var current = await h.Model.PrepareCourseScheduleAsync(Catalog(Current));
        Assert.Equal("OLD", Assert.Single((await oldTask).Meetings).Classroom);
        Assert.Equal("NEW", Assert.Single(current.Meetings).Classroom);
        Assert.Same(current, h.Model.CachedCourseScheduleFor(Catalog(Current)));
        Assert.Same(current, h.Model.CourseScheduleFor(Catalog(Current)));
    }
    [Fact] public async Task BackgroundPresentationCannotRepopulateCacheAfterAccountSwitch()
    {
        var h = new Harness();
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, Course("20260916")));
        await h.Model.InitializeAsync(); await h.Model.EnsureCourseScheduleAsync(Catalog(Current));
        var pending = h.Model.PrepareCourseScheduleAsync(Catalog(Current));
        await h.Model.SwitchAsync("b");
        await pending;
        Assert.Null(h.Model.CachedCourseScheduleFor(Catalog(Current)));
        Assert.NotSame(await pending, await h.Model.PrepareCourseScheduleAsync(Catalog(Current)));
    }
}
