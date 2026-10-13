namespace UCASSignIn.Core.Tests;

public sealed class AutoSignExecutionTests
{
    static (AccountCoordinator Model, MemoryData Data, FakeClock Clock, FakeSchool School, MemoryAccounts Accounts) Setup(DateTimeOffset now)
    {
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account()], "a") };
        var data = new MemoryData();
        var clock = new FakeClock(now);
        var school = new FakeSchool { Now = now,
            Query = (_, date) => Task.FromResult(new CourseQueryResult([TestData.Course() with
                { Day = CourseTime.DayKey(date), CourseId = "course-1", CourseNumber = "CS001" }], "同步成功")) };
        var model = new AccountCoordinator(school, accounts, data, data, new FakeReminders(), clock) { IsForeground = true };
        return (model, data, clock, school, accounts);
    }

    [Fact]
    public async Task MissedDefaultPlanDoesNotSubmit()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        h.Clock.Now = h.School.Now = h.Clock.Now.AddMinutes(4);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        var missed = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(AutoSignStage.Missed, missed.Stage);
        await h.Model.TickAsync();
        Assert.Equal(missed.Events.Count, Assert.Single(h.Model.AutoSignHistory).Events.Count);
    }

    [Fact]
    public async Task RetryRequiresTwoPostSubmissionNegativesThirtySecondsApart()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        h.Clock.Now = h.School.Now = h.Clock.Now.AddMinutes(2);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(1, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        h.Clock.Now = h.School.Now = h.Clock.Now.AddSeconds(29);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        h.Clock.Now = h.School.Now = h.Clock.Now.AddSeconds(1);
        await h.Model.TickAsync();
        Assert.Equal(2, h.School.Signs);
        Assert.Equal(2, Assert.Single(h.Model.AutoSignHistory).Submissions);
    }

    [Fact]
    public async Task FailedSecondVerificationCannotReuseFirstNegativeRead()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        h.Clock.Now = h.School.Now = h.Clock.Now.AddMinutes(2);
        await h.Model.TickAsync();
        Assert.Equal(1, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        h.School.Query = (_, _) => throw new IOException("网络中断");
        h.Clock.Now = h.School.Now = h.Clock.Now.AddSeconds(30);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Equal(1, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
    }

    [Fact]
    public async Task StoreFailurePreventsSubmission()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        h.Data.FailCacheWrites = true;
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        Assert.Contains("自动签到已暂停", h.Model.AutoSignError);
    }

    [Fact]
    public async Task RuleChangeRecordsUpdatedPlanWithoutResettingSubmissions()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        Assert.Equal(1, Assert.Single(h.Model.AutoSignHistory).Submissions);
        await h.Model.SetAutoSignSettingsAsync(rule: new AutoSignPolicy(RetryMinutes: 5));
        var execution = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(1, execution.Submissions);
        Assert.Contains(execution.Events, e => e.Message.StartsWith("计划已更新"));
    }

    [Fact]
    public async Task NeverEnabledRefreshAndConfigurationDoNotCreateExecutions()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        await h.Model.RefreshAsync(CourseTime.Today(h.Clock));
        await h.Model.SetPreferencesAsync(false, true, confirmBeforeSign: true);
        await h.Model.SetAutoSignSettingsAsync(rule: new AutoSignPolicy(RetryMinutes: 5));
        _ = h.Model.AutoSignPlans;
        await h.Model.TickAsync();
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Empty(h.Data.AutoSign);
        Assert.Equal(0, h.Data.AutoSignWrites);
        Assert.Equal("已关闭", h.Model.AutoSignSettingsStatus);
    }

    [Fact]
    public async Task CompatibilityPreferenceSetterControlsTheSameGlobalSwitch()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        Assert.True(h.Model.Preferences.AutoSignEnabled);
        Assert.True(h.Model.Preferences.AutoSignIsRunning);
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Single(h.Model.AutoSignHistory);
        await h.Model.SetPreferencesAsync(false, false);
        Assert.False(h.Model.Preferences.AutoSignIsRunning);
        Assert.False(h.Model.Preferences.AutoSignEnabled);
    }

    [Fact]
    public async Task FuturePlansDoNotOfferYesterdayOccurrences()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        Assert.NotEmpty(h.Model.AutoSignPlans);
        Assert.All(h.Model.AutoSignPlans, p => Assert.True(p.Course.Start >= CourseTime.Parse("20260916", "00:00")));
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(0, h.Data.AutoSignWrites);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RestoringDisabledOccurrenceUsesNewActivationBoundary(bool removeOverride)
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        var key = Assert.Single(h.Model.AutoSignPlans, x => x.Course.Day == "20260916").Key;
        await h.Model.SetAutoSignSettingsAsync(occurrences: new() { [key] = new(Enabled: false) });
        h.Clock.Now = h.School.Now = TestData.Now;
        await h.Model.SetAutoSignSettingsAsync(occurrences: removeOverride ? new() : new() { [key] = new(Policy: new()) });
        Assert.Equal(TestData.Now, h.Model.Preferences.AutoSignOccurrences[key].EnabledSince);
        var plan = Assert.Single(h.Model.AutoSignPlans, x => x.Key == key);
        Assert.Equal("账户默认", plan.Source);
        Assert.False(plan.IsParticipating);
        await h.Model.TickAsync();
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(0, h.School.Signs);
    }

    [Fact]
    public async Task ClearingAbsentPauseDoesNotMoveActivationTime()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.SetAutoSignSettingsAsync(clearPause: true);
        Assert.Equal(TestData.Now.AddMinutes(-10), h.Model.Preferences.AutoSignRunningSince);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
    }

    [Fact]
    public async Task GlobalOffBlocksCourseAndOccurrenceOverrides()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        var key = Assert.Single(h.Model.AutoSignPlans, x => x.Course.Day == "20260916").Key;
        await h.Model.SetCoursePreferencesAsync(h.Model.PreferenceId(h.Model.Courses[0])!, new(AutoSign: PreferenceOverride.Enabled));
        await h.Model.SetAutoSignSettingsAsync(running: false, occurrences: new() { [key] = new(Enabled: true) });
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(0, h.Data.AutoSignWrites);
        Assert.Equal("已关闭", h.Model.AutoSignSettingsStatus);
    }

    [Fact]
    public async Task OccurrenceCanEnableAnExplicitlyExcludedCourse()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        var key = Assert.Single(h.Model.AutoSignPlans, x => x.Course.Day == "20260916").Key;
        await h.Model.SetCoursePreferencesAsync(h.Model.PreferenceId(h.Model.Courses[0])!, new(AutoSign: PreferenceOverride.Disabled));
        await h.Model.SetAutoSignSettingsAsync(running: true, occurrences: new() { [key] = new(Enabled: true) });
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        var execution = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(TestData.Now.AddMinutes(-5), execution.StartedAt);
        Assert.Equal("示例课程", execution.CourseName);
        Assert.Equal(TestData.Now, execution.ClassStartAt);
    }

    [Fact]
    public async Task ReenableSkipsPastPlansAndAllowsFuturePlans()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.SetAutoSignSettingsAsync(running: false);
        h.Clock.Now = h.School.Now = TestData.Now;
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(0, h.School.Signs);
        Assert.Equal(AutoSignStage.Skipped, Assert.Single(h.Model.AutoSignPlans, x => x.Course.Day == "20260916").Stage);
        h.Clock.Now = h.School.Now = TestData.Now.AddDays(1).AddMinutes(-5);
        await h.Model.EnterDayAsync(CourseTime.Today(h.Clock));
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
    }

    [Fact]
    public async Task ReenablePreservesUnknownSubmissionEvidenceAcrossRestart()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        var original = Assert.Single(h.Model.AutoSignHistory);
        await h.Model.SetAutoSignSettingsAsync(running: false);
        h.Clock.Now = h.School.Now = TestData.Now;
        await h.Model.SetAutoSignSettingsAsync(running: true);
        var relaunched = new AccountCoordinator(h.School, h.Accounts, h.Data, h.Data, new FakeReminders(), h.Clock) { IsForeground = true };
        await relaunched.InitializeAsync();
        await relaunched.TickAsync();
        var preserved = Assert.Single(relaunched.AutoSignHistory);
        Assert.Equal(original.Submissions, preserved.Submissions);
        Assert.Equal(original.LastSubmissionAt, preserved.LastSubmissionAt);
        Assert.Equal(AutoSignStage.NeedsAttention, preserved.Stage);
        Assert.Equal(1, h.School.Signs);
    }

    [Fact]
    public async Task ManualBeforeDueKeepsOnlyHiddenCancellationState()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.SignAsync(h.Model.Courses[0], h.Model.Generation);
        Assert.Single(h.Model.Records);
        Assert.Empty(h.Model.AutoSignHistory);
        var tombstone = Assert.Single(h.Data.AutoSign["a"].Executions).Value;
        Assert.False(tombstone.HasExecutionActivity);
        Assert.Contains(tombstone.Events, e => e.Kind == AutoSignEventKind.ManualTakeover);
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Empty(h.Model.AutoSignHistory);
    }

    [Fact]
    public async Task ManualTakeoverAfterReenableAppendsToExistingRealProcess()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        await h.Model.SetAutoSignSettingsAsync(running: false);
        h.Clock.Now = h.School.Now = TestData.Now;
        await h.Model.SetAutoSignSettingsAsync(running: true);
        Assert.False(Assert.Single(h.Model.AutoSignPlans, x => x.Course.Day == "20260916").IsParticipating);
        await h.Model.SignAsync(h.Model.Courses[0], h.Model.Generation);
        var execution = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(1, execution.Submissions);
        Assert.Equal(AutoSignEventKind.ManualTakeover, execution.Events.Last().Kind);
        Assert.Equal(2, h.School.Signs);
    }

    [Fact]
    public async Task DismissingUnknownResultDoesNotResetSubmissionEvidence()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        var original = Assert.Single(h.Model.AutoSignHistory);
        h.Model.AcknowledgeSignInError(h.Model.SignInError!.Id);
        var preserved = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(original.Submissions, preserved.Submissions);
        Assert.Equal(original.LastSubmissionAt, preserved.LastSubmissionAt);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ManualTakeoverDuringRetryVerificationCannotBeOverwritten(bool lateReadIsSigned)
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        h.Model.AcknowledgeSignInError(h.Model.SignInError!.Id);
        h.Clock.Now = h.School.Now = h.Clock.Now.AddMinutes(2);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<CourseQueryResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.Query = (_, _) => { entered.TrySetResult(); return release.Task; };
        var tick = h.Model.TickAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var manual = h.Model.SignAsync(h.Model.Courses[0], h.Model.Generation);
        Assert.Equal(AutoSignStage.Skipped, Assert.Single(h.Model.AutoSignHistory).Stage);
        release.SetResult(new([h.Model.Courses[0] with { Signed = lateReadIsSigned }], "同步成功"));
        await Task.WhenAll(tick, manual);
        var execution = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(AutoSignStage.Skipped, execution.Stage);
        Assert.Contains(execution.Events, e => e.Kind == AutoSignEventKind.ManualTakeover);
        Assert.Equal(0, execution.NegativeReads);
        await h.Model.TickAsync();
        Assert.Equal(2, h.School.Signs);
    }

    [Fact]
    public async Task MovingPlanLaterDuringClockReadPreventsEarlySubmission()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<DateTimeOffset>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.SchoolClock = () => { entered.TrySetResult(); return release.Task; };
        var tick = h.Model.TickAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var key = Assert.Single(h.Model.AutoSignPlans, x => x.Course.Day == "20260916").Key;
        await h.Model.SetAutoSignSettingsAsync(occurrences: new() { [key] = new(At: TestData.Now) });
        release.SetResult(h.Clock.Now);
        await tick;
        Assert.Equal(0, h.School.Signs);
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Null(h.Model.SignInError);
        Assert.False(h.Model.IsBusy);
    }

    [Fact]
    public async Task IncreasingRetryIntervalDuringClockReadPreservesEvidenceAndDefersSubmission()
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        h.School.Sign = () => Task.FromResult(new SignResult(SignOutcome.Unknown, "结果未知"));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        h.Model.AcknowledgeSignInError(h.Model.SignInError!.Id);
        h.Clock.Now = h.School.Now = h.Clock.Now.AddMinutes(2);
        await h.Model.TickAsync();
        h.Clock.Now = h.School.Now = h.Clock.Now.AddSeconds(30);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<DateTimeOffset>(TaskCreationOptions.RunContinuationsAsynchronously);
        h.School.SchoolClock = () => { entered.TrySetResult(); return release.Task; };
        var tick = h.Model.TickAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await h.Model.SetAutoSignSettingsAsync(rule: new(RetryMinutes: 5));
        release.SetResult(h.Clock.Now);
        await tick;
        var execution = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(1, execution.Submissions);
        Assert.Equal(1, execution.NegativeReads);
        Assert.Equal(TestData.Now.AddMinutes(-5), execution.LastSubmissionAt);
        Assert.Equal(1, h.School.Signs);
        Assert.Null(h.Model.SignInError);
        h.School.SchoolClock = null;
        h.Clock.Now = h.School.Now = TestData.Now;
        await h.Model.TickAsync();
        Assert.Equal(2, h.School.Signs);
    }

    [Fact]
    public async Task CorruptLedgerStaysScopedAndPreventsLaterSubmission()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        h.Data.FailAutoSignReads = true;
        await h.Model.InitializeAsync();
        Assert.Equal("已关闭", h.Model.AutoSignSettingsStatus);
        Assert.DoesNotContain("自动签到", h.Model.Message ?? "");
        Assert.Contains("自动签到已暂停", h.Model.AutoSignError);
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal("已暂停", h.Model.AutoSignSettingsStatus);
        Assert.Equal(0, h.School.Signs);
    }

    [Theory]
    [InlineData(-1, 0, false, false)]
    [InlineData(4, 0, true, false)]
    [InlineData(1, 0, false, false)]
    [InlineData(0, 0, true, false)]
    [InlineData(1, 1, true, false)]
    [InlineData(1, 3, true, true)]
    public async Task InvalidLedgerCountersAndMissingEvidenceBlockAutomaticExecution(int submissions, int negatives, bool last, bool first)
    {
        var h = Setup(TestData.Now.AddMinutes(-5));
        var course = TestData.Course();
        var key = AutoSignPlanner.Key("a", course);
        var invalid = AutoSignExecution.New(key, h.Clock.Now) with
        {
            Submissions = submissions, NegativeReads = negatives,
            LastSubmissionAt = last ? h.Clock.Now : null, FirstNegativeAt = first ? h.Clock.Now : null
        };
        h.Data.AutoSign["a"] = new(1, "a", new() { [key] = invalid });
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        await h.Model.TickAsync();
        Assert.Contains("自动签到已暂停", h.Model.AutoSignError);
        Assert.Equal(0, h.School.Signs);
        Assert.Equal(0, h.Data.AutoSignWrites);
        Assert.Equal(1, h.Data.AutoSign["a"].Version);
    }

    [Fact]
    public async Task CourseReenableAndOrdinarySettingsPreserveActivationBoundary()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        await h.Model.SetPreferencesAsync(true, false);
        await h.Model.SetAutoSignSettingsAsync(running: true);
        var courseId = h.Model.PreferenceId(h.Model.Courses[0])!;
        await h.Model.SetCoursePreferencesAsync(courseId, new(AutoSign: PreferenceOverride.Disabled));
        h.Clock.Now = h.School.Now = TestData.Now;
        await h.Model.SetCoursePreferencesAsync(courseId, new(AutoSign: PreferenceOverride.Enabled, AutoSignRule: new(RetryMinutes: 5)));
        await h.Model.SetPreferencesAsync(true, true, confirmBeforeSign: true);
        var preferences = h.Model.CoursePreferencesFor(courseId);
        Assert.Equal(TestData.Now, preferences.AutoSignEnabledSince);
        Assert.Equal(5, preferences.AutoSignRule?.RetryMinutes);
        Assert.Equal(TestData.Now.AddMinutes(-10), h.Model.Preferences.AutoSignRunningSince);
        await h.Model.TickAsync();
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(0, h.School.Signs);
    }
}
