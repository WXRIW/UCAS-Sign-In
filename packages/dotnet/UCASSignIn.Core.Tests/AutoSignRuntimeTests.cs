using UCASSignIn.Core;

namespace UCASSignIn.Core.Tests;

public sealed class AutoSignRuntimeTests
{
    static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-13T08:25:00+08:00");
    static AutoSignExecution Execution(string account = "account", params AutoSignEvent[] events) =>
        AutoSignExecution.New(account + "|2026-10-13|lesson", Now) with { CourseName = "高等数学", Events = [.. events] };
    static AutoSignEvent Event(AutoSignStage stage, AutoSignEventKind kind, string message = "结果") => new(Now, stage, message, kind);

    [Fact]
    public void OnlyNewActualFinalEventsProduceResults()
    {
        var epoch = Guid.NewGuid();
        var previous = AutoSignNotificationSnapshot.Capture(epoch, "account", []);
        var outcome = Execution("account", Event(AutoSignStage.Verifying, AutoSignEventKind.Verification),
            Event(AutoSignStage.NeedsAttention, AutoSignEventKind.Result, "学校状态无法核实"),
            Event(AutoSignStage.NeedsAttention, AutoSignEventKind.PlanChanged, "计划已更新"));
        var result = Assert.Single(AutoSignRuntime.Results(previous, epoch, "account", [outcome], _ => AutoSignNotification.Problems));
        Assert.Equal("学校状态无法核实", result.Message);
        Assert.Equal("高等数学", result.CourseName);
        Assert.False(result.Succeeded);
        var acknowledged = AutoSignNotificationSnapshot.Capture(epoch, "account", [outcome]);
        Assert.Empty(AutoSignRuntime.Results(acknowledged, epoch, "account", [outcome], _ => AutoSignNotification.All));
    }

    [Fact]
    public void OldSuccessIsNotReplayedByPlanChangesOrPause()
    {
        var epoch = Guid.NewGuid();
        var old = Execution("account", Event(AutoSignStage.Signed, AutoSignEventKind.Result));
        var before = AutoSignNotificationSnapshot.Capture(epoch, "account", [old]);
        var changed = old with { Events = [.. old.Events,
            Event(AutoSignStage.Signed, AutoSignEventKind.PlanChanged), Event(AutoSignStage.Skipped, AutoSignEventKind.Pause)] };
        Assert.Empty(AutoSignRuntime.Results(before, epoch, "account", [changed], _ => AutoSignNotification.All));
    }

    [Fact]
    public void SuccessConfirmedBetweenTicksIsDeliveredOnceFromPersistentBaseline()
    {
        var epoch = Guid.NewGuid();
        var pending = Execution("account", Event(AutoSignStage.Verifying, AutoSignEventKind.Verification));
        var baseline = AutoSignNotificationSnapshot.Capture(epoch, "account", [pending]);
        var confirmedByRefresh = pending.Transition(AutoSignStage.Signed, Now.AddSeconds(5), "学校确认已签到");
        var result = Assert.Single(AutoSignRuntime.Results(baseline, epoch, "account", [confirmedByRefresh], _ => AutoSignNotification.All));
        Assert.True(result.Succeeded);
        baseline = AutoSignNotificationSnapshot.Capture(epoch, "account", [confirmedByRefresh]);
        Assert.Empty(AutoSignRuntime.Results(baseline, epoch, "account", [confirmedByRefresh], _ => AutoSignNotification.All));
    }

    [Theory]
    [InlineData(AutoSignStage.Signed, AutoSignEventKind.Result, AutoSignNotification.All, true)]
    [InlineData(AutoSignStage.Signed, AutoSignEventKind.Result, AutoSignNotification.Problems, false)]
    [InlineData(AutoSignStage.Missed, AutoSignEventKind.Missed, AutoSignNotification.Problems, true)]
    [InlineData(AutoSignStage.NeedsAttention, AutoSignEventKind.Result, AutoSignNotification.None, false)]
    [InlineData(AutoSignStage.Verifying, AutoSignEventKind.Verification, AutoSignNotification.All, false)]
    [InlineData(AutoSignStage.Signed, AutoSignEventKind.ManualTakeover, AutoSignNotification.All, false)]
    [InlineData(AutoSignStage.Signed, AutoSignEventKind.Legacy, AutoSignNotification.All, false)]
    public void NotificationModeAndEventKindBothControlEmission(AutoSignStage stage, AutoSignEventKind kind,
        AutoSignNotification mode, bool expected)
    {
        var epoch = Guid.NewGuid();
        var previous = AutoSignNotificationSnapshot.Capture(epoch, "account", []);
        var results = AutoSignRuntime.Results(previous, epoch, "account", [Execution("account", Event(stage, kind))], _ => mode);
        Assert.Equal(expected ? 1 : 0, results.Count);
    }

    [Fact]
    public void AccountAndGenerationChangesDiscardPriorTickResults()
    {
        var epoch = Guid.NewGuid();
        var previous = AutoSignNotificationSnapshot.Capture(epoch, "account", []);
        var result = Execution("account", Event(AutoSignStage.Signed, AutoSignEventKind.Result));
        Assert.Empty(AutoSignRuntime.Results(previous, Guid.NewGuid(), "account", [result], _ => AutoSignNotification.All));
        Assert.Empty(AutoSignRuntime.Results(previous, epoch, "other", [result], _ => AutoSignNotification.All));
        Assert.Empty(AutoSignRuntime.Results(previous, epoch, "account",
            [Execution("other", Event(AutoSignStage.Signed, AutoSignEventKind.Result))], _ => AutoSignNotification.All));
    }

    [Fact]
    public void PerOccurrenceModeCanSuppressOneResultWithoutSuppressingOthers()
    {
        var epoch = Guid.NewGuid();
        var previous = AutoSignNotificationSnapshot.Capture(epoch, "account", []);
        var first = Execution("account", Event(AutoSignStage.Missed, AutoSignEventKind.Missed));
        var second = first with { Key = "account|2026-10-13|second" };
        var emitted = Assert.Single(AutoSignRuntime.Results(previous, epoch, "account", [first, second],
            item => item.Key == first.Key ? AutoSignNotification.None : AutoSignNotification.Problems));
        Assert.Equal(second.Key, emitted.Key);
    }

    [Fact]
    public async Task MeaningfulChangeInterruptsLongWaitAndCancelsItsTimer()
    {
        var signal = new AutoSignWakeSignal<string>("old-plan");
        CancellationToken timerToken = default;
        var elapsed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var waiting = signal.WaitAsync(signal.State, TimeSpan.FromMinutes(15), CancellationToken.None, (_, token) =>
        { timerToken = token; token.Register(() => elapsed.TrySetCanceled(token)); return elapsed.Task; });
        Assert.False(waiting.IsCompleted);
        signal.Update("new-plan");
        await waiting;
        Assert.True(timerToken.IsCancellationRequested);
    }

    [Fact]
    public async Task TickChangesAcknowledgedBeforeWaitDoNotCauseHotLoop()
    {
        var signal = new AutoSignWakeSignal<string>("planned");
        signal.Update("checking");
        signal.Update("waiting-for-plan");
        using var lifetime = new CancellationTokenSource();
        var elapsed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var waiting = signal.WaitAsync(signal.State, TimeSpan.FromMinutes(15), lifetime.Token, (_, token) =>
        { token.Register(() => elapsed.TrySetCanceled(token)); return elapsed.Task; });
        signal.Update("waiting-for-plan");
        Assert.False(waiting.IsCompleted);
        lifetime.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiting);
    }

    [Fact]
    public async Task ChangeBetweenDeadlineCalculationAndWaitIsNotLost()
    {
        var signal = new AutoSignWakeSignal<string>("old-plan");
        var expected = signal.State;
        signal.Update("new-account");
        var timerCreated = false;
        await signal.WaitAsync(expected, TimeSpan.FromMinutes(15), CancellationToken.None, (_, _) =>
        { timerCreated = true; return Task.CompletedTask; });
        Assert.False(timerCreated);
    }

    [Fact]
    public async Task ReachingDeadlineEndsWaitWithoutStateChange()
    {
        var signal = new AutoSignWakeSignal<string>("planned");
        var elapsed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var waiting = signal.WaitAsync(signal.State, TimeSpan.FromMinutes(15), CancellationToken.None, (_, _) => elapsed.Task);
        elapsed.SetResult();
        await waiting;
        Assert.Equal("planned", signal.State);
    }

    [Fact]
    public void ProjectionJitterDoesNotWakeServiceButChangedDeadlineDoes()
    {
        var data = new MemoryData();
        var model = new AccountCoordinator(new FakeSchool(), new MemoryAccounts(), data, data, new FakeReminders(), new FakeClock(Now));
        var before = AutoSignRuntime.WakeState(model, Now.AddTicks(-10));
        Assert.Equal(before, AutoSignRuntime.WakeState(model, Now.AddTicks(10)));
        Assert.NotEqual(before, AutoSignRuntime.WakeState(model, Now.AddSeconds(1)));
    }

    [Fact]
    public async Task UnrelatedPreferencesAndUiMessagesDoNotChangeWakeState()
    {
        var accounts = new MemoryAccounts { Vault = new(1, [TestData.Account()], "a") };
        var data = new MemoryData();
        var clock = new FakeClock(TestData.Now.AddMinutes(-10));
        var school = new FakeSchool { Now = clock.Now, Query = (_, day) => Task.FromResult(new CourseQueryResult(
            [TestData.Course() with { Day = CourseTime.DayKey(day), CourseId = "course-1", CourseNumber = "CS001" }], "同步成功")) };
        var model = new AccountCoordinator(school, accounts, data, data, new FakeReminders(), clock);
        await model.InitializeAsync();
        var initial = AutoSignRuntime.WakeState(model, null);
        await model.SetPreferencesAsync(false, true, false, 15);
        await model.SetCoursePreferencesAsync("course-1", new(Reminders: PreferenceOverride.Enabled,
            Confirmation: PreferenceOverride.Disabled, ReminderLeadMinutes: 5));
        model.SetMessage("普通界面提示");
        Assert.Equal(initial, AutoSignRuntime.WakeState(model, null));
        await model.SetAutoSignSettingsAsync(rule: model.Preferences.AutoSignRule with { RetryMinutes = 5 });
        Assert.NotEqual(initial, AutoSignRuntime.WakeState(model, null));
        var rulesChanged = AutoSignRuntime.WakeState(model, null);
        await model.SetAutoSignSettingsAsync(running: true);
        Assert.NotEqual(rulesChanged, AutoSignRuntime.WakeState(model, null));
    }
}
