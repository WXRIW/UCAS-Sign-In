using System.Text.Json;
namespace UCASSignIn.Core.Tests;

public sealed class MemoryScheduleData : MemoryData, IScheduleStore
{
    public Dictionary<string, ScheduleSnapshot> Schedules = [];
    public Dictionary<string, ScheduleRetryTargets> RetryTargets = [];
    public bool FailSnapshot;
    public Task<IReadOnlyList<ScheduleSnapshot>> LoadSchedulesAsync(string id, CancellationToken ct = default)
        => Task.FromResult<IReadOnlyList<ScheduleSnapshot>>(Schedules.Values.Where(s => s.AccountId == id).ToArray());
    public Task SaveScheduleAsync(ScheduleSnapshot snapshot, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested(); if (FailSnapshot) throw new IOException("disk full");
        Schedules[snapshot.AccountId + "|" + snapshot.Semester.Id] = snapshot; return Task.CompletedTask;
    }
    public Task<IReadOnlyList<string>> CachedDaysAsync(string id, CancellationToken ct = default)
        => Task.FromResult<IReadOnlyList<string>>(Cache.Keys.Where(k => k.StartsWith(id + "|")).Select(k => k[(id.Length + 1)..]).ToArray());
    public Task<ScheduleRetryTargets?> LoadScheduleRetriesAsync(string id, CancellationToken ct = default) => Task.FromResult(RetryTargets.GetValueOrDefault(id));
    public Task SaveScheduleRetriesAsync(string id, ScheduleRetryTargets targets, CancellationToken ct = default)
    { ct.ThrowIfCancellationRequested(); RetryTargets[id] = targets; return Task.CompletedTask; }
}
public sealed class ScheduleTests
{
    [Fact] public async Task AliasIndexRejectsNewAmbiguityAndRebuildsAfterRefresh()
    {
        var h = new Harness(); var first = Course();
        h.Accounts.Vault = new(1, [TestData.Account() with { Settings = new(Courses: new()
            { ["teacher-record"] = new(SignInDisabled: true) }) }], "a");
        h.School.CatalogQuery = _ => Task.FromResult<IReadOnlyList<CatalogCourse>>([Catalog(), Catalog("second", "CS002")]);
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, first));
        await h.Model.InitializeAsync();
        Assert.True(h.Model.CoursePreferencesFor("unified").SignInDisabled);
        var conflicting = first with { Id = "other", CourseNumber = "CS002" };
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, first, conflicting));
        await h.Model.RefreshScheduleAsync();
        Assert.False(h.Model.CoursePreferencesFor("unified").SignInDisabled);
        Assert.False(h.Model.CoursePreferencesFor("second").SignInDisabled);
        Assert.True(h.Model.CoursePreferencesFor("teacher-record").SignInDisabled);
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, first));
        await h.Model.RefreshScheduleAsync();
        Assert.True(h.Model.CoursePreferencesFor("unified").SignInDisabled);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DailyCacheStatusClearsAfterColdStartAndRetryWithoutRefreshingOtherDays(bool hasCourse)
    {
        var h = new Harness();
        var today = new DateOnly(2026, 9, 16);
        var otherDay = today.AddDays(1);
        var current = Course();
        var other = Course("7654321", CourseTime.DayKey(otherDay));
        h.Data.Schedules["a|fall"] = new(1, 1, "a", Term, hasCourse ? [current, other] : [other], TestData.Now.AddHours(-1));
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult(hasCourse ? [current] : [], ""));

        await h.Model.InitializeAsync();
        Assert.False(h.Model.IsCached(today));
        Assert.True(h.Model.IsCached(otherDay));
        Assert.False(h.Model.IsFresh(other));
        Assert.Equal(hasCourse ? 1 : 0, h.Model.DisplayCourses(today).Count);
        if (hasCourse) Assert.True(h.Model.CanSign(current));
        Assert.Equal(0, h.School.WeekReads);

        // A new process must check today again; a failed check retains its cache banner.
        h.School.Query = (_, _) => throw new IOException("offline");
        var restarted = new AccountCoordinator(h.School, h.Accounts, h.Data, h.Data, new FakeReminders(), h.Clock);
        await restarted.InitializeAsync();
        Assert.True(restarted.IsCached(today));
        Assert.True(restarted.IsCached(otherDay));
        Assert.False(restarted.CanSign(current));

        // The banner's daily retry clears only the relevant day's stale status.
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult(hasCourse ? [current] : [], ""));
        bool? cachedAtNotification = null;
        restarted.Changed += () => cachedAtNotification = restarted.IsCached(today);
        await restarted.RefreshAsync(today);
        Assert.False(cachedAtNotification);
        Assert.False(restarted.IsCached(today));
        Assert.False(restarted.IsLoadingCourses(today));
        Assert.True(restarted.IsCached(otherDay));
        Assert.Equal(hasCourse ? 1 : 0, restarted.DisplayCourses(today).Count);
        if (hasCourse) Assert.True(restarted.CanSign(current));
        Assert.Equal(0, h.School.WeekReads);
    }

    [Fact] public async Task ChangedLegacyDayRefreshesAlreadyCheckedDaysInItsUnassignedWeek()
    {
        var h = new Harness();
        h.School.SemesterQuery = () => Task.FromResult<IReadOnlyList<SchoolSemester>>([Term with { Id = "old", BeginDate = "20260801", EndDate = "20260831", IsCurrent = false }, Term with { BeginDate = "20261001", EndDate = "20261007" }]);
        h.School.Query = (_, d) => Task.FromResult(new CourseQueryResult([Course(day: CourseTime.DayKey(d))], ""));
        await h.Model.InitializeAsync(); var reads = h.School.Reads;
        h.School.Query = (_, d) => Task.FromResult(new CourseQueryResult([Course(day: CourseTime.DayKey(d)) with { Classroom = "B202" }], ""));
        await h.Model.CheckDayAsync(new(2026, 9, 16), true); await h.Model.RefreshScheduleAsync(false);
        Assert.True(h.School.Reads >= reads + 7);
        Assert.All(h.Model.Courses, c => Assert.Equal("B202", c.Classroom));
    }
    [Fact] public async Task LegacyPreferenceAliasesMergeStrictlyAndSavingUnifiedPreferenceClearsThem()
    {
        var h = new Harness(); var a = Course(); var b = a with { Id = "7654321", CourseId = "teacher2", TeacherId = "t2" };
        h.Accounts.Vault = new(1, [TestData.Account() with { Settings = new(Courses: new()
        {
            ["teacher-record"] = new(Confirmation: PreferenceOverride.Enabled, ReminderLeadMinutes: 15),
            ["teacher2"] = new(AutoSign: PreferenceOverride.Disabled, Reminders: PreferenceOverride.Disabled, ReminderLeadMinutes: 30, SignInDisabled: true)
        }) }], "a");
        h.School.CatalogQuery = _ => Task.FromResult<IReadOnlyList<CatalogCourse>>([Catalog()]);
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, a, b)); await h.Model.InitializeAsync();
        var values = h.Model.CoursePreferencesFor("unified"); Assert.True(values.SignInDisabled); Assert.Equal(30, values.ReminderLeadMinutes);
        Assert.Equal(PreferenceOverride.Enabled, values.Confirmation); Assert.Equal(PreferenceOverride.Disabled, values.AutoSign);
        Assert.False(h.Model.CanSign(a)); await h.Model.SetCoursePreferencesAsync("unified", new(Confirmation: PreferenceOverride.Enabled));
        Assert.False(h.Model.Preferences.Courses.ContainsKey("teacher2")); Assert.False(h.Model.Preferences.Courses.ContainsKey("teacher-record")); Assert.True(h.Model.CanSign(a));
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([a with { Signed = true }, b], ""));
        await h.Model.SignAsync(a, h.Model.Generation);
        Assert.Equal(a.Id, h.School.LastSignedCourse?.Id); Assert.Equal(a.Uuid, h.School.LastSignedCourse?.Uuid); Assert.Equal(1, h.School.Signs);
        Assert.False(h.Model.Courses.Single(c => c.Id == b.Id).Signed);
    }
    [Fact] public async Task AccountRoundTripReusesProcessChecksButNewCoordinatorRechecksDate()
    {
        var h = new Harness(); await h.Model.InitializeAsync(); await h.Model.SwitchAsync("b"); var reads = h.School.Reads;
        await h.Model.SwitchAsync("a"); Assert.Equal(reads, h.School.Reads);
        var next = new AccountCoordinator(h.School, h.Accounts, h.Data, h.Data, new FakeReminders(), h.Clock);
        await next.InitializeAsync(); Assert.Equal(reads + 1, h.School.Reads);
    }
    [Fact] public async Task FileStorePersistsEmptyDaysSnapshotsAndRetriesAndRemovesAccountOnly()
    {
        var root = Path.Combine(Path.GetTempPath(), "ucas-schedule-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new FileDataStore(root);
            await store.SaveAsync("a", "20260916", new([], TestData.Now, false, 8));
            await store.SaveScheduleAsync(new(1, 1, "a", Term, [], TestData.Now, 7));
            await store.SaveScheduleRetriesAsync("a", new([Term.Id], []));
            await store.SaveScheduleAsync(new(1, 1, "b", Term, [Course()], TestData.Now));
            Assert.Equal("20260916", Assert.Single(await store.CachedDaysAsync("a"))); Assert.Empty(Assert.Single(await store.LoadSchedulesAsync("a")).Courses);
            Assert.Equal(8, (await store.LoadAsync("a", "20260916"))!.WriteSequence); Assert.Equal(Term.Id, Assert.Single((await store.LoadScheduleRetriesAsync("a"))!.SemesterIds));
            await store.RemoveAsync("a"); Assert.Empty(await store.LoadSchedulesAsync("a")); Assert.Empty(await store.CachedDaysAsync("a")); Assert.Null(await store.LoadScheduleRetriesAsync("a"));
            Assert.Single(await store.LoadSchedulesAsync("b"));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
    [Fact] public void HashCollisionsProbeAllSevenColors()
    {
        var values = Enumerable.Range(0, 1000).Select(i => Course() with { CourseNumber = "CS" + i }).Where(c => ScheduleColors.Hash(ScheduleColors.Key(c)) == 0).Take(14).ToArray();
        var allocator = new ScheduleColors(); allocator.Include(values); Assert.Equal(7, values.Select(allocator.Color).Distinct().Count());
        Assert.All(values.GroupBy(allocator.Color), g => Assert.Equal(2, g.Count()));
    }
    [Fact] public async Task DemoWeekendRemainsEmptyAfterRefreshAndNoSchoolCalls()
    {
        var h = new Harness(); await h.Model.InitializeDemoAsync(); await h.Model.SelectDateAsync(new(2026, 9, 19)); await h.Model.RefreshAsync();
        Assert.Empty(h.Model.DisplayCourses(new(2026, 9, 19))); Assert.Equal(0, h.School.Reads); Assert.Equal(0, h.School.WeekReads);
    }
    static readonly SchoolSemester Term = new("fall", "秋季", "20260914", "20260920", true);
    sealed class Harness
    {
        public FakeClock Clock = new(TestData.Now);
        public MemoryScheduleData Data = new();
        public FakeSchool School = new();
        public MemoryAccounts Accounts = new() { Vault = new(1, [TestData.Account(), TestData.Account("b")], "a") };
        public AccountCoordinator Model;
        public Harness()
        {
            School.SemesterQuery = () => Task.FromResult<IReadOnlyList<SchoolSemester>>([Term]);
            School.Query = (_, _) => Task.FromResult(new CourseQueryResult([], ""));
            School.WeekQuery = (_, date) => Task.FromResult(Week(date));
            Model = new(School, Accounts, Data, Data, new FakeReminders(), Clock) { ScheduleMode = ScheduleMode.Week };
        }
    }
    static WeeklyScheduleResult Week(DateOnly date, params Course[] courses) => new(courses,
        Enumerable.Range(0, 7).Select(i => CourseTime.DayKey(ScheduleLayout.Monday(date).AddDays(i))).ToArray());
    static CatalogCourse Catalog(string id = "unified", string number = "CS001") => new(id, number, "课程", "教师", "A101", Term.Id, Term.BeginDate, Term.EndDate);
    static Course Course(string id = "1234567", string day = "20260916", string start = "08:30", string end = "10:00")
        => new(id, "uuid-" + id, "课程", "教师", "A101", start, end, day, false, "teacher-record", "CS001", "t1");
    [Fact] public async Task StrictEmptyDayDoesNotRequestWeek()
    {
        var http = new FakeHttp(_ => "{\"STATUS\":\"0\",\"result\":[]}"); using var school = new SchoolClient(http);
        var result = await school.DailyScheduleAsync(TestData.Session(), new(2026, 9, 16));
        Assert.Empty(result.Courses); Assert.Single(http.Requests);
    }
    [Theory]
    [InlineData("{\"STATUS\":\"0\",\"result\":[{\"schedData\":[]}]}")]
    [InlineData("{\"STATUS\":\"0\",\"result\":[{\"dateStr\":\"20260916\"}]}")]
    [InlineData("{\"STATUS\":\"0\",\"result\":[{\"dateStr\":\"20260916\",\"schedData\":[]},{\"dateStr\":\"2026-09-16\",\"schedData\":[]}]}")]
    [InlineData("{\"STATUS\":\"2\",\"result\":[]}")]
    public void InvalidWeeklyCoverageIsRejected(string json)
    { using var doc = JsonDocument.Parse(json); Assert.Throws<SchoolException>(() => ResponseParser.WeeklySchedule(doc.RootElement)); }
    [Fact] public void ExplicitEmptyDayIsCovered()
    {
        using var doc = JsonDocument.Parse("{\"STATUS\":\"0\",\"result\":[{\"dateStr\":\"2026-09-16\",\"schedData\":[]}]}");
        var result = ResponseParser.WeeklySchedule(doc.RootElement); Assert.Empty(result.Courses); Assert.Equal("20260916", Assert.Single(result.CoveredDays));
    }
    [Fact] public async Task EmptySemesterCommitsAllDaysAndColdChecksAreDeduplicated()
    {
        var h = new Harness(); await h.Model.InitializeAsync(); Assert.True(h.Model.HasCompleteWeek); Assert.Equal(1, h.School.WeekReads);
        Assert.Equal(TestData.Now, h.Model.ScheduleUpdatedAt); Assert.Empty(h.Data.Schedules["a|fall"].Courses);
        await h.Model.EnterScheduleAsync(); await h.Model.SelectDateAsync(new(2026, 9, 18)); await h.Model.EnterScheduleAsync();
        Assert.Equal(1, h.School.Reads); Assert.Equal(1, h.School.WeekReads);
    }
    [Fact] public async Task SevenDayBoundaryClockRollbackAndManualRefresh()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        h.Clock.Now = TestData.Now.AddDays(7).AddTicks(-1); await h.Model.MaintainScheduleAsync(); Assert.Equal(1, h.School.WeekReads);
        h.Clock.Now = TestData.Now.AddDays(7); await h.Model.MaintainScheduleAsync(); Assert.Equal(2, h.School.WeekReads);
        h.Clock.Now = TestData.Now; await h.Model.MaintainScheduleAsync(); Assert.Equal(3, h.School.WeekReads);
        await h.Model.RefreshScheduleAsync(); Assert.Equal(4, h.School.WeekReads);
    }
    [Fact] public async Task MissingWeeklyDaysUseStrictDailyReadsOnlyForRequiredDates()
    {
        var h = new Harness(); var term = Term with { BeginDate = "20260916", EndDate = "20260918" };
        h.School.SemesterQuery = () => Task.FromResult<IReadOnlyList<SchoolSemester>>([term]);
        var queries = new List<string>(); h.School.Query = (_, d) => { queries.Add(CourseTime.DayKey(d)); return Task.FromResult(new CourseQueryResult([], "")); };
        h.School.WeekQuery = (_, _) => Task.FromResult(new WeeklyScheduleResult([], ["20260916", "20260918"]));
        await h.Model.InitializeAsync(); Assert.Contains("20260917", queries); Assert.Equal(1, queries.Count(x => x == "20260917"));
        Assert.Equal("20260916", h.Data.Schedules["a|fall"].Semester.BeginDate);
    }
    [Fact] public async Task FailurePreservesSnapshotBacksOffAndManualRetryBypassesCooldown()
    {
        var h = new Harness(); await h.Model.InitializeAsync(); var old = h.Data.Schedules["a|fall"];
        h.Clock.Now = TestData.Now.AddDays(8); h.School.WeekQuery = (_, _) => throw new IOException("offline");
        await h.Model.MaintainScheduleAsync(); Assert.Same(old, h.Data.Schedules["a|fall"]); Assert.Contains("fall", h.Data.RetryTargets["a"].SemesterIds);
        Assert.NotNull(h.Model.ScheduleError); await h.Model.MaintainScheduleAsync(); Assert.Equal(2, h.School.WeekReads);
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d)); await h.Model.RefreshScheduleAsync(); Assert.Equal(3, h.School.WeekReads);
        Assert.Empty(h.Data.RetryTargets["a"].SemesterIds); Assert.Equal(h.Clock.Now, h.Model.ScheduleUpdatedAt);
    }
    [Fact] public async Task FailedAtomicWriteDoesNotAdvanceFullTimestamp()
    {
        var h = new Harness(); await h.Model.InitializeAsync(); h.Data.FailSnapshot = true; h.Clock.Now = TestData.Now.AddDays(8);
        await h.Model.RefreshScheduleAsync(); Assert.Equal(TestData.Now, h.Model.ScheduleUpdatedAt); Assert.Contains("disk full", h.Model.ScheduleError);
    }
    [Fact] public async Task OlderSemesterResponseCannotReplaceNewDailyResult()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        var response = new TaskCompletionSource<WeeklyScheduleResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.WeekQuery = (_, _) => { started.TrySetResult(); return response.Task; };
        var full = h.Model.RefreshScheduleAsync(); await started.Task.WaitAsync(TimeSpan.FromSeconds(3));
        // Signed-only change avoids scheduling another full refresh; the newer success still wins.
        var c = Course(); h.Model.ScheduleMode = ScheduleMode.Day;
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([c], ""));
        await h.Model.RefreshAsync(new(2026, 9, 16));
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, c));
        response.SetResult(Week(new(2026, 9, 16)));
        await full.WaitAsync(TimeSpan.FromSeconds(3)); Assert.Equal(c, Assert.Single(h.Model.DisplayCourses(new(2026, 9, 16))));
        Assert.Equal(c, Assert.Single(h.Data.Schedules["a|fall"].Courses));
    }
    [Fact] public async Task AccountSwitchRejectsOldSemesterResponse()
    {
        var h = new Harness(); await h.Model.InitializeAsync(); var started = new TaskCompletionSource();
        var response = new TaskCompletionSource<WeeklyScheduleResult>();
        h.School.WeekQuery = (_, _) => { started.SetResult(); return response.Task; };
        var pending = h.Model.RefreshScheduleAsync(); await started.Task.WaitAsync(TimeSpan.FromSeconds(3));
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d)); await h.Model.SwitchAsync("b");
        response.SetResult(Week(new(2026, 9, 16), Course())); await pending;
        Assert.Equal("b", h.Model.ActiveAccount!.Id); Assert.Empty(h.Model.Courses); Assert.Empty(h.Data.Schedules["b|fall"].Courses);
    }
    [Fact] public async Task NewerDailyOverlaySurvivesRestartAndDoesNotGrantSignPermission()
    {
        var h = new Harness(); h.Data.Schedules["a|fall"] = new(1, 1, "a", Term, [], TestData.Now, 10);
        h.Data.Cache["a|20260916"] = new([Course()], TestData.Now.AddHours(-1), false, 11);
        h.School.Query = (_, _) => throw new IOException("offline"); await h.Model.InitializeAsync();
        var course = Assert.Single(h.Model.DisplayCourses(new(2026, 9, 16))); Assert.False(h.Model.CanSign(course)); Assert.Equal(0, h.School.WeekReads);
    }
    [Theory]
    [InlineData("version")]
    [InlineData("account")]
    [InlineData("semester")]
    [InlineData("courses")]
    public async Task InvalidIdentityCacheIsReplacedBeforeLinkingCourses(string invalid)
    {
        var h = new Harness(); var course = Course(); var stale = Catalog("stale");
        h.Data.Catalogs["a|fall"] = new(invalid == "version" ? -1 : CourseCatalogCache.CurrentVersion,
            invalid == "account" ? "other" : "a", invalid == "semester" ? "other" : "fall", TestData.Now,
            [invalid == "courses" ? stale with { SemesterId = "other" } : stale]);
        h.School.CatalogQuery = _ => Task.FromResult<IReadOnlyList<CatalogCourse>>([Catalog()]);
        h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, course));
        await h.Model.InitializeAsync();
        Assert.Equal("unified", h.Model.CatalogFor(course)?.Id);
        Assert.Equal("unified", Assert.Single(h.Data.Catalogs["a|fall"].Courses).Id);
        Assert.Equal(1, h.School.CatalogReads);
    }
    [Fact] public void IdentityUsesDateAndNumberRejectsAmbiguityAndNeverGuessesByName()
    {
        Assert.Equal("unified", CourseIdentity.Resolve(Course(), [Term], [Catalog()])?.Id);
        Assert.Null(CourseIdentity.Resolve(Course(), [Term], [Catalog(), Catalog("other")]));
        Assert.Null(CourseIdentity.Resolve(Course() with { CourseNumber = null }, [Term], [Catalog()]));
        Assert.Null(CourseIdentity.Resolve(Course(), [Term, Term with { Id = "overlap" }], [Catalog()]));
    }
    [Fact] public void NormalizedOrderAndSignChangesAreNotArrangementChanges()
    {
        var a = Course(); var b = Course("7654321");
        Assert.True(CourseIdentity.SameArrangement([a, b], [b with { Signed = true }, a with { Day = "2026-09-16", BeginTime = "0830", Name = " 课程 " }]));
        foreach (var changed in new[] { a with { Classroom = "B202" }, a with { TeacherId = "t2" }, a with { CourseNumber = "CS002" }, a with { Uuid = "different" } })
            Assert.False(CourseIdentity.SameArrangement([a], [changed]));
    }
    [Fact] public void ColorsAreBalancedStableAndUseAllSlotsBeforeRepeating()
    {
        var courses = Enumerable.Range(0, 70).Select(i => Course(i.ToString()) with { CourseNumber = "CS" + i }).ToArray();
        var colors = new ScheduleColors(); colors.Include(courses.Take(7)); Assert.Equal(7, courses.Take(7).Select(colors.Color).Distinct().Count());
        var old = courses.Take(7).Select(colors.Color).ToArray(); colors.Include(courses); Assert.Equal(old, courses.Take(7).Select(colors.Color));
        Assert.All(courses.GroupBy(colors.Color), group => Assert.Equal(10, group.Count()));
        var first = new ScheduleColors(); var second = new ScheduleColors(); first.Include(courses); second.Include(courses.Reverse());
        Assert.Equal(courses.Select(first.Color), courses.Select(second.Color));
    }
    [Fact] public void TeacherMergeTransitiveOverlapAndInvalidTimeArePreserved()
    {
        var a = Course(); var teacher = a with { Id = "7654321", CourseId = "teacher2", TeacherId = "t2" };
        var b = Course("b", start: "09:30", end: "11:00") with { CourseNumber = "CS002" };
        var c = Course("c", start: "10:30", end: "12:00") with { CourseNumber = "CS003" };
        var adjacent = Course("d", start: "12:00", end: "13:00"); var invalid = Course("e", start: "invalid");
        var layout = ScheduleLayout.Build(new(2026, 9, 16), [a, teacher, b, c, adjacent, invalid], [Term], [Catalog()], false, new());
        Assert.Equal(2, layout.Blocks.Count); Assert.Equal(3, layout.Blocks[0].Entries.Count); Assert.Equal(2, layout.Blocks[0].Entries[0].Courses.Count);
        Assert.Single(layout.Unplaced); Assert.Equal(8, layout.StartHour); Assert.Equal(22, layout.EndHour);
    }
    [Fact] public void PreviewPreservesRealDateAndHidesWhenCourseAlreadyPresentInDifferentRoom()
    {
        var term = Term with { EndDate = "20261031" }; var previous = Course(day: "20260916");
        var layout = ScheduleLayout.Build(new(2026, 9, 23), [previous], [term], [Catalog()], true, new());
        var entry = Assert.Single(Assert.Single(layout.Blocks).Entries); Assert.True(entry.Preview); Assert.Equal("20260916", entry.Course.Day); Assert.Equal(new DateOnly(2026, 9, 23), entry.DisplayDate);
        layout = ScheduleLayout.Build(new(2026, 9, 23), [previous, previous with { Day = "20260923", Classroom = "B202" }], [term], [Catalog()], true, new());
        Assert.False(Assert.Single(Assert.Single(layout.Blocks).Entries).Preview);
    }
    [Fact] public async Task LargeSemesterLayoutCacheIgnoresProgressAndSignOnlyUpdates()
    {
        var h = new Harness(); h.School.WeekQuery = (_, d) => Task.FromResult(Week(d, Course())); await h.Model.InitializeAsync();
        var before = h.Model.WeekSchedule(); var count = h.School.WeekReads;
        h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([Course() with { Signed = true }], ""));
        await h.Model.CheckDayAsync(new(2026, 9, 16), true);
        Assert.Equal(count, h.School.WeekReads); Assert.Same(before, h.Model.WeekSchedule());
        var sample = Enumerable.Range(0, 140).SelectMany(d => Enumerable.Range(0, 6).Select(i => Course($"{d}-{i}", CourseTime.DayKey(new DateOnly(2026, 9, 1).AddDays(d)), $"{8 + i * 2}:00", $"{9 + i * 2}:00") with { CourseNumber = "CS" + i })).ToArray();
        var layout = ScheduleLayout.Build(new(2026, 12, 31), sample, [Term with { EndDate = "20270131" }], [], false, new());
        Assert.Equal(new DateOnly(2026, 12, 28), layout.Monday); Assert.Equal(42, layout.Blocks.Count);
    }
}
