namespace UCASSignIn.Core.Tests;

public sealed class AutoSignSingleControlTests
{
    static Course Course(string id = "1234567", string courseId = "course-1", string start = "08:30") =>
        TestData.Course(id) with { CourseId = courseId, CourseNumber = courseId == "course-1" ? "CS001" : "CS002", BeginTime = start };

    static (AccountCoordinator Model, MemoryData Data, FakeClock Clock, FakeSchool School, MemoryAccounts Accounts)
        Setup(DateTimeOffset now, AccountPreferences? preferences = null, params Course[] courses)
    {
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account() with { Settings = preferences }], "a") };
        var data = new MemoryData();
        var clock = new FakeClock(now);
        var values = courses.Length == 0 ? new[] { Course() } : courses;
        var school = new FakeSchool { Now = now, Query = (_, date) => Task.FromResult(new CourseQueryResult(
            values.Select(c => c with { Day = CourseTime.DayKey(date) }).ToArray(), "同步成功")) };
        var model = new AccountCoordinator(school, accounts, data, data, new FakeReminders(), clock) { IsForeground = true };
        return (model, data, clock, school, accounts);
    }

    [Fact]
    public async Task OneGlobalSwitchStartsInheritedCoursesWithoutAnotherPreference()
    {
        var h = Setup(TestData.Now.AddMinutes(-10));
        await h.Model.InitializeAsync();
        await h.Model.SetAutoSignSettingsAsync(running: true);
        Assert.True(h.Model.Preferences.AutoSignEnabled);
        Assert.True(h.Model.EffectiveAutoSign("course-1"));
        Assert.True(h.Model.NeedsAutoSignService);
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Single(h.Model.AutoSignHistory);
    }

    [Fact]
    public async Task StoredSplitStateEnablesFutureInheritedCoursesAndSkipsPastPlans()
    {
        var before = TestData.Now.AddHours(-1);
        var h = Setup(TestData.Now, new(AutoSignRunning: true, AutoSignRunningSince: before),
            Course(), Course("7654321", "course-2", "08:40"));
        await h.Model.InitializeAsync();
        Assert.True(h.Model.Preferences.AutoSignEnabled);
        Assert.Equal(before, h.Model.Preferences.AutoSignRunningSince);
        Assert.Equal(TestData.Now, h.Model.Preferences.AutoSignDefaultSince);
        var past = Assert.Single(h.Model.AutoSignPlans, p => p.Course.Day == "20260916" && p.Course.Id == "1234567");
        Assert.Equal(AutoSignStage.Skipped, past.Stage);
        Assert.False(past.IsParticipating);
        Assert.True(h.Model.EffectiveAutoSign("course-2"));
        await h.Model.TickAsync();
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(0, h.School.Signs);
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(5);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Equal("7654321", h.School.LastSignedCourse?.Id);
        Assert.True(h.Accounts.Vault.Accounts[0].Preferences.AutoSignEnabled);
    }

    [Fact]
    public async Task LegacyCourseOptInKeepsItsBoundaryWhileNewInheritanceStartsAtMigration()
    {
        var before = TestData.Now.AddHours(-1);
        var preferences = new AccountPreferences(Courses: new()
        {
            ["course-1"] = new(AutoSign: PreferenceOverride.Enabled, AutoSignEnabledSince: before,
                AutoSignRule: new(MissedAction: AutoSignMissedAction.TenMinuteGrace))
        });
        var h = Setup(TestData.Now.AddMinutes(-3), preferences, Course(), Course("7654321", "course-2"));
        await h.Model.InitializeAsync();
        Assert.True(h.Model.Preferences.AutoSignIsRunning);
        Assert.True(h.Model.Preferences.AutoSignEnabled);
        Assert.Null(h.Model.Preferences.AutoSignRunningSince);
        Assert.Equal(before, h.Model.CoursePreferencesFor("course-1").AutoSignEnabledSince);
        Assert.Equal(h.Clock.Now, h.Model.Preferences.AutoSignDefaultSince);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
        Assert.Equal("1234567", h.School.LastSignedCourse?.Id);
        Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(AutoSignStage.Skipped, Assert.Single(h.Model.AutoSignPlans,
            p => p.Course.Day == "20260916" && p.Course.Id == "7654321").Stage);
    }

    [Fact]
    public async Task UnifiedSwitchPreservesExplicitCourseAndOccurrenceExclusions()
    {
        var inherited = Course();
        var excluded = Course("7654321", "course-2");
        var preferences = new AccountPreferences(AutoSignRunning: true, Courses: new()
        {
            ["course-2"] = new(AutoSign: PreferenceOverride.Disabled)
        }, AutoSignOccurrences: new() { [AutoSignPlanner.Key("a", inherited)] = new(Enabled: false) });
        var h = Setup(TestData.Now.AddMinutes(-10), preferences, inherited, excluded);
        await h.Model.InitializeAsync();
        Assert.False(h.Model.EffectiveAutoSign("course-2"));
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.False(h.Model.Preferences.AutoSignOccurrences[AutoSignPlanner.Key("a", inherited)].Enabled);
        Assert.Equal(PreferenceOverride.Disabled, h.Model.CoursePreferencesFor("course-2").AutoSign);
    }

    [Fact]
    public async Task MigrationAndGlobalSwitchRemainScopedToTheActiveAccount()
    {
        var h = Setup(TestData.Now.AddMinutes(-10), new(AutoSignRunning: true));
        var other = TestData.Account("b") with { Settings = new(AutoSignRunning: false, Courses: new()
        {
            ["course-1"] = new(AutoSign: PreferenceOverride.Enabled)
        }) };
        h.Accounts.Vault = new(1, [h.Accounts.Vault.Accounts[0], other], "a");
        await h.Model.InitializeAsync();
        var migratedAt = h.Model.Preferences.AutoSignDefaultSince;
        Assert.Equal(other.Preferences, h.Accounts.Vault.Accounts.Single(a => a.Id == "b").Preferences);
        await h.Model.SwitchAsync("b");
        Assert.False(h.Model.Preferences.AutoSignIsRunning);
        Assert.False(h.Model.NeedsAutoSignService);
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        await h.Model.SwitchAsync("a");
        Assert.Equal(migratedAt, h.Model.Preferences.AutoSignDefaultSince);
        await h.Model.TickAsync();
        Assert.Equal(1, h.School.Signs);
    }

    [Fact]
    public async Task FailedMigrationSaveKeepsSafeBoundaryAndBlocksAutomaticSubmissions()
    {
        var h = Setup(TestData.Now.AddMinutes(-10), new(AutoSignRunning: true));
        h.Accounts.FailSave = true;
        await h.Model.InitializeAsync();
        Assert.True(h.Model.Preferences.AutoSignEnabled);
        Assert.Equal(h.Clock.Now, h.Model.Preferences.AutoSignDefaultSince);
        Assert.False(h.Accounts.Vault.Accounts[0].Preferences.AutoSignEnabled);
        Assert.Contains("设置升级保存失败", h.Model.AutoSignError);
        h.Clock.Now = h.School.Now = TestData.Now.AddMinutes(-5);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        Assert.Empty(h.Model.AutoSignHistory);
    }

    [Theory]
    [InlineData(null)]
    [InlineData(false)]
    public async Task CoherentOffPreferencesDoNotRequireAnUpgradeWrite(bool? running)
    {
        var h = Setup(TestData.Now.AddMinutes(-10), new(AutoSignRunning: running));
        h.Accounts.FailSave = true;
        await h.Model.InitializeAsync();
        Assert.False(h.Model.Preferences.AutoSignIsRunning);
        Assert.Null(h.Model.AutoSignError);
        Assert.Equal(running, h.Model.Preferences.AutoSignRunning);
        Assert.Empty(h.Model.AutoSignHistory);
    }

    [Fact]
    public async Task ExplicitStoredOffWinsOverLegacyParticipationAndOverrides()
    {
        var course = Course();
        var h = Setup(TestData.Now.AddMinutes(-5), new(AutoSignEnabled: true, AutoSignRunning: false,
            Courses: new() { ["course-1"] = new(AutoSign: PreferenceOverride.Enabled) },
            AutoSignOccurrences: new() { [AutoSignPlanner.Key("a", course)] = new(Enabled: true) }));
        await h.Model.InitializeAsync();
        await h.Model.TickAsync();
        Assert.False(h.Model.Preferences.AutoSignEnabled);
        Assert.False(h.Model.Preferences.AutoSignIsRunning);
        Assert.False(h.Model.NeedsAutoSignService);
        Assert.Equal(0, h.School.Signs);
        Assert.Empty(h.Model.AutoSignHistory);
        Assert.Equal(PreferenceOverride.Enabled, h.Model.Preferences.Courses["course-1"].AutoSign);
        Assert.True(h.Model.Preferences.AutoSignOccurrences[AutoSignPlanner.Key("a", course)].Enabled);
    }

    [Fact]
    public async Task NormalizationPreservesSubmittedEvidenceAndExistingCourseActivation()
    {
        var at = TestData.Now.AddMinutes(-5);
        var course = Course();
        var h = Setup(at.AddMinutes(2), new(AutoSignRunning: true, Courses: new()
        {
            ["course-1"] = new(AutoSign: PreferenceOverride.Enabled, AutoSignEnabledSince: at)
        }));
        var key = AutoSignPlanner.Key("a", course);
        var execution = AutoSignExecution.New(key, at).Begin(course, at) with { Submissions = 1, LastSubmissionAt = at };
        execution = execution.Transition(AutoSignStage.Verifying, at, "提交结果未知", at.AddMinutes(2));
        h.Data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { [key] = execution });
        await h.Model.InitializeAsync();
        var restored = Assert.Single(h.Model.AutoSignHistory);
        Assert.Equal(execution.Submissions, restored.Submissions);
        Assert.Equal(execution.LastSubmissionAt, restored.LastSubmissionAt);
        Assert.Equal(execution.Events, restored.Events);
        await h.Model.TickAsync();
        Assert.Equal(0, h.School.Signs);
        Assert.Equal(0, Assert.Single(h.Model.AutoSignHistory).NegativeReads);
        Assert.Equal(AutoSignStage.NeedsAttention, Assert.Single(h.Model.AutoSignHistory).Stage);
        Assert.Null(Assert.Single(h.Model.AutoSignHistory).LastSchoolSubmissionAt);
    }
}
