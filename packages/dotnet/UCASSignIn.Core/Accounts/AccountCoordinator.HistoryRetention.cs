namespace UCASSignIn.Core;

public sealed partial class AccountCoordinator
{
    readonly IHistoryRetentionStore? historyRetentionStore = records as IHistoryRetentionStore ?? cache as IHistoryRetentionStore;
    // Every operation-history save shares this gate with cleanup, including delayed sign responses.
    readonly SemaphoreSlim historySaveGate = new(1);
    string? loadedHistoryAccountId;
    DateTimeOffset? historyCleanupAfter;

    public HistoryRetentionSettings HistoryRetention { get; private set; } = new();

    async Task LoadHistoryRetentionAsync()
    {
        var settings = historyRetentionStore is null ? new() : await historyRetentionStore.LoadHistoryRetentionAsync();
        settings.Validate();
        HistoryRetention = settings;
    }

    public async Task SetHistoryRetentionAsync(HistoryRetentionSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        settings.Validate();
        if (!loaded) throw new InvalidOperationException("账户尚未加载完成，请稍后保存");
        if (IsDemo) throw new InvalidOperationException("演示模式不会修改真实账户的记录保留设置");
        if (historyRetentionStore is null) throw new InvalidOperationException("当前存储不支持保存记录保留设置");
        await mutations.WaitAsync();
        var ownsBusy = false;
        try
        {
            if (IsDemo || !CanChangeAccount) throw new InvalidOperationException("当前无法修改记录保留设置，请稍后保存");
            IsBusy = true;
            ownsBusy = true;
            Notify();
            await historySaveGate.WaitAsync();
            try
            {
                // Persist the user's choice before irreversible cleanup. A settings-write failure
                // leaves both the old preference and all history intact.
                await historyRetentionStore.SaveHistoryRetentionAsync(settings);
                HistoryRetention = settings;
                historyCleanupAfter = null;
                try { await MaintainHistoriesCoreAsync(); }
                catch (Exception e)
                {
                    throw new IOException("保留设置已保存，但部分记录清理失败；稍后将重试：" + e.Message, e);
                }
            }
            finally { historySaveGate.Release(); }
        }
        finally { if (ownsBusy) IsBusy = false; mutations.Release(); Notify(); }
    }

    static IReadOnlyList<AttendanceRecord> RetainedRecords(IReadOnlyList<AttendanceRecord> source,
        HistoryRetentionPolicy policy, DateTimeOffset now) => policy.IsUnlimited ? source
        : policy.Retain(source, now, x => x.Date,
            x => string.Join("\u001f", x.CourseId, x.ScheduledCourseId, x.CourseName, x.Message, x.Succeeded.ToString()));

    async Task SaveOperationRecordsAsync(string accountId, Guid epoch)
    {
        await historySaveGate.WaitAsync();
        try
        {
            if (epoch != Generation || ActiveAccount?.Id != accountId) return;
            var source = Records;
            var retained = RetainedRecords(source, HistoryRetention.Operations, clock.GetUtcNow());
            await records.SaveAsync(accountId, retained, lifetime.Token);
            if (epoch == Generation && ReferenceEquals(source, Records)) Records = retained;
        }
        finally { historySaveGate.Release(); }
    }

    // Caller owns historySaveGate. Account switching/removal is held by mutations or activation.
    async Task MaintainHistoriesCoreAsync()
    {
        if (HistoryRetention.IsUnlimited) return;
        var now = clock.GetUtcNow();
        foreach (var accountId in vault.Accounts.Select(x => x.Id).ToArray())
        {
            var active = !IsDemo && loadedHistoryAccountId == accountId && ActiveAccount?.Id == accountId;
            var epoch = Generation;
            if (!HistoryRetention.Operations.IsUnlimited)
            {
                var source = active ? Records : await records.LoadAsync(accountId);
                var retained = RetainedRecords(source, HistoryRetention.Operations, now);
                if (retained.Count != source.Count)
                {
                    await records.SaveAsync(accountId, retained);
                    if (active && epoch == Generation && ReferenceEquals(source, Records)) Records = retained;
                }
            }
            if (autoSignStore is null || HistoryRetention.Automatic.IsUnlimited) continue;
            await autoSignSaveGate.WaitAsync();
            try
            {
                // Read the active execution dictionary only after acquiring the save gate. Inactive
                // disk reads must never leave a stale snapshot of active submission evidence.
                if (active && !autoSignStoreAvailable)
                    throw new IOException("自动签到执行记录不可用，未清理该账户的自动历史");
                var source = active ? new AutoSignLedger(AutoSignLedger.CurrentVersion, accountId,
                    new(autoSignExecutions)) : await autoSignStore.LoadAutoSignAsync(accountId);
                if (source is null) continue;
                source.Validate(accountId);
                var retained = source.RetainHistory(HistoryRetention.Automatic, now);
                if (retained.Executions.All(x => ReferenceEquals(x.Value, source.Executions[x.Key]))) continue;
                await autoSignStore.SaveAutoSignAsync(retained);
                if (active && epoch == Generation) ApplySavedHistoryCompaction(source, retained);
            }
            finally { autoSignSaveGate.Release(); }
        }
        historyCleanupAfter = now.AddHours(1);
    }

    void ApplySavedHistoryCompaction(AutoSignLedger source, AutoSignLedger saved)
    {
        foreach (var pair in saved.Executions)
            if (autoSignExecutions.TryGetValue(pair.Key, out var current)
                && ReferenceEquals(current, source.Executions[pair.Key]))
                autoSignExecutions[pair.Key] = pair.Value;
    }

    async Task MaintainHistoryRetentionIfDueAsync(bool force = false)
    {
        if (IsDemo || HistoryRetention.IsUnlimited || !loaded || !CanChangeAccount
            || !force && historyCleanupAfter is { } next && clock.GetUtcNow() < next) return;
        await mutations.WaitAsync();
        var ownsBusy = false;
        try
        {
            if (IsDemo || !CanChangeAccount) return;
            IsBusy = true;
            ownsBusy = true;
            await historySaveGate.WaitAsync();
            try { await MaintainHistoriesCoreAsync(); }
            catch (Exception e)
            {
                historyCleanupAfter = clock.GetUtcNow().AddMinutes(1);
                Message = "记录保留设置清理未完成；稍后将重试：" + e.Message;
            }
            finally { historySaveGate.Release(); }
        }
        finally { if (ownsBusy) IsBusy = false; mutations.Release(); Notify(); }
    }

    async Task MaintainActivatedHistoryAsync(Guid epoch)
    {
        if (HistoryRetention.IsUnlimited || IsDemo || epoch != Generation) return;
        await mutations.WaitAsync();
        var ownsBusy = false;
        try
        {
            if (IsDemo || epoch != Generation) return;
            if (!IsBusy) { IsBusy = true; ownsBusy = true; }
            await historySaveGate.WaitAsync();
            try
            {
                if (!IsDemo && epoch == Generation) await MaintainHistoriesCoreAsync();
            }
            catch (Exception e) { Message = "记录保留设置清理未完成；稍后将重试：" + e.Message; }
            finally { historySaveGate.Release(); }
        }
        finally { if (ownsBusy) IsBusy = false; mutations.Release(); }
    }
}
