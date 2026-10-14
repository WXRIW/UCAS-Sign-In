using System.Text.Json;

namespace UCASSignIn.Core.Tests;

public sealed class HistoryRetentionTests
{
    static AttendanceRecord Operation(string id, DateTimeOffset at) => new(id, at, "签到结果", true, id, id);
    static AutoSignExecution Execution(string key, DateTimeOffset at, AutoSignStage stage = AutoSignStage.Signed)
        => AutoSignExecution.New(key, at).Begin(TestData.Course(), at).Transition(stage, at, "执行结果");
    static AccountCoordinator Model(MemoryAccounts accounts, ICourseStore data, IRecordStore records,
        FakeClock? clock = null, FakeSchool? school = null) => new(school ?? new(), accounts, data, records,
            new FakeReminders(), clock ?? new(TestData.Now));
    static MemoryAccounts Accounts(params string[] ids) => new()
        { Vault = new(1, ids.Select(x => TestData.Account(x)).ToList(), ids.FirstOrDefault()) };

    [Fact]
    public void DefaultsAreUnlimitedAndRoundTripWithoutImplicitCaps()
    {
        var settings = JsonSerializer.Deserialize<HistoryRetentionSettings>("{}")!;
        Assert.Equal(new(), settings.Operations);
        Assert.Equal(new(), settings.Automatic);
        var values = Enumerable.Range(0, 151).Select(i => Operation(i.ToString(), TestData.Now.AddDays(-200 - i))).ToArray();
        Assert.Equal(151, settings.Operations.Retain(values, TestData.Now, x => x.Date, x => x.CourseName).Count);
        Assert.Equal(settings, JsonSerializer.Deserialize<HistoryRetentionSettings>(JsonSerializer.Serialize(settings)));
        Assert.True(JsonSerializer.Deserialize<AutoSignExecution>(JsonSerializer.Serialize(Execution("old", TestData.Now)))!.HasExecutionActivity);
    }

    [Fact]
    public void CountAndAgeUseInclusiveCutoffAndStableOrderWithoutCollapsingIdenticalRows()
    {
        var at = TestData.Now;
        var values = new[] { Operation("z", at.AddDays(-1)), Operation("b", at), Operation("a", at),
            Operation("old", at.AddDays(-1).AddTicks(-1)), Operation("future", at.AddDays(1)) };
        var byAge = new HistoryRetentionPolicy(MaxAgeDays: 1).Retain(values, at, x => x.Date, x => x.CourseName);
        Assert.Equal(new[] { "future", "a", "b", "z" }, byAge.Select(x => x.CourseName));
        var both = new HistoryRetentionPolicy(2, 1).Retain(values, at, x => x.Date, x => x.CourseName);
        Assert.Equal(new[] { "future", "a" }, both.Select(x => x.CourseName));
        var identical = Enumerable.Repeat(Operation("same", at), 10);
        Assert.Equal(2, new HistoryRetentionPolicy(2).Retain(identical, at, x => x.Date, x => x.CourseName).Count);
    }

    [Theory]
    [InlineData(0, null)]
    [InlineData(-1, null)]
    [InlineData(null, 0)]
    [InlineData(null, -1)]
    public void NonpositiveLimitsAreRejected(int? count, int? days)
        => Assert.Throws<ArgumentOutOfRangeException>(() => new HistoryRetentionPolicy(count, days).Validate());

    [Theory]
    [InlineData("{\"MaxCount\":true}")]
    [InlineData("{\"MaxCount\":1.5}")]
    [InlineData("{\"MaxAgeDays\":2147483648}")]
    public void JsonRequiresRepresentableIntegers(string json)
        => Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<HistoryRetentionPolicy>(json));

    [Fact]
    public void IntMaxValueAgeAndCountDoNotOverflowAndNearMinimumDatesAreSafe()
    {
        var values = new[] { Operation("old", DateTimeOffset.MinValue), Operation("now", TestData.Now) };
        var policy = new HistoryRetentionPolicy(int.MaxValue, int.MaxValue);
        Assert.Equal(2, policy.Retain(values, TestData.Now, x => x.Date, x => x.CourseName).Count);
        Assert.Equal(2, policy.Retain(values, DateTimeOffset.MinValue, x => x.Date, x => x.CourseName).Count);
    }

    [Fact]
    public void LegacyExecutionWithoutEventsUsesItsVerificationTime()
    {
        var legacy = AutoSignExecution.New("legacy", TestData.Now) with { Stage = AutoSignStage.Signed,
            FirstNegativeAt = TestData.Now.AddDays(-1), NegativeReads = 1 };
        Assert.Equal(TestData.Now.AddDays(-1), legacy.HistoryDate);
        var ledger = new AutoSignLedger(AutoSignLedger.CurrentVersion, "a", new() { [legacy.Key] = legacy });
        Assert.False(ledger.RetainHistory(new(MaxAgeDays: 1), TestData.Now).Executions[legacy.Key].HistoryDiscarded);
        var verified = legacy with { LastVerificationAttemptAt = TestData.Now };
        Assert.Equal(TestData.Now, verified.HistoryDate);
    }

    [Fact]
    public void AutomaticCleanupKeepsExecutionEvidenceAndProtectsUnfinishedEntries()
    {
        var at = TestData.Now.AddDays(-200);
        var terminal = Execution("terminal", at) with { Submissions = 2, LastSubmissionAt = at,
            LastSchoolSubmissionAt = at, FirstNegativeAt = at, FirstSchoolNegativeAt = at,
            NegativeReads = 2, LastVerificationAttemptAt = at, LastSchoolVerificationAttemptAt = at,
            LastSubmissionQuerySequence = 7, LastNegativeQuerySequence = 9 };
        var active = Enum.GetValues<AutoSignStage>().Where(x => x is not (AutoSignStage.Signed or AutoSignStage.Missed or AutoSignStage.Skipped))
            .Select(x => Execution(x.ToString(), at, x)).ToArray();
        var newest = Execution("newest", TestData.Now);
        var ledger = new AutoSignLedger(AutoSignLedger.CurrentVersion, "a", active.Append(terminal).Append(newest).ToDictionary(x => x.Key));
        var cleaned = ledger.RetainHistory(new(1, 1), TestData.Now);
        var evidence = cleaned.Executions[terminal.Key];
        Assert.True(evidence.HistoryDiscarded);
        Assert.Empty(evidence.Events);
        Assert.Null(evidence.CourseName);
        Assert.Equal("", evidence.Message);
        Assert.Equal(terminal with { HistoryDiscarded = true, Events = evidence.Events, Message = "", CourseName = null,
            ClassStartAt = null, ClassEndAt = null, NotificationMode = null }, evidence);
        Assert.True(evidence.HasExecutionActivity);
        Assert.All(active, x => Assert.Same(x, cleaned.Executions[x.Key]));
        Assert.Same(newest, cleaned.Executions[newest.Key]);
        cleaned.Validate("a");
        Assert.True(cleaned.Cleaned().Executions.ContainsKey("terminal"));
        Assert.True(cleaned.RetainHistory(new(), TestData.Now).Executions["terminal"].HistoryDiscarded);
    }

    [Fact]
    public async Task LegacyDefaultKeepsMoreThan100OldRowsThroughFileSaveSignAndRestart()
    {
        var root = Path.Combine(Path.GetTempPath(), "ucas-retention-default-" + Guid.NewGuid());
        try
        {
            var store = new FileDataStore(root);
            var operations = Enumerable.Range(0, 125).Select(i => Operation(i.ToString(), TestData.Now.AddDays(-120 - i))).ToArray();
            var executions = Enumerable.Range(0, 125).Select(i => Execution("a|old-" + i, TestData.Now.AddDays(-120 - i))).ToDictionary(x => x.Key);
            executions.Remove("a|old-0");
            var currentKey = AutoSignPlanner.Key("a", TestData.Course());
            executions[currentKey] = Execution(currentKey, TestData.Now.AddDays(-120), AutoSignStage.Verifying);
            await store.SaveAsync("a", operations);
            await store.SaveAutoSignAsync(new(AutoSignLedger.CurrentVersion, "a", executions));
            var accounts = Accounts("a");
            var model = Model(accounts, store, store);
            await model.InitializeAsync();
            Assert.True(model.HistoryRetention.IsUnlimited);
            Assert.Equal(125, model.Records.Count);
            Assert.Equal(125, model.AutoSignHistory.Count);
            await model.SignAsync(model.Courses.First(x => x.Day == CourseTime.DayKey(model.SelectedDate)), model.Generation);
            Assert.Equal(126, model.Records.Count);
            await model.SetAutoSignSettingsAsync(running: true); // Exercises the execution-log save path too.
            var restartedStore = new FileDataStore(root);
            var restarted = Model(accounts, restartedStore, restartedStore);
            await restarted.InitializeAsync();
            Assert.Equal(126, restarted.Records.Count);
            Assert.Equal(125, restarted.AutoSignHistory.Count);
            Assert.False(File.Exists(Path.Combine(root, "history-retention.json")));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact]
    public async Task ApplicationSettingCleansEachAccountIndependentlyAndUnlimitedDoesNotResurrect()
    {
        var data = new MemoryData();
        foreach (var id in new[] { "a", "b" })
        {
            data.Records[id] = Enumerable.Range(0, 6).Select(i => Operation(id + i, TestData.Now.AddDays(-i))).ToList();
            var entries = Enumerable.Range(0, 6).Select(i => Execution(id + "|" + i, TestData.Now.AddDays(-i))).ToDictionary(x => x.Key);
            entries[id + "|active"] = Execution(id + "|active", TestData.Now.AddDays(-200), AutoSignStage.Verifying);
            data.AutoSign[id] = new(AutoSignLedger.CurrentVersion, id, entries);
        }
        var accounts = Accounts("a", "b");
        var model = Model(accounts, data, data);
        await model.InitializeAsync();
        var limited = new HistoryRetentionSettings(new(2, 3), new(2, 3));
        await model.SetHistoryRetentionAsync(limited);
        Assert.Equal(limited, data.HistoryRetention);
        Assert.Equal(2, model.Records.Count);
        Assert.Equal(3, model.AutoSignHistory.Count); // Two selected rows plus an unfinished execution.
        foreach (var id in new[] { "a", "b" })
        {
            Assert.Equal(2, data.Records[id].Count);
            Assert.Equal(4, data.AutoSign[id].Executions.Values.Count(x => x.HistoryDiscarded));
            Assert.Equal(7, data.AutoSign[id].Executions.Count);
        }
        await model.SwitchAsync("b");
        Assert.Equal(limited, model.HistoryRetention);
        Assert.Equal(2, model.Records.Count);
        await model.SetHistoryRetentionAsync(new());
        var restarted = Model(accounts, data, data);
        await restarted.InitializeAsync();
        Assert.True(restarted.HistoryRetention.IsUnlimited);
        Assert.Equal(2, restarted.Records.Count);
        Assert.Equal(3, restarted.AutoSignHistory.Count);
    }

    [Fact]
    public async Task FiniteSettingsLoadBeforeActivationAndTickExpiresActiveAndInactiveHistory()
    {
        var data = new MemoryData { HistoryRetention = new(new(MaxAgeDays: 1), new(MaxAgeDays: 1)) };
        foreach (var id in new[] { "a", "b" })
        {
            data.Records[id] = [Operation("boundary", TestData.Now.AddDays(-1)), Operation("old", TestData.Now.AddDays(-2))];
            data.AutoSign[id] = new(AutoSignLedger.CurrentVersion, id, new()
                { [id + "|boundary"] = Execution(id + "|boundary", TestData.Now.AddDays(-1)),
                  [id + "|old"] = Execution(id + "|old", TestData.Now.AddDays(-2)) });
        }
        var clock = new FakeClock(TestData.Now);
        var model = Model(Accounts("a", "b"), data, data, clock);
        await model.InitializeAsync();
        Assert.Single(model.Records);
        Assert.Single(model.AutoSignHistory);
        Assert.Single(data.Records["b"]);
        clock.Now = clock.Now.AddHours(2);
        model.IsForeground = true;
        await model.TickAsync();
        Assert.Empty(model.Records);
        Assert.Empty(model.AutoSignHistory);
        Assert.Empty(data.Records["b"]);
        Assert.All(data.AutoSign.Values.SelectMany(x => x.Executions.Values), x => Assert.True(x.HistoryDiscarded));
    }

    [Fact]
    public async Task SettingsWriteFailureAndInvalidValuesNeverDeleteHistory()
    {
        var data = new MemoryData { FailHistoryRetentionWrites = true };
        data.Records["a"] = [Operation("one", TestData.Now), Operation("two", TestData.Now.AddDays(-2))];
        data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new()
            { ["old"] = Execution("old", TestData.Now.AddDays(-2)) });
        var model = Model(Accounts("a"), data, data);
        await model.InitializeAsync();
        await Assert.ThrowsAsync<IOException>(() => model.SetHistoryRetentionAsync(new(new(1), new(MaxAgeDays: 1))));
        Assert.True(model.HistoryRetention.IsUnlimited);
        Assert.True(data.HistoryRetention.IsUnlimited);
        Assert.Equal(2, model.Records.Count);
        Assert.False(data.AutoSign["a"].Executions["old"].HistoryDiscarded);
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => model.SetHistoryRetentionAsync(new(new(0), new())));
        Assert.Equal(0, data.HistoryRetentionWrites);
    }

    [Fact]
    public async Task CleanupWriteFailurePreservesVisibleDataAndRetriesSavedPolicy()
    {
        var data = new MemoryData();
        data.Records["a"] = [Operation("one", TestData.Now), Operation("two", TestData.Now.AddDays(-2))];
        var model = Model(Accounts("a"), data, data);
        await model.InitializeAsync();
        data.FailCacheWrites = true;
        var setting = new HistoryRetentionSettings(new(1), new());
        var error = await Assert.ThrowsAsync<IOException>(() => model.SetHistoryRetentionAsync(setting));
        Assert.Contains("设置已保存", error.Message);
        Assert.Equal(setting, model.HistoryRetention);
        Assert.Equal(2, model.Records.Count);
        Assert.Equal(2, data.Records["a"].Count);
        Assert.False(model.IsBusy);
        data.FailCacheWrites = false;
        model.IsForeground = true;
        await model.TickAsync();
        Assert.Single(model.Records);
        Assert.Single(data.Records["a"]);
    }

    [Fact]
    public async Task AutomaticCleanupFailureDoesNotHideUnpersistedRows()
    {
        var data = new MemoryData();
        data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new()
            { ["old"] = Execution("old", TestData.Now.AddDays(-2)) });
        var model = Model(Accounts("a"), data, data);
        await model.InitializeAsync();
        data.FailCacheWrites = true;
        await Assert.ThrowsAsync<IOException>(() => model.SetHistoryRetentionAsync(new(new(), new(MaxAgeDays: 1))));
        Assert.Single(model.AutoSignHistory);
        Assert.False(data.AutoSign["a"].Executions["old"].HistoryDiscarded);
    }

    [Fact]
    public async Task DemoDoesNotPersistSettingsOrCleanRealHistories()
    {
        var data = new MemoryData { HistoryRetention = new(new(MaxAgeDays: 1), new(MaxAgeDays: 1)) };
        data.Records["a"] = [Operation("old", TestData.Now.AddDays(-200))];
        data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { ["old"] = Execution("old", TestData.Now.AddDays(-200)) });
        var model = Model(Accounts("a"), data, data);
        await model.InitializeDemoAsync();
        model.IsForeground = true;
        await model.TickAsync();
        await Assert.ThrowsAsync<InvalidOperationException>(() => model.SetHistoryRetentionAsync(new()));
        Assert.Single(data.Records["a"]);
        Assert.False(data.AutoSign["a"].Executions["old"].HistoryDiscarded);
        Assert.Equal(0, data.HistoryRetentionWrites);
    }

    [Fact]
    public async Task FileSettingsPersistApplicationWideAndCorruptionIsNeverOverwritten()
    {
        var root = Path.Combine(Path.GetTempPath(), "ucas-retention-settings-" + Guid.NewGuid());
        try
        {
            var store = new FileDataStore(root);
            Assert.True((await store.LoadHistoryRetentionAsync()).IsUnlimited);
            var settings = new HistoryRetentionSettings(new(333, 444), new(555, 666));
            await store.SaveHistoryRetentionAsync(settings);
            await store.RemoveAsync("a");
            Assert.Equal(settings, await new FileDataStore(root).LoadHistoryRetentionAsync());
            var path = Path.Combine(root, "history-retention.json");
            File.WriteAllText(path, "{damaged");
            await Assert.ThrowsAsync<JsonException>(() => store.SaveHistoryRetentionAsync(new()));
            Assert.Equal("{damaged", File.ReadAllText(path));
            var model = Model(Accounts("a"), store, store);
            await Assert.ThrowsAsync<JsonException>(() => model.InitializeAsync());
            Assert.Equal("{damaged", File.ReadAllText(path));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact]
    public async Task CleaningSuccessfulExecutionCannotCauseAnotherSubmissionAfterRestart()
    {
        var data = new MemoryData();
        var course = TestData.Course();
        var key = AutoSignPlanner.Key("a", course);
        var signed = Execution(key, TestData.Now.AddDays(-2)) with { Submissions = 1,
            LastSubmissionAt = TestData.Now.AddDays(-2), LastSchoolSubmissionAt = TestData.Now.AddDays(-2) };
        data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { [key] = signed });
        var accounts = Accounts("a");
        var clock = new FakeClock(TestData.Now.AddMinutes(-5));
        var school = new FakeSchool { Now = clock.Now };
        var model = Model(accounts, data, data, clock, school);
        await model.InitializeAsync();
        await model.SetHistoryRetentionAsync(new(new(), new(MaxAgeDays: 1)));
        await model.SetAutoSignSettingsAsync(running: true);
        Assert.Empty(model.AutoSignHistory);
        var restarted = Model(accounts, data, data, clock, school);
        await restarted.InitializeAsync();
        restarted.IsForeground = true;
        await restarted.TickAsync();
        Assert.Equal(0, school.Signs);
        Assert.Equal(1, data.AutoSign["a"].Executions[key].Submissions);
        Assert.Equal(AutoSignStage.Signed, data.AutoSign["a"].Executions[key].Stage);
        Assert.Empty(restarted.AutoSignHistory);
    }

    sealed class PausingData : MemoryData, IAutoSignStore
    {
        public Func<string, Task>? BeforeAutoSignLoad;
        public Func<AutoSignLedger, Task>? BeforeAutoSignSave;
        async Task<AutoSignLedger?> IAutoSignStore.LoadAutoSignAsync(string accountId, CancellationToken ct)
        {
            if (BeforeAutoSignLoad is { } pause) await pause(accountId);
            return await LoadAutoSignAsync(accountId, ct);
        }
        async Task IAutoSignStore.SaveAutoSignAsync(AutoSignLedger ledger, CancellationToken ct)
        {
            if (BeforeAutoSignSave is { } pause) await pause(ledger);
            await SaveAutoSignAsync(ledger, ct);
        }
    }

    [Fact]
    public async Task PendingCleanupCannotOverwriteNewlyVerifiedExecutionEvidence()
    {
        var data = new PausingData();
        var old = Execution("a|old", TestData.Now.AddDays(-200));
        var key = AutoSignPlanner.Key("a", TestData.Course());
        var verifying = Execution(key, TestData.Now, AutoSignStage.Verifying) with
            { Submissions = 1, LastSubmissionAt = TestData.Now, LastSchoolSubmissionAt = TestData.Now };
        data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { [old.Key] = old, [key] = verifying });
        var school = new FakeSchool();
        var model = Model(Accounts("a"), data, data, school: school);
        await model.InitializeAsync();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var blocked = false;
        data.BeforeAutoSignSave = async ledger =>
        {
            if (blocked || !ledger.Executions[old.Key].HistoryDiscarded) return;
            blocked = true;
            entered.SetResult();
            await release.Task;
        };
        var cleanup = model.SetHistoryRetentionAsync(new(new(), new(MaxAgeDays: 1)));
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        school.Query = (_, date) => Task.FromResult(new CourseQueryResult(
            [TestData.Course() with { Day = CourseTime.DayKey(date), Signed = true }], "已签到"));
        var refresh = model.RefreshAsync();
        try
        {
            // Reconciliation updates the live execution before waiting for the shared save gate.
            Assert.Equal(AutoSignStage.Signed, Assert.Single(model.AutoSignHistory, x => x.Key == key).Stage);
            Assert.False(refresh.IsCompleted);
        }
        finally { release.TrySetResult(); }
        await Task.WhenAll(cleanup, refresh).WaitAsync(TimeSpan.FromSeconds(5));
        var persisted = data.AutoSign["a"].Executions[key];
        Assert.Equal(AutoSignStage.Signed, persisted.Stage);
        Assert.Equal(1, persisted.Submissions);
        Assert.Equal(verifying.LastSchoolSubmissionAt, persisted.LastSchoolSubmissionAt);
        Assert.True(data.AutoSign["a"].Executions[old.Key].HistoryDiscarded);
        Assert.Equal(AutoSignStage.Signed, Assert.Single(model.AutoSignHistory).Stage);
        var restarted = Model(Accounts("a"), data, data);
        await restarted.InitializeAsync();
        Assert.Equal(AutoSignStage.Signed, Assert.Single(restarted.AutoSignHistory).Stage);
    }

    [Fact]
    public async Task ActivationCleanupPreventsEnteringDemoDuringAnInactiveAccountRead()
    {
        var data = new PausingData { HistoryRetention = new(new(), new(MaxAgeDays: 1)) };
        foreach (var id in new[] { "a", "b" })
            data.AutoSign[id] = new(AutoSignLedger.CurrentVersion, id,
                new() { [id + "|old"] = Execution(id + "|old", TestData.Now.AddDays(-200)) });
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        data.BeforeAutoSignLoad = async id =>
        {
            if (id != "b") return;
            entered.TrySetResult();
            await release.Task;
        };
        var model = Model(Accounts("a", "b"), data, data);
        var initialization = model.InitializeAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            Assert.True(model.IsBusy);
            await model.EnterDemoAsync();
            Assert.False(model.IsDemo);
        }
        finally { release.TrySetResult(); }
        await initialization.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(model.IsBusy);
        Assert.All(data.AutoSign.Values.SelectMany(x => x.Executions.Values), x => Assert.True(x.HistoryDiscarded));
    }

    [Fact]
    public async Task TwoResultsInOneTickBothNotifyWhenOnlyOneHistoryRowIsRetained()
    {
        var now = TestData.Now.AddMinutes(-5);
        var clock = new FakeClock(now);
        var school = new FakeSchool { Now = now, Query = (_, date) => Task.FromResult(new CourseQueryResult(
            [TestData.Course("1234567") with { Day = CourseTime.DayKey(date) },
             TestData.Course("7654321") with { Day = CourseTime.DayKey(date) }], "")) };
        var data = new MemoryData();
        var model = Model(Accounts("a"), data, data, clock, school);
        await model.InitializeAsync();
        await model.SetHistoryRetentionAsync(new(new(), new(1)));
        await model.SetAutoSignSettingsAsync(running: true, rule: new(Notification: AutoSignNotification.All));
        Assert.Empty(model.ConsumeAutoSignResults());
        model.IsForeground = true;
        await model.TickAsync();
        Assert.Equal(2, school.Signs);
        Assert.Single(model.AutoSignHistory);
        Assert.Single(data.AutoSign["a"].Executions.Values, x => x.HistoryDiscarded);
        var results = model.ConsumeAutoSignResults();
        Assert.Equal(2, results.Count);
        Assert.All(results, x => Assert.True(x.Succeeded));
        Assert.Equal(2, results.Select(x => x.Key).Distinct().Count());
        Assert.Empty(model.ConsumeAutoSignResults());
    }

    [Fact]
    public async Task RefreshResultSurvivesCleanupAndIsConsumedOnceWithoutReplayingOldHistory()
    {
        var data = new MemoryData();
        var key = AutoSignPlanner.Key("a", TestData.Course());
        var active = Execution(key, TestData.Now, AutoSignStage.Verifying) with { NotificationMode = AutoSignNotification.All,
            Submissions = 1, LastSubmissionAt = TestData.Now, LastSchoolSubmissionAt = TestData.Now };
        data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { [key] = active });
        var clock = new FakeClock(TestData.Now);
        var school = new FakeSchool();
        var accounts = Accounts("a", "b");
        var model = Model(accounts, data, data, clock, school);
        await model.InitializeAsync();
        Assert.Empty(model.ConsumeAutoSignResults());
        await model.SetAutoSignSettingsAsync(rule: new(Notification: AutoSignNotification.All));
        school.Query = (_, date) => Task.FromResult(new CourseQueryResult(
            [TestData.Course() with { Day = CourseTime.DayKey(date), Signed = true }], ""));
        await model.RefreshAsync();
        clock.Now = clock.Now.AddDays(2);
        await model.SetHistoryRetentionAsync(new(new(), new(MaxAgeDays: 1)));
        Assert.Empty(model.AutoSignHistory);
        var result = Assert.Single(model.ConsumeAutoSignResults());
        Assert.Equal(key, result.Key);
        Assert.True(result.Succeeded);
        Assert.Equal("学校确认已签到", result.Message);
        Assert.Empty(model.ConsumeAutoSignResults());
        var restarted = Model(accounts, data, data, clock, school);
        await restarted.InitializeAsync();
        Assert.Empty(restarted.ConsumeAutoSignResults());
    }

    [Fact]
    public async Task NotificationQueueHonorsModesRequiresSuccessfulPersistenceAndClearsOnSwitch()
    {
        foreach (var mode in Enum.GetValues<AutoSignNotification>())
        {
            var data = new MemoryData();
            var course = TestData.Course();
            var key = AutoSignPlanner.Key("a", course);
            data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { [key] =
                Execution(key, TestData.Now, AutoSignStage.Verifying) with { NotificationMode = mode } });
            var school = new FakeSchool();
            var model = Model(Accounts("a", "b"), data, data, school: school);
            await model.InitializeAsync();
            await model.SetAutoSignSettingsAsync(rule: new(Notification: mode));
            school.Query = (_, date) => Task.FromResult(new CourseQueryResult(
                [course with { Day = CourseTime.DayKey(date), Signed = true }], ""));
            await model.RefreshAsync();
            Assert.Equal(mode == AutoSignNotification.All ? 1 : 0, model.ConsumeAutoSignResults().Count);
        }
        var failing = new MemoryData();
        var failedKey = AutoSignPlanner.Key("a", TestData.Course());
        failing.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { [failedKey] =
            Execution(failedKey, TestData.Now, AutoSignStage.Verifying) with { NotificationMode = AutoSignNotification.All } });
        var failedSchool = new FakeSchool();
        var failureAccounts = Accounts("a", "b");
        var failedModel = Model(failureAccounts, failing, failing, school: failedSchool);
        await failedModel.InitializeAsync();
        await failedModel.SetAutoSignSettingsAsync(rule: new(Notification: AutoSignNotification.All));
        failedSchool.Query = (_, date) => Task.FromResult(new CourseQueryResult(
            [TestData.Course() with { Day = CourseTime.DayKey(date), Signed = true }], ""));
        failing.FailCacheWrites = true;
        await failedModel.RefreshAsync();
        Assert.Empty(failedModel.ConsumeAutoSignResults());
        failing.FailCacheWrites = false;
        // A newly restored pending execution can generate a fresh result, but never leak to another account.
        var modelForSwitch = Model(failureAccounts, failing, failing, school: failedSchool);
        await modelForSwitch.InitializeAsync();
        await modelForSwitch.SwitchAsync("b");
        Assert.Empty(modelForSwitch.ConsumeAutoSignResults());
    }

    [Fact]
    public async Task NotificationUsesCurrentPlanPreferenceWhenItChangesDuringResultPersistence()
    {
        var data = new PausingData();
        var key = AutoSignPlanner.Key("a", TestData.Course());
        data.AutoSign["a"] = new(AutoSignLedger.CurrentVersion, "a", new() { [key] =
            Execution(key, TestData.Now, AutoSignStage.Verifying) with { NotificationMode = AutoSignNotification.All } });
        var school = new FakeSchool();
        var model = Model(Accounts("a"), data, data, school: school);
        await model.InitializeAsync();
        await model.SetAutoSignSettingsAsync(rule: new(Notification: AutoSignNotification.All));
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var blocked = false;
        data.BeforeAutoSignSave = async ledger =>
        {
            if (blocked || ledger.Executions[key].Stage != AutoSignStage.Signed) return;
            blocked = true;
            entered.SetResult();
            await release.Task;
        };
        school.Query = (_, date) => Task.FromResult(new CourseQueryResult(
            [TestData.Course() with { Day = CourseTime.DayKey(date), Signed = true }], ""));
        var refresh = model.RefreshAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var change = model.SetAutoSignSettingsAsync(rule: new(Notification: AutoSignNotification.None));
        try { Assert.Equal(AutoSignNotification.None, model.Preferences.AutoSignRule.Notification); }
        finally { release.TrySetResult(); }
        await Task.WhenAll(refresh, change).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Empty(model.ConsumeAutoSignResults());
        Assert.Equal(AutoSignStage.Signed, data.AutoSign["a"].Executions[key].Stage);
    }
}
