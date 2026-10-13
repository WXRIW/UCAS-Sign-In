namespace UCASSignIn.Core.Tests;

public sealed class AutoSignSafetyTests
{
    static (AccountCoordinator Model, FakeSchool School, FakeClock Clock, MemoryData Data, MemoryAccounts Accounts, FakeReminders Reminders)
        Setup(DateTimeOffset deviceNow, DateTimeOffset? schoolNow = null, int max = 3, bool on = true, bool remember = false)
    {
        var preferences = new AccountPreferences(AutoSignEnabled: on, AutoSignRunning: on,
            AutoSignRule: new(MaxSubmissions: max), AutoSignRunningSince: on ? deviceNow.AddHours(-1) : null);
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account(remember: remember) with { Settings = preferences }], "a") };
        var data = new MemoryData();
        var school = new FakeSchool { Now = schoolNow ?? deviceNow, Query = (_, date) => Task.FromResult(new CourseQueryResult(
            [TestData.Course() with { Day = CourseTime.DayKey(date), CourseId = "course-1", CourseNumber = "CS001" }], "同步成功")) };
        var clock = new FakeClock(deviceNow);
        var reminders = new FakeReminders();
        return (new AccountCoordinator(school, accounts, data, data, reminders, clock) { IsForeground = true }, school, clock, data, accounts, reminders);
    }

    [Fact]
    public async Task LoginRecoveryPreservesCourseExclusionSavedWhilePermissionWasPending()
    {
        var h = Setup(TestData.Now.AddMinutes(-5), remember: true);
        await h.Model.InitializeAsync();
        var permission = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var loginStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var login = new TaskCompletionSource<SchoolSession>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.Reminders.Permission = () => permission.Task;
        var settings = h.Model.SetCoursePreferencesAsync("course-1", new(AutoSign: PreferenceOverride.Disabled, Reminders: PreferenceOverride.Enabled));
        var expired = true;
        h.School.Query = (_, date) =>
        {
            if (expired) { expired = false; throw new SchoolException("LOGIN_EXPIRED", "expired"); }
            return Task.FromResult(new CourseQueryResult([TestData.Course() with { Day = CourseTime.DayKey(date), CourseId = "course-1", CourseNumber = "CS001" }], "ok"));
        };
        h.School.Login = _ => { loginStarted.TrySetResult(); return login.Task; };
        var refresh = h.Model.RefreshAsync();
        await loginStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        permission.SetResult(true);
        await settings;
        login.SetResult(TestData.Session() with { SessionId = "new-session" });
        await refresh;
        Assert.Equal(PreferenceOverride.Disabled, h.Model.CoursePreferencesFor("course-1").AutoSign);
        Assert.Equal(PreferenceOverride.Disabled, h.Accounts.Vault.Accounts[0].Preferences.Courses["course-1"].AutoSign);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
    }

    [Fact]
    public async Task SwitchingToExpiredRememberedAccountCanRecoverWithoutHoldingActivationMutationGate()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        h.Accounts.Vault = new(1, [h.Accounts.Vault.Accounts[0], TestData.Account("b", remember: true)], "a");
        await h.Model.InitializeAsync();
        var expired = true;
        var query = h.School.Query;
        h.School.Query = (session, date) =>
        {
            if (session.StudentNo == "b" && expired) { expired = false; throw new SchoolException("LOGIN_EXPIRED", "expired"); }
            return query(session, date);
        };
        await h.Model.SwitchAsync("b").WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("b", h.Model.ActiveAccount?.Id);
        Assert.False(h.Model.ActiveAccount!.RequiresLogin);
        Assert.Equal(1, h.School.Logins);
    }

    [Fact]
    public async Task LastUnknownSubmissionStillQueriesAndCanConfirmSignedAtTheCap()
    {
        var h = Setup(TestData.Now.AddMinutes(-5), max: 1);
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "unknown"));
        await h.Model.InitializeAsync();
        await h.Model.TickAsync();
        h.Clock.Now = h.School.Now = h.Clock.Now.AddSeconds(30);
        var query = h.School.Query;
        h.School.Query = async (session, date) =>
        {
            var result = await query(session, date);
            return result with { Courses = result.Courses.Select(c => c with { Signed = true }).ToArray() };
        };
        var before = h.School.Reads;
        await h.Model.TickAsync();
        Assert.True(h.School.Reads > before);
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(AutoSignStage.Signed, Assert.Single(h.Model.AutoSignHistory).Stage);
    }

    [Fact]
    public async Task AttentionAfterCapContinuesReadOnlyUntilClassEndsAndReconcilesLaterPositiveRefresh()
    {
        var h = Setup(TestData.Now.AddMinutes(-5), max: 1);
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "unknown"));
        await h.Model.InitializeAsync();
        await h.Model.TickAsync();
        h.Clock.Now = h.School.Now = h.Clock.Now.AddSeconds(30);
        await h.Model.TickAsync();
        Assert.Equal(AutoSignStage.NeedsAttention, Assert.Single(h.Model.AutoSignHistory).Stage);
        h.Clock.Now = h.School.Now = TestData.Course().End!.Value.AddMinutes(1);
        var before = h.School.Reads;
        await h.Model.TickAsync();
        Assert.Equal(before, h.School.Reads);
        h.School.Query = (_, date) => Task.FromResult(new CourseQueryResult([TestData.Course() with
            { Day = CourseTime.DayKey(date), Signed = true, CourseId = "course-1", CourseNumber = "CS001" }], "signed"));
        await h.Model.RefreshAsync();
        Assert.Equal(AutoSignStage.Signed, Assert.Single(h.Model.AutoSignHistory).Stage);
        Assert.Equal(1, h.School.Signs);
    }

    [Theory]
    [InlineData(-2, false)]
    [InlineData(2, false)]
    [InlineData(-2, true)]
    [InlineData(2, true)]
    public async Task SchoolTimeControlsInitialDueWhenDeviceIsAheadOrBehind(int skewMinutes, bool enableNow)
    {
        var at = TestData.Now.AddMinutes(-5);
        var h = Setup(at.AddMinutes(skewMinutes), at, on: !enableNow);
        await h.Model.InitializeAsync();
        if (enableNow) await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        var execution = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(at, execution.LastSchoolSubmissionAt);
        Assert.Equal(at.AddMinutes(skewMinutes), execution.LastSubmissionAt);
    }

    [Fact]
    public async Task ClockCalibrationDefersBeforeSchoolDueWithoutCreatingHistoryOrPollingIdle()
    {
        var h = Setup(TestData.Now.AddMinutes(-4), TestData.Now.AddMinutes(-6));
        await h.Model.InitializeAsync();
        await h.Model.TickAsync();
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(0, h.Data.AutoSignWrites);
        Assert.Equal(TestData.Now.AddMinutes(-3), h.Model.NextAutoSignWakeAt);
        var reads = h.School.ClockReads;
        h.Clock.Now = h.Clock.Now.AddSeconds(30); h.School.Now = h.School.Now.AddSeconds(30);
        await h.Model.TickAsync();
        Assert.Equal(reads, h.School.ClockReads);
        h.Clock.Now = h.Clock.Now.AddSeconds(30); h.School.Now = h.School.Now.AddSeconds(30);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
    }

    [Fact]
    public async Task FailedSchoolClockBackoffUsesElapsedTimeAfterWallClockMovesBackward()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        var failed = false;
        h.School.SchoolClock = () =>
        {
            if (!failed) { failed = true; throw new IOException("first clock read failed"); }
            return Task.FromResult(h.School.Now);
        };
        await h.Model.InitializeAsync();
        await h.Model.TickAsync();
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(1, h.School.ClockReads);
        h.Clock.ShiftDeviceClock(TimeSpan.FromMinutes(-1));
        Assert.Equal(h.Clock.Now.AddSeconds(30), h.Model.NextAutoSignWakeAt);
        h.Clock.Now = h.Clock.Now.AddSeconds(29); h.School.Now = h.School.Now.AddSeconds(29);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.ClockReads);
        h.Clock.Now = h.Clock.Now.AddSeconds(1); h.School.Now = h.School.Now.AddSeconds(1);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
    }

    [Fact]
    public async Task WallClockJumpCannotMoveRetryDueOrThirtySecondSchoolVerificationQuorum()
    {
        var at = TestData.Now.AddMinutes(-5);
        var h = Setup(at);
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "unknown"));
        await h.Model.InitializeAsync(); await h.Model.TickAsync();
        h.Clock.Now = h.Clock.Now.AddMinutes(1); h.School.Now = h.School.Now.AddMinutes(1);
        h.Clock.ShiftDeviceClock(TimeSpan.FromMinutes(2));
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(0, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        Assert.Equal(at.AddMinutes(4), h.Model.NextAutoSignWakeAt);
        h.Clock.Now = h.Clock.Now.AddMinutes(1); h.School.Now = h.School.Now.AddMinutes(1);
        await h.Model.TickAsync();
        Assert.Equal(1, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        h.Clock.ShiftDeviceClock(TimeSpan.FromMinutes(2));
        h.Clock.Now = h.Clock.Now.AddSeconds(10); h.School.Now = h.School.Now.AddSeconds(10);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(1, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        h.Clock.Now = h.Clock.Now.AddSeconds(20); h.School.Now = h.School.Now.AddSeconds(20);
        await h.Model.TickAsync();
        Assert.Equal(2, h.School.Signs);
    }

    [Fact]
    public async Task FailedVerificationAfterWallClockMovesBackwardCannotReuseACompletedOldQuery()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "unknown"));
        await h.Model.InitializeAsync(); await h.Model.TickAsync();
        h.Clock.Now = h.School.Now = h.Clock.Now.AddMinutes(2);
        await h.Model.TickAsync();
        Assert.Equal(1, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        h.Clock.ShiftDeviceClock(TimeSpan.FromMinutes(-1));
        h.Clock.Now = h.Clock.Now.AddSeconds(30); h.School.Now = h.School.Now.AddSeconds(30);
        var query = h.School.Query;
        h.School.Query = (_, _) => throw new IOException("failed second query");
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(1, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        h.School.Query = query;
        h.Clock.Now = h.Clock.Now.AddSeconds(30); h.School.Now = h.School.Now.AddSeconds(30);
        await h.Model.TickAsync();
        Assert.Equal(2, h.School.Signs);
    }

    [Fact]
    public async Task RestartKeepsFrozenSchoolSubmissionAfterDeviceClockJump()
    {
        var at = TestData.Now.AddMinutes(-5);
        var h = Setup(at);
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "unknown"));
        await h.Model.InitializeAsync(); await h.Model.TickAsync();
        h.Clock.Now = h.Clock.Now.AddMinutes(1); h.School.Now = h.School.Now.AddMinutes(1);
        h.Clock.ShiftDeviceClock(TimeSpan.FromMinutes(2));
        var model = new AccountCoordinator(h.School, h.Accounts, h.Data, h.Data, h.Reminders, h.Clock) { IsForeground = true };
        await model.InitializeAsync(); await model.TickAsync();
        Assert.Equal(at, Assert.Single(model.AutoSignHistory).LastSchoolSubmissionAt);
        Assert.Equal(0, Assert.Single(model.AutoSignHistory).NegativeReads);
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(at.AddMinutes(4), model.NextAutoSignWakeAt);
        h.Clock.Now = h.Clock.Now.AddMinutes(1); h.School.Now = h.School.Now.AddMinutes(1);
        await model.TickAsync();
        Assert.Equal(1, Assert.Single(model.AutoSignHistory).NegativeReads);
        h.Clock.Now = h.Clock.Now.AddSeconds(30); h.School.Now = h.School.Now.AddSeconds(30);
        await model.TickAsync();
        Assert.Equal(2, h.School.Signs);
    }

    [Theory]
    [InlineData(-60)]
    [InlineData(60)]
    public async Task LegacySubmissionWithoutSchoolReceiptCanOnlyVerifyDespiteOffsetOrOldQuorum(int offsetMinutes)
    {
        var schoolNow = offsetMinutes > 0 ? TestData.Now.AddHours(1) : TestData.Now;
        var deviceNow = schoolNow.AddMinutes(-offsetMinutes);
        var h = Setup(deviceNow, schoolNow);
        var course = TestData.Course();
        var last = TestData.Now.AddMinutes(-2);
        var key = AutoSignPlanner.Key("a", course);
        var legacy = AutoSignExecution.New(key, last).Begin(course, last) with
        {
            Submissions = 1, LastSubmissionAt = last, NegativeReads = 2, FirstNegativeAt = last.AddSeconds(30),
            Stage = AutoSignStage.Verifying
        };
        h.Data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { [key] = legacy });
        await h.Model.InitializeAsync();
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        var execution = Assert.Single(h.Model.AutoSignHistory);
        Assert.Null(execution.LastSchoolSubmissionAt);
        Assert.Equal(legacy.Submissions, execution.Submissions);
        Assert.Equal(legacy.NegativeReads, execution.NegativeReads);
        Assert.Equal(legacy.LastSubmissionAt, execution.LastSubmissionAt);
        Assert.Equal(AutoSignStage.NeedsAttention, execution.Stage);
        Assert.Contains("旧记录", execution.Message);
        var reloaded = new AccountCoordinator(h.School, h.Accounts, h.Data, h.Data, h.Reminders, h.Clock) { IsForeground = true };
        await reloaded.InitializeAsync();
        h.Clock.Now = h.Clock.Now.AddMinutes(2); h.School.Now = h.School.Now.AddMinutes(2);
        await reloaded.TickAsync();
        Assert.Equal(0, h.School.Signs);
        Assert.Null(Assert.Single(reloaded.AutoSignHistory).LastSchoolSubmissionAt);
    }

    [Theory]
    [InlineData("submission")]
    [InlineData("negative")]
    [InlineData("verification")]
    public async Task InconsistentNewSchoolEvidenceFieldsAreRejected(string invalid)
    {
        var execution = AutoSignExecution.New("key", TestData.Now) with
        {
            LastSchoolSubmissionAt = invalid == "submission" ? TestData.Now : null,
            FirstSchoolNegativeAt = invalid == "negative" ? TestData.Now : null,
            LastSchoolVerificationAttemptAt = invalid == "verification" ? TestData.Now : null
        };
        Assert.Throws<IOException>(() => new AutoSignLedger(AutoSignLedger.CurrentVersion, "a", new() { ["key"] = execution }).Validate("a"));
    }

    [Fact]
    public async Task ClockJumpCannotMoveActivationBeforeAnAlreadyPastPlan()
    {
        var h = Setup(TestData.Now.AddMinutes(-4), on: false);
        await h.Model.InitializeAsync();
        await h.Model.SetAutoSignSettingsAsync(running: true, rule: new(MissedAction: AutoSignMissedAction.UntilClassEnds));
        h.Clock.ShiftDeviceClock(TimeSpan.FromMinutes(2));
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(TestData.Now.AddMinutes(-4), h.Model.Preferences.AutoSignRunningSince);
    }

    [Fact]
    public async Task SuccessfulExcludedManualOccurrenceStaysCompletedWithoutInventingAutoHistory()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        await h.Model.InitializeAsync();
        await h.Model.SetCoursePreferencesAsync("course-1", new(AutoSign: PreferenceOverride.Disabled));
        await h.Model.SignAsync(h.Model.Courses[0], h.Model.Generation);
        await h.Model.RefreshAsync();
        Assert.Equal(AttendanceStatus.Unsigned, h.Model.AttendanceStatusFor(h.Model.Courses[0]));
        h.Clock.Now = h.School.Now = TestData.Now;
        await h.Model.SetCoursePreferencesAsync("course-1", new(AutoSign: PreferenceOverride.Enabled));
        var key = AutoSignPlanner.Key("a", h.Model.Courses[0]);
        await h.Model.SetAutoSignSettingsAsync(occurrences: new() { [key] = new(At: TestData.Now.AddMinutes(1)) });
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(1);
        await h.Model.TickAsync();
        await h.Model.SignAsync(h.Model.Courses[0], h.Model.Generation, automatically: true);
        Assert.Equal(1, h.School.Signs);
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(AutoSignStage.Signed, Assert.Single(h.Model.AutoSignPlans, p => p.Key == key).Stage);
    }

    [Fact]
    public async Task PauseEndIsADeviceWakeBoundaryWithoutPollingSchoolDuringPause()
    {
        var h = Setup(new(2026, 9, 16, 23, 55, 0, CourseTime.ShanghaiOffset));
        await h.Model.InitializeAsync();
        var resume = new DateTimeOffset(2026, 9, 17, 0, 0, 0, CourseTime.ShanghaiOffset);
        await h.Model.SetAutoSignSettingsAsync(pauseUntil: resume);
        Assert.Equal(resume, h.Model.NextAutoSignWakeAt);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.ClockReads);
        Assert.Empty(h.Model.AutoSignHistory);
    }

    [Fact]
    public async Task PausingDuringRetryClockReadStopsTheFollowingAutomaticVerification()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "unknown"));
        await h.Model.InitializeAsync(); await h.Model.TickAsync();
        h.Clock.Now = h.School.Now = h.Clock.Now.AddMinutes(2);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<DateTimeOffset>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.SchoolClock = () => { entered.TrySetResult(); return release.Task; };
        var reads = h.School.Reads;
        var tick = h.Model.TickAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var resume = TestData.Now.AddDays(1);
        await h.Model.SetAutoSignSettingsAsync(pauseUntil: resume);
        release.SetResult(h.School.Now);
        await tick;
        Assert.Equal(reads, h.School.Reads);
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(0, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        Assert.Equal(resume, h.Model.NextAutoSignWakeAt);
    }
}
