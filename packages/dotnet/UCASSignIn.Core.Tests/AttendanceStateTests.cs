using System.Text.Json;
namespace UCASSignIn.Core.Tests;

public sealed class AttendanceStateTests
{
    static DateTimeOffset Now => TestData.Now;
    static AttendanceEvidence Success() => new AttendanceEvidence(AttendanceStatus.Unknown, AttendanceSource.Cache, Now)
        .Observe(AttendanceStatus.Signed, AttendanceSource.Submission, Now);
    [Fact] public void CorrectionNeedsTwoIndependentSameSourceNegativesWithoutWaiting()
    {
        var state = Success().Observe(AttendanceStatus.Unsigned, AttendanceSource.Daily, Now);
        Assert.Equal(AttendanceStatus.Signed, state.Status); Assert.True(state.PendingVerification);
        state = state.Observe(AttendanceStatus.Unsigned, AttendanceSource.Detail, Now);
        Assert.Equal(AttendanceStatus.Signed, state.Status);
        state = state.Observe(AttendanceStatus.Unsigned, AttendanceSource.Detail, Now);
        Assert.Equal(AttendanceStatus.Unsigned, state.Status); Assert.False(state.PendingVerification);
        Assert.Equal(Now, state.LastSuccessfulSignAt);
    }
    [Fact] public void PositiveAndUnknownInterruptNegativeConfirmation()
    {
        var state = Success().Observe(AttendanceStatus.Unsigned, AttendanceSource.Daily, Now.AddMinutes(3));
        state = state.Observe(AttendanceStatus.Unknown, AttendanceSource.Daily, Now.AddMinutes(4));
        Assert.Null(state.NegativeSource);
        state = state.Observe(AttendanceStatus.Unsigned, AttendanceSource.Daily, Now.AddMinutes(5));
        Assert.Equal(AttendanceStatus.Signed, state.Status);
        state = state.Observe(AttendanceStatus.Signed, AttendanceSource.Daily, Now.AddMinutes(6));
        Assert.False(state.PendingVerification); Assert.Null(state.NegativeSource);
    }
    [Theory] [InlineData("")] [InlineData(",\"signStatus\":null")] [InlineData(",\"signStatus\":true")] [InlineData(",\"signStatus\":\"2\"")]
    public void MissingOrInvalidStatusIsUnknown(string field)
    {
        using var json = JsonDocument.Parse("[{\"id\":\"1234567\"" + field + "}]");
        Assert.False(Assert.Single(ResponseParser.Courses(json.RootElement, "20260916")).SignStatusKnown);
    }
    [Fact] public void UnknownRevokesPreviouslyUnsignedPermission()
    {
        var state = new AttendanceEvidence(AttendanceStatus.Unsigned, AttendanceSource.Daily, Now)
            .Observe(AttendanceStatus.Unknown, AttendanceSource.Daily, Now.AddSeconds(1));
        Assert.Equal(AttendanceStatus.Unknown, state.Status);
    }
    [Fact] public void ReferencePolicyHasExactBoundaryAndRejectsFutureTimestamp()
    {
        Assert.True(CachePolicy.Fresh(Now, Now.AddDays(7).AddTicks(-1)));
        Assert.False(CachePolicy.Fresh(Now, Now.AddDays(7)));
        Assert.False(CachePolicy.Fresh(Now, Now.AddTicks(-1)));
    }
    sealed class Harness
    {
        public readonly FakeClock Clock = new(Now);
        public readonly MemoryScheduleData Data = new();
        public readonly MemoryAccounts Accounts = new() { Vault = new(1, [TestData.Account()], "a") };
        public readonly FakeSchool School = new();
        public readonly AccountCoordinator Model;
        public readonly Course Course = TestData.Course() with { CourseId = "course-1" };
        public readonly SchoolSemester Term = new("fall", "秋季", "20260914", "20260920", true);
        public Harness()
        {
            School.SemesterQuery = () => Task.FromResult<IReadOnlyList<SchoolSemester>>([Term]);
            School.Query = (_, d) => Task.FromResult(new CourseQueryResult(d == new DateOnly(2026, 9, 16) ? [Course] : [], ""));
            School.WeekQuery = (_, _) => Task.FromResult(new WeeklyScheduleResult([Course], Enumerable.Range(0, 7).Select(i => CourseTime.DayKey(new DateOnly(2026, 9, 14).AddDays(i))).ToArray()));
            Model = new(School, Accounts, Data, Data, new FakeReminders(), Clock) { IsForeground = true, ScheduleMode = ScheduleMode.Week };
        }
        public Course Display => Model.DisplayCourses(new(2026, 9, 16)).Single();
        public Task Refresh() => Model.RefreshAsync(new(2026, 9, 16));
        public CourseAttendanceSummary Summary(bool signed) => new(signed ? 1 : 0, signed ? 0 : 1,
            [new("row", "course-1", Course.Id, Course.Day, Course.BeginTime, Course.EndTime, signed)]);
    }
    [Fact] public async Task LaterWeekCannotUndoDailySuccessAndColdRestartRetainsEvidence()
    {
        var h = new Harness(); h.School.Query = (_, d) => Task.FromResult(new CourseQueryResult(d == new DateOnly(2026,9,16) ? [h.Course with { Signed = true }] : [], ""));
        await h.Model.InitializeAsync(); Assert.True(h.Display.Signed);
        await h.Model.RefreshScheduleAsync(); Assert.True(h.Display.Signed);
        h.School.Query = (_, _) => throw new IOException("offline");
        var restarted = new AccountCoordinator(h.School, h.Accounts, h.Data, h.Data, new FakeReminders(), h.Clock);
        await restarted.InitializeAsync();
        Assert.True(restarted.DisplayCourses(new(2026,9,16)).Single().Signed);
    }
    [Theory] [InlineData(true)] [InlineData(false)]
    public async Task ConflictWaitsForPageEntryAndNeverPolls(bool localSign)
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        if (localSign) await h.Model.SignAsync(h.Display, h.Model.Generation);
        else
        {
            h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([h.Course with { Signed = true }], ""));
            await h.Refresh();
            h.School.Query = (_, _) => Task.FromResult(new CourseQueryResult([h.Course], ""));
            await h.Refresh();
        }
        Assert.True(h.Display.Signed); Assert.Equal("已签到 · 待核验", h.Model.AttendanceLabel(h.Display));
        var reads = (h.School.Reads, h.School.AttendanceReads);
        foreach (var second in new[] { 5, 30, 120, 150, 3600 })
        {
            h.Clock.Now = Now.AddSeconds(second); await h.Model.TickAsync();
            Assert.True(h.Display.Signed);
            Assert.Equal(reads, (h.School.Reads, h.School.AttendanceReads));
        }
        // Only an explicit page entry or refresh can supply a correction.
        await h.Model.EnterDayAsync(new(2026, 9, 16));
        Assert.False(h.Display.Signed);
        Assert.Equal(localSign ? 1 : 0, h.School.Signs);
    }
    [Fact] public async Task DuplicateRowsInOneResponseCannotCountAsTwoConfirmations()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        await h.Model.SignAsync(h.Display, h.Model.Generation);
        var row = h.Summary(false).Records.Single();
        h.School.AttendanceQuery = _ => Task.FromResult(new CourseAttendanceSummary(0, 2, [row, row with { Id = "duplicate" }]));
        await h.Model.RefreshAttendanceAsync("course-1");
        Assert.True(h.Display.Signed);
        await h.Model.RefreshAttendanceAsync("course-1", true);
        Assert.False(h.Display.Signed);
    }
    [Fact] public async Task ManualSignDoesNotRepeatPageQueryAfterOneMinute()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        h.Clock.Now += TimeSpan.FromMinutes(2);
        var before = h.School.Reads;
        h.School.Sign = () =>
        {
            Assert.Equal(before, h.School.Reads);
            return Task.FromResult(new SignResult(SignOutcome.Signed, "成功"));
        };
        await h.Model.SignAsync(h.Display, h.Model.Generation);
        Assert.Equal(before + 1, h.School.Reads); // Only the single post-submit read.
        before = h.School.Reads;
        h.Clock.Now += TimeSpan.FromMinutes(2);
        await h.Model.SignAsync(h.Display, h.Model.Generation);
        Assert.Equal(before, h.School.Reads); Assert.Equal(1, h.School.Signs);
    }
    [Fact] public async Task RefreshJoiningPreSignDayWaitsForReplacementQuery()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        var oldRelease = new TaskCompletionSource<CourseQueryResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var newStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var newRelease = new TaskCompletionSource<CourseQueryResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.Query = (_, _) => oldRelease.Task;
        var old = h.Refresh();
        var signing = h.Model.SignAsync(h.Display, h.Model.Generation);
        Assert.True(h.Display.Signed);
        h.School.Query = (_, _) => { newStarted.TrySetResult(); return newRelease.Task; };
        var joined = h.Refresh();
        oldRelease.SetResult(new([h.Course], ""));
        await newStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(joined.IsCompleted);
        newRelease.SetResult(new([h.Course with { Signed = true }], ""));
        await Task.WhenAll(old, signing, joined);
        Assert.True(h.Display.Signed); Assert.Equal("已签到", h.Model.AttendanceLabel(h.Display));
    }
    [Fact] public async Task SchoolSuccessSurvivesCacheAndRecordWriteFailures()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        h.Data.FailCacheWrites = true;
        await h.Model.SignAsync(h.Display, h.Model.Generation);
        Assert.True(h.Display.Signed); Assert.Null(h.Model.SignInError);
        Assert.True(Assert.Single(h.Model.Records).Succeeded);
        await h.Model.SetPreferencesAsync(true, false); await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
    }
    [Fact] public async Task SuccessfulSignInvalidatesDiskDetailAndRejectsInFlightDetail()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        h.School.AttendanceQuery = _ => Task.FromResult(h.Summary(false));
        await h.Model.RefreshAttendanceAsync("course-1");
        var started = new TaskCompletionSource(); var release = new TaskCompletionSource<CourseAttendanceSummary>();
        h.School.AttendanceQuery = _ => { started.TrySetResult(); return release.Task; };
        var old = h.Model.RefreshAttendanceAsync("course-1", true); await started.Task;
        await h.Model.SignAsync(h.Display, h.Model.Generation);
        Assert.True(h.Model.IsAttendanceStale("course-1")); Assert.True(h.Display.Signed);
        var newStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var newRelease = new TaskCompletionSource<CourseAttendanceSummary>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.AttendanceQuery = _ => { newStarted.TrySetResult(); return newRelease.Task; };
        var before = h.School.AttendanceReads;
        release.SetResult(h.Summary(false)); await old;
        Assert.Equal(before, h.School.AttendanceReads); // Invalidation does not start a detached detail refresh.
        Assert.True(h.Model.IsAttendanceStale("course-1"));
        var joined = h.Model.RefreshAttendanceAsync("course-1");
        await newStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var alsoJoined = h.Model.RefreshAttendanceAsync("course-1", true);
        newRelease.SetResult(h.Summary(true)); await Task.WhenAll(joined, alsoJoined);
        Assert.Equal(before + 1, h.School.AttendanceReads); Assert.False(h.Model.IsAttendanceStale("course-1"));
        Assert.True(h.Model.AttendanceFor("course-1")!.Records.Single().Signed);
    }
    [Fact] public async Task ConcurrentPostSignDayReadersShareFailureWithoutAutomaticRetry()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        var release = new TaskCompletionSource<CourseQueryResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.Query = (_, _) => release.Task;
        var before = h.School.Reads;
        var signing = h.Model.SignAsync(h.Display, h.Model.Generation);
        Assert.True(h.Display.Signed);
        var joined = h.Refresh();
        release.SetException(new IOException("offline"));
        await Task.WhenAll(signing, joined).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(before + 1, h.School.Reads);
        Assert.True(h.Display.Signed);
    }
    [Fact] public async Task ConcurrentDetailReadersShareFailureWithoutAutomaticRetry()
    {
        var h = new Harness(); await h.Model.InitializeAsync();
        await h.Model.SignAsync(h.Display, h.Model.Generation);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<CourseAttendanceSummary>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.AttendanceQuery = _ => { started.TrySetResult(); return release.Task; };
        var first = h.Model.RefreshAttendanceAsync("course-1"); await started.Task;
        var second = h.Model.RefreshAttendanceAsync("course-1", true);
        var third = h.Model.RefreshAttendanceAsync("course-1");
        release.SetException(new IOException("offline"));
        await Task.WhenAll(first, second, third).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, h.School.AttendanceReads); Assert.True(h.Model.IsAttendanceStale("course-1"));
        Assert.True(h.Display.Signed);
    }
    [Fact] public async Task WeekNavigationAndTicksDoNotReadSelectedDayButDayEntryDoes()
    {
        var h = new Harness(); await h.Model.InitializeAsync(); var before = h.School.Reads;
        await h.Model.SelectDateAsync(new(2026,9,17)); await h.Model.EnterScheduleAsync(); await h.Model.TickAsync();
        Assert.Equal(before, h.School.Reads);
        h.Model.ScheduleMode = ScheduleMode.Day; await h.Model.EnterScheduleAsync();
        Assert.Equal(before + 1, h.School.Reads);
        await h.Model.EnterScheduleAsync(); Assert.Equal(before + 1, h.School.Reads);
        h.Clock.Now += TimeSpan.FromSeconds(31); await h.Model.TickAsync(); Assert.Equal(before + 1, h.School.Reads);
        await h.Model.EnterScheduleAsync(); Assert.Equal(before + 2, h.School.Reads);
    }
    [Fact] public async Task LegacyUnsignedCacheDoesNotGrantSignPermission()
    {
        var h = new Harness(); h.Data.Cache["a|20260916"] = new([h.Course], Now);
        h.School.Query = (_, _) => throw new IOException("offline"); h.School.WeekQuery = (_, _) => throw new IOException("offline");
        await h.Model.InitializeAsync(); Assert.Equal(AttendanceStatus.Unknown, h.Model.AttendanceStatusFor(h.Display));
        Assert.Equal("状态待同步", h.Model.AttendanceLabel(h.Display)); Assert.False(h.Model.CanSign(h.Display));
    }
    [Fact] public async Task CatalogAndDetailShareSevenDayCacheAndInFlightRequest()
    {
        var h = new Harness(); await h.Model.InitializeAsync(); var before = h.School.CatalogReads;
        await h.Model.RefreshCatalogAsync(); await h.Model.EnsureCatalogForDateAsync(new(2026,9,16));
        Assert.Equal(before, h.School.CatalogReads);
        h.Clock.Now += TimeSpan.FromDays(7);
        await Task.WhenAll(h.Model.RefreshCatalogAsync(), h.Model.EnsureCatalogForDateAsync(new(2026,9,16)));
        Assert.Equal(before + 1, h.School.CatalogReads);
    }
}
