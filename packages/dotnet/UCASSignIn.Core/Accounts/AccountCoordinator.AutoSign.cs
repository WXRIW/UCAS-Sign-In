namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    readonly IAutoSignStore? autoSignStore = cache as IAutoSignStore;
    readonly Dictionary<string, AutoSignExecution> autoSignExecutions = [];
    readonly SemaphoreSlim autoSignSaveGate = new(1);
    readonly SemaphoreSlim autoSignTickGate = new(1);
    readonly Dictionary<string, DateTimeOffset> autoSignQueryStartedAt = [];
    readonly Dictionary<string, DateTimeOffset> autoSignQuerySchoolStartedAt = [], autoSignQuerySchoolVerifiedAt = [];
    readonly Dictionary<string, long> autoSignVerifiedQuerySequence = [];
    bool autoSignStoreAvailable = true;
    bool autoSignNetworkIssue;
    TimeSpan? autoSignSchoolOffset;
    DateTimeOffset? autoSignSchoolSample;
    long autoSignSchoolTimestamp;
    readonly Dictionary<string, (DateTimeOffset At, long Timestamp)> autoSignActivationMarks = [];
    long? autoSignClockRetryTimestamp;
    DateTimeOffset? autoSignClockRetryAt => autoSignClockRetryTimestamp is { } started
        ? clock.GetUtcNow() + TimeSpan.FromSeconds(30) - clock.GetElapsedTime(started) : null;
    DateTimeOffset AutoSignNow => autoSignSchoolSample is { } sample
        ? sample + clock.GetElapsedTime(autoSignSchoolTimestamp) : clock.GetUtcNow();
    DateTimeOffset SchoolTime(DateTimeOffset deviceTime) => deviceTime + (autoSignSchoolOffset ?? TimeSpan.Zero);
    DateTimeOffset DeviceTime(DateTimeOffset schoolTime) => clock.GetUtcNow() + (schoolTime - AutoSignNow);
    bool HasLocalSignSuccess(Course course) => attendanceStates.GetValueOrDefault(AttendanceKey(course))?.LastSuccessfulSignAt is not null;
    public string? AutoSignError { get; private set; }
    public string AutoSignSettingsStatus => !Preferences.AutoSignIsRunning ? "已关闭"
        : !autoSignStoreAvailable || paused || ActiveAccount?.RequiresLogin == true
            || Preferences.AutoSignPausedUntil is { } until && until > AutoSignNow ? "已暂停" : "运行中";
    public string AutoSignRuntimeStatus => !Preferences.AutoSignIsRunning ? "已关闭"
        : !autoSignStoreAvailable ? "已暂停 · 执行记录不可用"
        : ActiveAccount?.RequiresLogin == true || paused ? "需要登录"
        : Preferences.AutoSignPausedUntil is { } until && until > AutoSignNow ? "已暂停至明天"
        : autoSignNetworkIssue ? "等待网络"
        : "运行中";

    public IReadOnlyList<AutoSignExecution> AutoSignHistory => autoSignExecutions.Values
        .Where(x => x.HasExecutionActivity && !x.HistoryDiscarded).OrderByDescending(x => x.HistoryDate)
        .ThenBy(x => x.Key, StringComparer.Ordinal)
        .Select(x =>
        {
            var course = Courses.Concat(snapshots.Values.SelectMany(s => s.Courses))
                .FirstOrDefault(c => AutoSignPlanner.Key(ActiveAccount?.Id ?? "", c) == x.Key);
            return x with { CourseName = x.CourseName ?? course?.Name ?? "课次记录",
                ClassStartAt = x.ClassStartAt ?? course?.Start, ClassEndAt = x.ClassEndAt ?? course?.End };
        }).ToArray();
    bool AutoSignAllowed(Course course) => Preferences.AutoSignIsRunning
        && !HasLocalSignSuccess(course)
        && AutoSignPlans.Any(x => x.Key == AutoSignPlanner.Key(ActiveAccount?.Id ?? "", course)
            && x.IsParticipating && x.Stage is not (AutoSignStage.Skipped or AutoSignStage.Signed or AutoSignStage.Missed or AutoSignStage.NeedsAttention));
    bool AutoSignConfigured(Course course)
    {
        var settings = PreferenceId(course) is { } id ? CoursePreferencesFor(id) : new();
        var occurrence = Preferences.AutoSignOccurrences.GetValueOrDefault(AutoSignPlanner.Key(ActiveAccount?.Id ?? "", course));
        return !settings.SignInDisabled && !HasLocalSignSuccess(course)
            && (occurrence?.Enabled ?? CoursePreferences.Resolve(settings.AutoSign, true));
    }
    bool CanVerifyExisting(AutoSignPlan plan) => Preferences.AutoSignIsRunning && !paused
        && ActiveAccount is { RequiresLogin: false }
        && (Preferences.AutoSignPausedUntil is null || Preferences.AutoSignPausedUntil <= AutoSignNow)
        && AutoSignConfigured(plan.Course)
        && autoSignExecutions.GetValueOrDefault(plan.Key) is { Submissions: > 0 } execution
        && execution.Stage is not (AutoSignStage.Signed or AutoSignStage.Skipped);
    void ObserveAutoSignClock(DateTimeOffset schoolNow)
    {
        autoSignSchoolOffset = schoolNow - clock.GetUtcNow();
        autoSignSchoolSample = schoolNow;
        autoSignSchoolTimestamp = clock.GetTimestamp();
        autoSignClockRetryTimestamp = null;
        autoSignNetworkIssue = false;
        if (autoSignStoreAvailable) AutoSignError = null;
    }
    async Task<DateTimeOffset?> ReadAutoSignClockAsync(Guid epoch)
    {
        try
        {
            var now = await school.SchoolNowAsync(lifetime.Token);
            if (epoch != Generation) return null;
            var clockChanged = autoSignSchoolOffset is null || (now - AutoSignNow).Duration() > TimeSpan.FromSeconds(1);
            ObserveAutoSignClock(now);
            if (!await FreezeAutoSignTimesAsync(epoch)) return null;
            if (clockChanged) Notify();
            return AutoSignNow;
        }
        catch (OperationCanceledException) when (epoch != Generation || lifetime.IsCancellationRequested) { return null; }
        catch (Exception e)
        {
            if (epoch != Generation) return null;
            autoSignNetworkIssue = true;
            autoSignClockRetryTimestamp = clock.GetTimestamp();
            AutoSignError = "自动签到等待网络：" + e.Message;
            Notify();
            return null;
        }
    }
    static DateTimeOffset? Latest(params DateTimeOffset?[] values) => values.Where(x => x.HasValue).DefaultIfEmpty().Max();
    DateTimeOffset StampAutoSignBoundary(string key, DateTimeOffset deviceNow)
    {
        if (autoSignSchoolSample is not null) return AutoSignNow;
        autoSignActivationMarks[key] = (deviceNow, clock.GetTimestamp());
        return deviceNow;
    }
    async Task<bool> FreezeAutoSignTimesAsync(Guid epoch)
    {
        if (epoch != Generation || ActiveAccount is not { } account || !autoSignStoreAvailable) return false;
        await mutations.WaitAsync(lifetime.Token);
        try
        {
            if (epoch != Generation || ActiveAccount is not { } current || current.Id != account.Id) return false;
            var p = current.Preferences;
            DateTimeOffset? Freeze(string key, DateTimeOffset? value)
            {
                if (value is not { } at) return null;
                if (autoSignActivationMarks.TryGetValue(key, out var mark) && mark.At == at)
                    return AutoSignNow - clock.GetElapsedTime(mark.Timestamp);
                if (p.AutoSignSinceUsesSchoolTime) return at;
                var mapped = SchoolTime(at);
                return at > mapped ? at : mapped; // Legacy wall-clock timestamps have no frozen calibration.
            }
            var preferences = p with
            {
                AutoSignSinceUsesSchoolTime = true,
                AutoSignRunningSince = Freeze("running", p.AutoSignRunningSince),
                AutoSignDefaultSince = Freeze("default", p.AutoSignDefaultSince),
                Courses = p.Courses.ToDictionary(x => x.Key, x => x.Value with
                    { AutoSignEnabledSince = Freeze("course:" + x.Key, x.Value.AutoSignEnabledSince) }),
                AutoSignOccurrences = p.AutoSignOccurrences.ToDictionary(x => x.Key, x => x.Value with
                    { EnabledSince = Freeze("once:" + x.Key, x.Value.EnabledSince) })
            };
            if (preferences != p)
            {
                var next = Updated(current with { Settings = preferences });
                try { await CommitAsync(next); }
                catch (Exception e) when (e is not OperationCanceledException)
                {
                    if (epoch == Generation)
                    {
                        vault = next;
                        autoSignStoreAvailable = false;
                        AutoSignError = "自动签到已暂停：启用时间保存失败：" + e.Message;
                        Notify();
                    }
                    return false;
                }
            }
            if (epoch != Generation) return false;
            autoSignActivationMarks.Clear();
        }
        finally { mutations.Release(); }
        if (epoch != Generation) return false;
        var changed = false;
        foreach (var pair in autoSignExecutions.ToArray())
        {
            var execution = pair.Value;
            DateTimeOffset? Legacy(DateTimeOffset? value) => value is { } at
                ? at > SchoolTime(at) ? at : SchoolTime(at) : null;
            var frozen = execution with
            {
                // A legacy wall timestamp cannot prove when the school received the submission.
                FirstSchoolNegativeAt = execution.LastSchoolSubmissionAt is null ? execution.FirstSchoolNegativeAt
                    : execution.FirstSchoolNegativeAt ?? Legacy(execution.FirstNegativeAt),
                LastSchoolVerificationAttemptAt = execution.LastSchoolVerificationAttemptAt ?? Legacy(execution.LastVerificationAttemptAt)
            };
            if (frozen != execution) { autoSignExecutions[pair.Key] = frozen; changed = true; }
        }
        return !changed || await SaveAutoSignAsync(epoch);
    }
    DateTimeOffset? ParticipationSince(AccountPreferences preferences, CoursePreferences settings,
        AutoSignOccurrenceOverride? occurrence) => Latest(Latest(preferences.AutoSignRunningSince,
            occurrence?.Enabled == true ? occurrence.EnabledSince : settings.AutoSign == PreferenceOverride.Enabled
                ? settings.AutoSignEnabledSince : preferences.AutoSignDefaultSince,
            settings.AutoSignEnabledSince, occurrence?.EnabledSince) is { } since
                ? preferences.AutoSignSinceUsesSchoolTime ? since : SchoolTime(since) : null,
            preferences.AutoSignPausedUntil);
    DateTimeOffset SubmissionDue(AutoSignPlan plan, AutoSignExecution? execution) => execution is { Submissions: > 0, LastSubmissionAt: { } last }
        ? (execution.LastSchoolSubmissionAt ?? last).AddMinutes(plan.Policy.RetryMinutes) : plan.PlannedAt;
    DateTimeOffset SubmissionDeadline(AutoSignPlan plan, AutoSignExecution? execution)
    {
        var deadline = execution is { Submissions: > 0 } && plan.Policy.MissedAction == AutoSignMissedAction.Manual
            ? SubmissionDue(plan, execution).AddSeconds(60) : plan.Deadline;
        return plan.Course.End is { } end && deadline > end ? end : deadline;
    }
    DateTimeOffset NextAutoSignAction(AutoSignPlan plan, AutoSignExecution? execution)
    {
        var due = SubmissionDue(plan, execution);
        if (execution is { Submissions: > 0, LastSchoolSubmissionAt: null })
            return execution.LastSchoolVerificationAttemptAt is { } legacyRead
                ? legacyRead.AddMinutes(plan.Policy.RetryMinutes) : plan.Course.Start!.Value.AddMinutes(-25);
        if (execution is { Submissions: > 0, LastSubmissionAt: { } last }
            && (execution.Submissions >= plan.Policy.MaxSubmissions || execution.Stage == AutoSignStage.NeedsAttention))
            due = execution.LastSchoolVerificationAttemptAt is { } attempt ? attempt.AddMinutes(plan.Policy.RetryMinutes)
                : (execution.LastSchoolSubmissionAt ?? last).AddSeconds(30);
        else if (execution is { Submissions: > 0, NegativeReads: < 2, LastSchoolVerificationAttemptAt: { } attempt }
            && due < attempt.AddSeconds(30)) due = attempt.AddSeconds(30);
        if (execution is { NegativeReads: 1, FirstSchoolNegativeAt: { } first } && due < first.AddSeconds(30))
            due = first.AddSeconds(30);
        if (autoSignClockRetryAt is { } retry)
        {
            var schoolRetry = AutoSignNow + (retry - clock.GetUtcNow());
            if (due < schoolRetry) due = schoolRetry;
        }
        return due;
    }
    public DateTimeOffset? NextAutoSignWakeAt
    {
        get
        {
            if (IsDemo || !Preferences.AutoSignIsRunning || !autoSignStoreAvailable || paused
                || ActiveAccount is not { RequiresLogin: false }) return null;
            if (Preferences.AutoSignPausedUntil is { } until && until > AutoSignNow) return DeviceTime(until);
            return AutoSignPlans.Where(p => (p.IsParticipating || CanVerifyExisting(p)) && p.Stage != AutoSignStage.Signed
                    && (p.Stage is not (AutoSignStage.Skipped or AutoSignStage.Missed) || CanVerifyExisting(p))
                    && (p.Stage != AutoSignStage.NeedsAttention || autoSignExecutions.GetValueOrDefault(p.Key) is { Submissions: > 0 })
                    && (autoSignExecutions.GetValueOrDefault(p.Key) is not { Submissions: > 0 } || p.Course.End > AutoSignNow))
                .Select(p => DeviceTime(p.NextAt ?? p.PlannedAt))
                .Concat(autoSignSchoolOffset is null ? Courses.Concat(snapshots.Values.SelectMany(s => s.Courses))
                    .Where(c => AutoSignConfigured(c) && c.Start is not null && c.End > clock.GetUtcNow())
                    .Select(c => c.Start!.Value.AddMinutes(-25)) : [])
                .Select(at => autoSignClockRetryAt is { } retry && at < retry ? retry : at)
                .Cast<DateTimeOffset?>().DefaultIfEmpty().Min();
        }
    }
    AccountPreferences StampParticipation(AccountPreferences before, AccountPreferences after,
        DateTimeOffset now, bool resumed = false) => after with
    {
        AutoSignRunningSince = !before.AutoSignIsRunning && after.AutoSignIsRunning || resumed
            ? StampAutoSignBoundary("running", now) : before.AutoSignRunningSince,
        AutoSignDefaultSince = !before.AutoSignIsRunning && after.AutoSignIsRunning
            ? StampAutoSignBoundary("default", now) : after.AutoSignDefaultSince,
        AutoSignSinceUsesSchoolTime = before.AutoSignSinceUsesSchoolTime || autoSignSchoolSample is not null
    };

    async Task UnifyAutoSignPreferencesAsync(Guid epoch)
    {
        if (epoch != Generation || ActiveAccount is not { } account) return;
        await mutations.WaitAsync();
        try
        {
            if (epoch != Generation || ActiveAccount is not { } current || current.Id != account.Id) return;
            var preferences = current.Preferences.UnifyingAutoSign(current.Preferences.AutoSignSinceUsesSchoolTime ? AutoSignNow : clock.GetUtcNow());
            if (preferences == current.Preferences) return;
            var next = Updated(current with { Settings = preferences });
            try
            {
                await accounts.SaveAsync(next, lifetime.Token);
                if (epoch == Generation && ActiveAccount?.Id == account.Id) vault = next;
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                if (epoch != Generation || ActiveAccount?.Id != account.Id) return;
                // Keep the safe participation boundary while retaining the original persisted settings.
                vault = next;
                autoSignStoreAvailable = false;
                AutoSignError = "自动签到已暂停：设置升级保存失败：" + e.Message;
            }
        }
        finally { mutations.Release(); }
    }
    public IReadOnlyList<AutoSignPlan> AutoSignPlans
    {
        get
        {
            if (ActiveAccount is not { } account || IsDemo) return [];
            var preferences = account.Preferences;
            var now = AutoSignNow;
            var todayStart = CourseTime.Parse(CourseTime.DayKey(DateOnly.FromDateTime(now.ToOffset(CourseTime.ShanghaiOffset).DateTime)), "00:00")!.Value;
            var cutoff = now.AddDays(7);
            return Courses.Concat(snapshots.Values.SelectMany(x => x.Courses))
                .GroupBy(c => AutoSignPlanner.Key(account.Id, c)).Select(g => g.First())
                .Where(c => c.Start is { } start && start >= todayStart && start < cutoff)
                .Select(c =>
                {
                    var key = AutoSignPlanner.Key(account.Id, c);
                    var settings = PreferenceId(c) is { } preferenceId ? CoursePreferencesFor(preferenceId) : new CoursePreferences();
                    preferences.AutoSignOccurrences.TryGetValue(key, out var occurrence);
                    var execution = autoSignExecutions.GetValueOrDefault(key);
                    var plan = AutoSignPlanner.Create(account.Id, c, preferences.AutoSignRule, settings.AutoSignRule,
                        occurrence, preferences.AutoSignIsRunning && (preferences.AutoSignPausedUntil is null || now >= preferences.AutoSignPausedUntil),
                        settings.AutoSign,
                        settings.SignInDisabled, now, execution,
                        ParticipationSince(preferences, settings, occurrence));
                    if (plan is null) return null;
                    return HasLocalSignSuccess(c)
                        ? plan with { Stage = AutoSignStage.Signed, Reason = "本机已保存签到成功，自动任务已完成", NextAt = null }
                        : plan with { NextAt = NextAutoSignAction(plan, execution) };
                })
                .OfType<AutoSignPlan>().OrderBy(x => x.NextAt).ThenBy(x => x.Key).ToArray();
        }
    }

    async Task LoadAutoSignAsync(string accountId, Guid epoch)
    {
        autoSignExecutions.Clear();
        autoSignQueryStartedAt.Clear();
        autoSignQuerySchoolStartedAt.Clear(); autoSignQuerySchoolVerifiedAt.Clear(); autoSignVerifiedQuerySequence.Clear();
        autoSignSchoolOffset = null;
        autoSignSchoolSample = null;
        autoSignActivationMarks.Clear();
        autoSignClockRetryTimestamp = null;
        autoSignStoreAvailable = autoSignStore is not null;
        autoSignNetworkIssue = false;
        AutoSignError = null;
        if (autoSignStore is null) return;
        try
        {
            var ledger = await autoSignStore.LoadAutoSignAsync(accountId, lifetime.Token);
            if (epoch != Generation || ledger is null) return;
            ledger.Validate(accountId);
            var cleaned = ledger.Cleaned();
            if (ledger.Version != AutoSignLedger.CurrentVersion || cleaned.Executions.Count != ledger.Executions.Count)
                await autoSignStore.SaveAutoSignAsync(cleaned, lifetime.Token);
            if (epoch != Generation) return;
            foreach (var pair in cleaned.Executions) autoSignExecutions[pair.Key] = pair.Value;
            foreach (var execution in cleaned.Executions.Values)
                requestSequence = Math.Max(requestSequence, Math.Max(execution.LastSubmissionQuerySequence ?? 0, execution.LastNegativeQuerySequence ?? 0));
            foreach (var pair in autoSignExecutions.Where(x => x.Value.Stage == AutoSignStage.Submitting).ToArray())
                autoSignExecutions[pair.Key] = pair.Value.Transition(AutoSignStage.Verifying, clock.GetUtcNow(), "上次提交结果未知，等待学校状态核实");
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (epoch == Generation) { autoSignStoreAvailable = false; AutoSignError = "自动签到已暂停：" + e.Message; }
        }
    }

    async Task<bool> SaveAutoSignAsync(Guid epoch)
    {
        if (autoSignStore is null || !autoSignStoreAvailable || ActiveAccount is not { } account) return false;
        await autoSignSaveGate.WaitAsync();
        try
        {
            if (epoch != Generation || ActiveAccount?.Id != account.Id) return false;
            var items = new Dictionary<string, AutoSignExecution>(autoSignExecutions);
            var source = new AutoSignLedger(AutoSignLedger.CurrentVersion, account.Id, items);
            var ledger = source.RetainHistory(HistoryRetention.Automatic, clock.GetUtcNow());
            ledger.Validate(account.Id);
            await autoSignStore.SaveAutoSignAsync(ledger, lifetime.Token);
            if (epoch == Generation) ApplySavedHistoryCompaction(source, ledger);
            return true;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (epoch == Generation) { autoSignStoreAvailable = false; AutoSignError = "自动签到已暂停：执行记录保存失败：" + e.Message; Notify(); }
            return false;
        }
        finally { autoSignSaveGate.Release(); }
    }

    async Task<bool> SetAutoSignStageAsync(AutoSignExecution execution, AutoSignStage stage, string message,
        Guid epoch, DateTimeOffset? nextAt = null)
    {
        if (epoch != Generation) return false;
        execution = autoSignExecutions.GetValueOrDefault(execution.Key) ?? execution;
        if (execution.Stage is AutoSignStage.Skipped or AutoSignStage.Signed && stage != execution.Stage) return false;
        if (execution.Stage == stage && execution.Message == message && execution.NextAt == nextAt) return true;
        var at = clock.GetUtcNow();
        var next = execution.Transition(stage, at, message, nextAt);
        autoSignExecutions[execution.Key] = next;
        var saved = await SaveAutoSignAsync(epoch);
        if (saved && epoch == Generation)
        {
            QueueAutoSignResult(next, new(at, stage, message, AutoSignExecution.TransitionKind(stage)));
            Notify();
        }
        return saved;
    }

    async Task RecordAutoSignPlanChangesAsync(IReadOnlyDictionary<string, AutoSignPlan> before, Guid epoch)
    {
        if (epoch != Generation || !autoSignStoreAvailable) return;
        var changed = false;
        foreach (var plan in AutoSignPlans)
        {
            if (!autoSignExecutions.TryGetValue(plan.Key, out var execution) || !execution.HasExecutionActivity || execution.HistoryDiscarded) continue;
            if (before.TryGetValue(plan.Key, out var previous)
                && previous.PlannedAt == plan.PlannedAt && previous.Policy == plan.Policy
                && previous.Stage == plan.Stage && previous.Source == plan.Source) continue;
            var message = plan.Stage == AutoSignStage.Skipped ? "计划已暂停或跳过：" + plan.Reason
                : "计划已更新：" + plan.PlannedAt.ToOffset(CourseTime.ShanghaiOffset).ToString("MM-dd HH:mm")
                  + "；" + plan.Source;
            autoSignExecutions[plan.Key] = execution with
            {
                NotificationMode = plan.Policy.Notification,
                Events = [.. execution.Events, new(clock.GetUtcNow(), plan.Stage, message,
                    plan.Stage == AutoSignStage.Skipped ? AutoSignEventKind.Pause : AutoSignEventKind.PlanChanged)]
            };
            changed = true;
        }
        if (changed && await SaveAutoSignAsync(epoch)) Notify();
    }

    public async Task SetAutoSignSettingsAsync(bool? running = null, AutoSignPolicy? rule = null,
        Dictionary<string, AutoSignOccurrenceOverride>? occurrences = null, DateTimeOffset? pauseUntil = null, bool clearPause = false)
    {
        if (IsDemo || !CanChangeAccount || ActiveAccount is not { } account) return;
        var expectedGeneration = Generation;
        rule?.Validate();
        await mutations.WaitAsync();
        try
        {
            var epoch = Generation;
            if (epoch != expectedGeneration || ActiveAccount?.Id != account.Id) return;
            var before = AutoSignPlans.ToDictionary(x => x.Key);
            var p = ActiveAccount!.Preferences;
            var now = clock.GetUtcNow();
            var values = new Dictionary<string, AutoSignOccurrenceOverride>(occurrences ?? p.AutoSignOccurrences);
            if (occurrences is not null)
            {
                foreach (var key in values.Keys.ToArray())
                {
                    var value = values[key];
                    var previous = p.AutoSignOccurrences.GetValueOrDefault(key);
                    _ = value.Policy?.Resolve(rule ?? p.AutoSignRule);
                    var plan = before.GetValueOrDefault(key);
                    if (value.At is { } at && plan is not null
                        && (at < plan.Course.Start!.Value.AddMinutes(-25) || at >= plan.Course.End))
                    { SetMessage("本次时间需在课前 25 分钟至下课前"); return; }
                    values[key] = value with { EnabledSince = value.Enabled == true && previous?.Enabled != true
                        || previous?.Enabled == false && value.Enabled != false
                        ? StampAutoSignBoundary("once:" + key, now) : previous?.EnabledSince ?? value.EnabledSince };
                }
                foreach (var removed in p.AutoSignOccurrences.Where(x => !values.ContainsKey(x.Key) && x.Value.Enabled == false))
                    values[removed.Key] = new(EnabledSince: StampAutoSignBoundary("once:" + removed.Key, now));
            }
            var preferences = StampParticipation(p, p with
            {
                AutoSignRunning = running ?? p.AutoSignIsRunning,
                AutoSignEnabled = running ?? p.AutoSignIsRunning,
                AutoSignRule = rule ?? p.AutoSignRule,
                AutoSignOccurrences = values,
                AutoSignPausedUntil = clearPause ? null : pauseUntil ?? p.AutoSignPausedUntil,
                AutoSignV2Acknowledged = true
            }, now, clearPause && p.AutoSignPausedUntil is not null);
            var updated = ActiveAccount! with { Settings = preferences };
            await CommitAsync(Updated(updated));
            await RecordAutoSignPlanChangesAsync(before, epoch);
            Notify();
        }
        finally { mutations.Release(); }
    }
    public async Task AcknowledgeAutoSignMigrationAsync()
    {
        if (ActiveAccount is not { } account || !account.Preferences.NeedsAutoSignMigrationNotice) return;
        await mutations.WaitAsync();
        try
        {
            var current = ActiveAccount;
            if (current is null) return;
            await CommitAsync(Updated(current with { Settings = current.Preferences with { AutoSignV2Acknowledged = true } }));
            Notify();
        }
        finally { mutations.Release(); }
    }

    async Task<bool> ReserveAutoSignSubmissionAsync(Course course, Guid epoch, DateTimeOffset schoolNow)
    {
        if (epoch != Generation || ActiveAccount is not { } account || !autoSignStoreAvailable || HasLocalSignSuccess(course)
            || autoSignExecutions.GetValueOrDefault(AutoSignPlanner.Key(account.Id, course)) is { Submissions: > 0, LastSchoolSubmissionAt: null }) return false;
        ObserveAutoSignClock(schoolNow);
        if (!await FreezeAutoSignTimesAsync(epoch)) return false;
        schoolNow = AutoSignNow;
        var plan = AutoSignPlans.FirstOrDefault(x => x.Course.Id == course.Id && x.Course.Day == course.Day);
        if (plan is null || plan.Stage is AutoSignStage.Skipped or AutoSignStage.Missed or AutoSignStage.NeedsAttention
            || !AutoSignAllowed(plan.Course) || !CourseTime.InSignWindow(plan.Course, schoolNow)) return false;
        var execution = (autoSignExecutions.GetValueOrDefault(plan.Key) ?? AutoSignExecution.New(plan.Key, clock.GetUtcNow()))
            .Begin(course, clock.GetUtcNow(), plan.Policy.Notification);
        if (schoolNow < SubmissionDue(plan, execution) || schoolNow > SubmissionDeadline(plan, execution)) return false;
        if (execution.Submissions >= plan.Policy.MaxSubmissions || execution.Stage is AutoSignStage.Signed or AutoSignStage.Submitting) return false;
        var next = execution with { Submissions = execution.Submissions + 1, LastSubmissionAt = clock.GetUtcNow(),
            FirstNegativeAt = null, NegativeReads = 0, LastVerificationAttemptAt = null,
            NotificationMode = plan.Policy.Notification, LastSchoolSubmissionAt = schoolNow,
            FirstSchoolNegativeAt = null, LastSchoolVerificationAttemptAt = null,
            LastSubmissionQuerySequence = requestSequence, LastNegativeQuerySequence = null };
        autoSignExecutions[plan.Key] = next.Transition(AutoSignStage.Submitting, clock.GetUtcNow(), "第 " + next.Submissions + " 次提交已发送");
        if (!await SaveAutoSignAsync(epoch) || epoch != Generation || HasLocalSignSuccess(course)) return false;
        var latest = AutoSignPlans.FirstOrDefault(x => x.Key == plan.Key);
        return latest is not null && AutoSignAllowed(latest.Course) && next.Submissions <= latest.Policy.MaxSubmissions
            && AutoSignNow >= SubmissionDue(latest, execution) && AutoSignNow <= SubmissionDeadline(latest, execution)
            && CourseTime.InSignWindow(latest.Course, AutoSignNow);
    }

    async Task SetAutoSignNextAtAsync(AutoSignExecution execution, DateTimeOffset? nextAt, Guid epoch,
        DateTimeOffset? verificationAttemptAt = null)
    {
        if (epoch != Generation || !autoSignExecutions.TryGetValue(execution.Key, out var current)
            || current.Stage is AutoSignStage.Signed or AutoSignStage.Skipped
            || current.NextAt == nextAt && verificationAttemptAt is null) return;
        autoSignExecutions[execution.Key] = current with { NextAt = nextAt,
            LastVerificationAttemptAt = verificationAttemptAt ?? current.LastVerificationAttemptAt,
            LastSchoolVerificationAttemptAt = verificationAttemptAt is null ? current.LastSchoolVerificationAttemptAt : AutoSignNow };
        if (await SaveAutoSignAsync(epoch)) Notify();
    }

    async Task ReconcileAutoSignSuccessAsync(IEnumerable<Course> courses, Guid epoch)
    {
        foreach (var course in courses.Where(c => c.Signed && c.SignStatusKnown == true))
        {
            var key = AutoSignPlanner.Key(ActiveAccount?.Id ?? "", course);
            if (epoch != Generation) return;
            if (autoSignExecutions.TryGetValue(key, out var execution) && execution.HasExecutionActivity
                && execution.Stage is not (AutoSignStage.Signed or AutoSignStage.Skipped))
                await SetAutoSignStageAsync(execution, AutoSignStage.Signed, "学校确认已签到", epoch);
        }
    }

    bool HasFreshAutoSignNegative(Course course, AutoSignExecution execution, bool requireQuorumSpacing)
    {
        var sequence = autoSignVerifiedQuerySequence.GetValueOrDefault(course.Day);
        if (sequence == 0 || sequence != versions.GetValueOrDefault(course.Day)
            || sequence <= (execution.LastSubmissionQuerySequence ?? 0)
            || sequence <= (execution.LastNegativeQuerySequence ?? 0)
            || !autoSignQuerySchoolStartedAt.TryGetValue(course.Day, out var started)
            || !autoSignQuerySchoolVerifiedAt.TryGetValue(course.Day, out var verified)
            || execution.LastSchoolSubmissionAt is { } lastSchool && started <= lastSchool
            || verified < started || AttendanceStatusFor(course) != AttendanceStatus.Unsigned) return false;
        return !requireQuorumSpacing || execution.FirstSchoolNegativeAt is not { } first || started >= first.AddSeconds(30);
    }

    async Task EvaluateAutoSignAsync(Course course, Guid epoch)
    {
        if (epoch != Generation || ActiveAccount is not { } account || !autoSignStoreAvailable || HasLocalSignSuccess(course)
            || !Preferences.AutoSignIsRunning || paused || account.RequiresLogin
            || Preferences.AutoSignPausedUntil is { } until && until > AutoSignNow) return;
        var plan = AutoSignPlans.FirstOrDefault(x => x.Course.Id == course.Id && x.Course.Day == course.Day);
        if (plan is null || plan.Stage == AutoSignStage.Signed || plan.Stage == AutoSignStage.Skipped && !CanVerifyExisting(plan)) return;
        var now = clock.GetUtcNow();
        var execution = autoSignExecutions.GetValueOrDefault(plan.Key) ?? AutoSignExecution.New(plan.Key, now);
        if (execution.Stage is AutoSignStage.Skipped or AutoSignStage.Signed || execution.Stage == AutoSignStage.Missed && execution.Submissions == 0
            || plan.Stage == AutoSignStage.NeedsAttention && execution.Submissions == 0) return;
        if (AutoSignNow < NextAutoSignAction(plan, execution)) return;
        var reading = await ReadAutoSignClockAsync(epoch);
        if (reading is not { } schoolNow || epoch != Generation) return;
        plan = AutoSignPlans.FirstOrDefault(x => x.Key == plan.Key);
        execution = autoSignExecutions.GetValueOrDefault(execution.Key) ?? execution;
        if (plan is null || (!plan.IsParticipating || plan.Stage == AutoSignStage.Skipped) && !CanVerifyExisting(plan) || plan.Stage == AutoSignStage.Signed
            || !Preferences.AutoSignIsRunning || HasLocalSignSuccess(course)
            || execution.Stage is AutoSignStage.Skipped or AutoSignStage.Signed || execution.Stage == AutoSignStage.Missed && execution.Submissions == 0
            || schoolNow < NextAutoSignAction(plan, execution)) return;
        course = plan.Course;
        if (!execution.HasExecutionActivity)
        {
            execution = execution.Begin(course, now, plan.Policy.Notification);
            autoSignExecutions[plan.Key] = execution;
            if (!await SaveAutoSignAsync(epoch)) return;
            Notify();
        }
        if (AttendanceStatusFor(course) == AttendanceStatus.Signed)
        {
            await SetAutoSignStageAsync(execution, AutoSignStage.Signed, "学校确认已签到", epoch);
            return;
        }
        var deadline = SubmissionDeadline(plan, execution);
        if (execution.Submissions == 0 && schoolNow > deadline)
        {
            await SetAutoSignStageAsync(execution, AutoSignStage.Missed,
                "已错过自动执行时间，请手动处理", epoch);
            return;
        }
        if (execution.Submissions > 0 && course.End is { } end && schoolNow >= end)
        {
            if (execution.Stage == AutoSignStage.NeedsAttention) await SetAutoSignNextAtAsync(execution, null, epoch);
            else await SetAutoSignStageAsync(execution, AutoSignStage.NeedsAttention, "课程已结束，提交结果仍需手动核实", epoch);
            return;
        }
        var verifyOnly = execution.Submissions > 0 && (execution.Submissions >= plan.Policy.MaxSubmissions
            || execution.LastSchoolSubmissionAt is null || !plan.IsParticipating || plan.Stage == AutoSignStage.Skipped
            || execution.Stage is AutoSignStage.NeedsAttention or AutoSignStage.Missed || schoolNow > deadline);
        if (verifyOnly)
        {
            await RefreshAsync(CourseTime.Date(course.Day));
            if (epoch != Generation) return;
            execution = autoSignExecutions.GetValueOrDefault(plan.Key) ?? execution;
            if (execution.Stage is AutoSignStage.Signed or AutoSignStage.Skipped || HasLocalSignSuccess(course)) return;
            var next = clock.GetUtcNow().AddMinutes(plan.Policy.RetryMinutes);
            if (HasFreshAutoSignNegative(course, execution, requireQuorumSpacing: false) && execution.Stage != AutoSignStage.NeedsAttention)
            {
                autoSignExecutions[execution.Key] = execution with { LastVerificationAttemptAt = clock.GetUtcNow(), LastSchoolVerificationAttemptAt = AutoSignNow };
                await SetAutoSignStageAsync(execution, AutoSignStage.NeedsAttention,
                    execution.LastSchoolSubmissionAt is null ? "旧记录缺少学校提交时间，已停止自动重试，请手动核实"
                    : execution.Submissions >= plan.Policy.MaxSubmissions ? "学校尚未确认签到，已达到自动提交次数上限，请手动处理"
                        : "学校尚未确认签到，已错过自动提交时间，请手动处理", epoch, next);
            }
            else await SetAutoSignNextAtAsync(execution, next, epoch, clock.GetUtcNow());
            return;
        }
        if (execution.Submissions > 0)
        {
            if (execution.NegativeReads < 2)
            {
                if (execution.FirstSchoolNegativeAt is { } firstSchool && AutoSignNow < firstSchool.AddSeconds(30)) return;
                await RefreshAsync(CourseTime.Date(course.Day));
                if (epoch != Generation) return;
                execution = autoSignExecutions.GetValueOrDefault(plan.Key) ?? execution;
                if (execution.Stage is AutoSignStage.Skipped or AutoSignStage.Signed or AutoSignStage.Missed or AutoSignStage.NeedsAttention or AutoSignStage.Submitting) return;
                if (AttendanceStatusFor(course) == AttendanceStatus.Signed)
                {
                    await SetAutoSignStageAsync(execution, AutoSignStage.Signed, "学校确认已签到", epoch);
                    return;
                }
                var observed = dayVerifiedAt.GetValueOrDefault(course.Day);
                var started = autoSignQueryStartedAt.GetValueOrDefault(course.Day);
                if (!HasFreshAutoSignNegative(course, execution, requireQuorumSpacing: true))
                {
                    await SetAutoSignNextAtAsync(execution, clock.GetUtcNow().AddSeconds(30), epoch, clock.GetUtcNow());
                    return;
                }
                execution = execution with { NegativeReads = execution.NegativeReads + 1,
                    FirstNegativeAt = execution.FirstNegativeAt ?? observed,
                    LastVerificationAttemptAt = clock.GetUtcNow(),
                    FirstSchoolNegativeAt = execution.FirstSchoolNegativeAt ?? autoSignQuerySchoolVerifiedAt[course.Day],
                    LastSchoolVerificationAttemptAt = AutoSignNow,
                    LastNegativeQuerySequence = autoSignVerifiedQuerySequence[course.Day],
                    Events = [.. execution.Events, new(now, AutoSignStage.Checking,
                        "学校第 " + (execution.NegativeReads + 1) + " 次确认仍未签到", AutoSignEventKind.Verification)] };
                autoSignExecutions[plan.Key] = execution;
                if (!await SaveAutoSignAsync(epoch)) return;
                Notify();
                if (execution.NegativeReads < 2) return;
            }
        }
        else if (!CachePolicy.Fresh(dayVerifiedAt.GetValueOrDefault(course.Day), now, TimeSpan.FromSeconds(60)))
            await RefreshAsync(CourseTime.Date(course.Day));
        if (epoch != Generation || AttendanceStatusFor(course) != AttendanceStatus.Unsigned || HasLocalSignSuccess(course)) return;
        execution = autoSignExecutions.GetValueOrDefault(plan.Key) ?? execution;
        plan = AutoSignPlans.FirstOrDefault(x => x.Key == plan.Key);
        if (plan is null || !AutoSignAllowed(plan.Course) || AutoSignNow < SubmissionDue(plan, execution)
            || AutoSignNow > SubmissionDeadline(plan, execution) || !CourseTime.InSignWindow(plan.Course, AutoSignNow)) return;
        await SignAsync(plan.Course, epoch, true);
    }
}
